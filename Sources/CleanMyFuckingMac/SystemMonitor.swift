import AppKit
import CMFMCore
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

/// Resource use of one application, all its helper processes included.
struct AppLoad: Identifiable {
    let name: String
    let cpu: Double
    let memory: Int64
    let pids: [Int32]
    var id: String { name }

    /// The app's own process if it is a regular, quittable application.
    var runningApplication: NSRunningApplication? {
        pids.lazy.compactMap { NSRunningApplication(processIdentifier: $0) }.first { $0.activationPolicy == .regular }
    }
}

/// The background service: samples the machine every few seconds for the menu bar and the Performance screen.
@MainActor
final class SystemMonitor: ObservableObject {
    static let sampleInterval: Duration = .seconds(3)
    /// Free space under which a low-disk notification is sent, once per launch.
    static let lowDiskThreshold: Int64 = 10 << 30
    private static let listLength = 12
    /// Health is refreshed every this many samples (it spawns diskutil).
    private static let healthEvery = 20

    @Published var cpu = 0.0
    @Published var memory = SystemInfo.memoryUsage()
    @Published var disk = SystemInfo.diskUsage()
    @Published var battery = SystemInfo.battery()
    @Published var downloadRate = 0.0
    @Published var uploadRate = 0.0
    @Published var topByCPU: [AppLoad] = []
    @Published var topByMemory: [AppLoad] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var health: HealthReport?

    private var lowDiskNotified = false

    init() {
        Task { await run() }
    }

    private struct Sample: Sendable {
        let ticks: CPUTicks
        let network: NetworkCounters
        let date: Date
        let memory: MemoryUsage
        let disk: DiskUsage
        let battery: BatteryInfo?
        let processes: [ProcessEntry]
    }

    private func run() async {
        var previous: Sample?
        var count = 0
        while !Task.isCancelled {
            if count % Self.healthEvery == 0 { refreshHealth() }
            count += 1
            let sample = await Task.detached(priority: .utility) {
                Sample(ticks: SystemInfo.cpuTicks(), network: SystemInfo.networkCounters(), date: Date(),
                       memory: SystemInfo.memoryUsage(), disk: SystemInfo.diskUsage(), battery: SystemInfo.battery(),
                       processes: SystemInfo.processes())
            }.value
            apply(sample, previous: previous)
            previous = sample
            try? await Task.sleep(for: Self.sampleInterval)
        }
    }

    private func apply(_ sample: Sample, previous: Sample?) {
        memory = sample.memory
        disk = sample.disk
        battery = sample.battery
        if let previous {
            cpu = sample.ticks.usage(since: previous.ticks)
            let seconds = max(0.001, sample.date.timeIntervalSince(previous.date))
            // Kernel counters are 32-bit: truncate before the wrapping difference.
            downloadRate = Double(UInt32(truncatingIfNeeded: sample.network.received) &- UInt32(truncatingIfNeeded: previous.network.received)) / seconds
            uploadRate = Double(UInt32(truncatingIfNeeded: sample.network.sent) &- UInt32(truncatingIfNeeded: previous.network.sent)) / seconds
        }
        let loads = Dictionary(grouping: sample.processes, by: \.app).map { name, group in
            AppLoad(name: name, cpu: group.reduce(0) { $0 + $1.cpu }, memory: group.reduce(0) { $0 + $1.memory },
                    pids: group.map(\.pid))
        }
        topByCPU = Array(loads.sorted { $0.cpu > $1.cpu }.prefix(Self.listLength))
        topByMemory = Array(loads.sorted { $0.memory > $1.memory }.prefix(Self.listLength))
        warnIfDiskLow()
    }

    func refreshHealth() {
        let pressure: HealthInputs.ThermalPressure
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: pressure = .nominal
        case .fair: pressure = .fair
        case .serious: pressure = .serious
        case .critical: pressure = .critical
        @unknown default: pressure = .nominal
        }
        Task.detached(priority: .utility) {
            let report = HealthReport(inputs: HealthInputs(
                disk: SystemInfo.diskUsage(), memory: SystemInfo.memoryUsage(), swapUsed: SystemInfo.swapUsed(),
                battery: SystemInfo.batteryHealth(), smartVerified: SystemInfo.smartVerified(),
                uptime: ProcessInfo.processInfo.systemUptime, loadAverage: SystemInfo.loadAverage(),
                cores: ProcessInfo.processInfo.activeProcessorCount, thermalPressure: pressure))
            await MainActor.run {
                if self.health?.score != report.score { Log.info("santé", "Score de santé : \(report.score)/100") }
                self.health = report
            }
        }
    }

    private func warnIfDiskLow() {
        guard !lowDiskNotified, disk.total > 0, disk.free < Self.lowDiskThreshold,
              Bundle.main.bundleIdentifier != nil else { return }
        lowDiskNotified = true
        let free = Fmt.bytes(disk.free)
        Log.warning("moniteur", "Espace disque faible : \(free) libres")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Disque presque plein"
            content.body = "Il ne reste que \(free). Ouvre CleanMyFuckingMac pour faire de la place."
            center.add(UNNotificationRequest(identifier: "low-disk", content: content, trigger: nil))
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.info("moniteur", "Lancement à l'ouverture de session : \(enabled ? "activé" : "désactivé")")
        } catch {
            Log.error("moniteur", "Lancement à l'ouverture de session : \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// The quick panel shown from the menu bar icon.
struct MenuBarView: View {
    private enum Ranking: String, CaseIterable { case cpu = "CPU", memory = "Mémoire" }

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var ranking: Ranking = .cpu

    private static let rowCount = 5
    private static let cpuCores = Double(ProcessInfo.processInfo.activeProcessorCount)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LogoView(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("CleanMyFuckingMac").font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("Santé \(monitor.health.map { "\($0.score)/100" } ?? "…") · Nettoyable \(state.isCleanScanning ? "…" : Fmt.bytes(state.cleanableTotal))")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Ouvrir") { open(.dashboard) }.buttonStyle(AccentButtonStyle())
            }

            HStack(spacing: 8) {
                gauge("Disque", fraction: monitor.disk.usedFraction, detail: "\(Fmt.bytes(monitor.disk.free)) libres")
                gauge("Mémoire", fraction: monitor.memory.usedFraction, detail: Fmt.bytes(monitor.memory.used))
                gauge("CPU", fraction: monitor.cpu, detail: "\(ProcessInfo.processInfo.activeProcessorCount) cœurs")
            }

            HStack(spacing: 8) {
                chip("arrow.down", Self.rate(monitor.downloadRate))
                chip("arrow.up", Self.rate(monitor.uploadRate))
                if let battery = monitor.battery {
                    chip(battery.isCharging ? "battery.100.bolt" : "battery.75", "\(battery.percent) %")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Apps les plus gourmandes").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Picker("", selection: $ranking) {
                        ForEach(Ranking.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                }
                ForEach((ranking == .cpu ? monitor.topByCPU : monitor.topByMemory).prefix(Self.rowCount)) { load in
                    HStack(spacing: 8) {
                        Text(load.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(ranking == .cpu ? String(format: "%.0f %%", load.cpu) : Fmt.bytes(load.memory))
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        Button {
                            Log.info("moniteur", "Demande de fermeture : \(load.name)")
                            load.runningApplication?.terminate()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Quitter \(load.name)")
                        .opacity(load.runningApplication == nil ? 0 : 1)
                        .disabled(load.runningApplication == nil)
                    }
                    .frame(height: 20)
                }
            }
            .padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 8) {
                Button("Smart Scan") { state.smartScan(); open(.dashboard) }.buttonStyle(GhostButtonStyle())
                Button("Nettoyer") { open(.cleanup) }.buttonStyle(GhostButtonStyle())
                Button("Space Lens") { open(.lens) }.buttonStyle(GhostButtonStyle())
                Button("Santé") { open(.health) }.buttonStyle(GhostButtonStyle())
                Spacer()
            }

            Divider().overlay(.white.opacity(0.12))
            HStack {
                Toggle("Lancer à l'ouverture de session", isOn: Binding(get: { monitor.launchAtLogin },
                                                                       set: { monitor.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(Theme.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private func gauge(_ title: String, fraction: Double, detail: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RingGauge(fraction: fraction, lineWidth: 6)
                Text("\(Int((fraction * 100).rounded())) %").font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 54, height: 54)
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.white.opacity(0.06), in: Capsule())
    }

    private func open(_ section: AppSection) {
        state.section = section
        openWindow(id: mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        Fmt.bytes(Int64(bytesPerSecond)) + "/s"
    }
}
