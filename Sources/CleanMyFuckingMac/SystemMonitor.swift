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

/// One live value the menu bar can show next to the icon.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case cpu, memory, disk, download, upload, battery

    /// More than this no longer fits a crowded menu bar.
    static let maxShown = 3
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "RAM"
        case .disk: String(localized: "Disk")
        case .download: String(localized: "↓ Network")
        case .upload: String(localized: "↑ Network")
        case .battery: String(localized: "Battery")
        }
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
    /// What the menu bar shows next to the icon, in the order picked. Empty: icon only.
    @Published var menuBarMetrics = UserDefaults.standard.stringArray(forKey: "menuBarMetrics")?
        .compactMap(MenuBarMetric.init(rawValue:)) ?? [.disk] {
        didSet { UserDefaults.standard.set(menuBarMetrics.map(\.rawValue), forKey: "menuBarMetrics") }
    }

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

    // MARK: Menu bar label

    /// Caption and value of every shown metric, e.g. ("CPU", "12%").
    var menuBarItems: [MenuBarLabel.Item] {
        menuBarMetrics.compactMap { metric in
            switch metric {
            case .cpu: .init(caption: "CPU", value: Self.percent(cpu))
            case .memory: .init(caption: "RAM", value: Self.percent(memory.usedFraction))
            case .disk: .init(caption: "SSD", value: Fmt.compactBytes(disk.free))
            case .download: .init(caption: "DOWN", value: Fmt.compactBytes(Int64(downloadRate)))
            case .upload: .init(caption: "UP", value: Fmt.compactBytes(Int64(uploadRate)))
            case .battery: battery.map { .init(caption: "BAT", value: "\($0.percent)%") }
            }
        }
    }

    func toggleMenuBarMetric(_ metric: MenuBarMetric) {
        if let index = menuBarMetrics.firstIndex(of: metric) {
            menuBarMetrics.remove(at: index)
        } else if menuBarMetrics.count < MenuBarMetric.maxShown {
            menuBarMetrics.append(metric)
        }
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
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
                if self.health?.score != report.score { Log.info("health", "Health score: \(report.score)/100") }
                self.health = report
            }
        }
    }

    private func warnIfDiskLow() {
        guard !lowDiskNotified, disk.total > 0, disk.free < Self.lowDiskThreshold,
              Bundle.main.bundleIdentifier != nil else { return }
        lowDiskNotified = true
        let free = Fmt.bytes(disk.free)
        Log.warning("monitor", "Low disk space: \(free) free")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Disk almost full")
            content.body = String(localized: "Only \(free) left. Open CleanMyFuckingMac to free up space.")
            center.add(UNNotificationRequest(identifier: "low-disk", content: content, trigger: nil))
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.info("monitor", "Launch at login: \(enabled ? "on" : "off")")
        } catch {
            Log.error("monitor", "Launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// What sits in the menu bar: the icon, then one tiny caption-over-value column per metric.
/// A menu bar label only accepts an image or a text, so the layout is drawn into a template image.
struct MenuBarLabel: View {
    struct Item {
        let caption: String
        let value: String
    }

    let items: [Item]
    /// Wide enough for "100%" so the menu bar does not shift when values change.
    private static let columnWidth: CGFloat = 30
    private static let barHeight: CGFloat = 22

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.circle.fill").font(.system(size: 14, weight: .medium))
            ForEach(items, id: \.caption) { item in
                VStack(spacing: -1) {
                    Text(item.caption).font(.system(size: 7, weight: .bold)).kerning(0.4).opacity(0.65)
                    Text(item.value).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .frame(width: Self.columnWidth)
            }
        }
        .foregroundStyle(.black)
        .frame(height: Self.barHeight)
    }

    /// Template image: macOS tints it for light, dark and highlighted menu bars.
    @MainActor var image: NSImage {
        let renderer = ImageRenderer(content: self)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

/// The quick panel shown from the menu bar icon.
struct MenuBarView: View {
    private enum Ranking: CaseIterable {
        case cpu, memory
        var title: String { self == .cpu ? "CPU" : String(localized: "Memory") }
    }

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
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("CleanMyFuckingMac").font(.system(size: 13, weight: .bold, design: .rounded))
                        Text(AppVersion.label).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Theme.secondaryText)
                    }
                    Text("Health \(monitor.health.map { "\($0.score)/100" } ?? "…") · Cleanable \(state.isCleanScanning ? "…" : Fmt.bytes(state.cleanableTotal))")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Open") { open(.dashboard) }.buttonStyle(AccentButtonStyle())
            }

            HStack(spacing: 8) {
                gauge("Disk", fraction: monitor.disk.usedFraction, detail: String(localized: "\(Fmt.bytes(monitor.disk.free)) free"))
                gauge("Memory", fraction: monitor.memory.usedFraction, detail: Fmt.bytes(monitor.memory.used))
                gauge("CPU", fraction: monitor.cpu,
                      detail: String(localized: "\(ProcessInfo.processInfo.activeProcessorCount) cores"))
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
                    Text("Top apps").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Picker("", selection: $ranking) {
                        ForEach(Ranking.allCases, id: \.self) { Text($0.title).tag($0) }
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
                            Log.info("monitor", "Quit requested: \(load.name)")
                            load.runningApplication?.terminate()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Quit \(load.name)")
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
                Button("Smart Clean") { state.requestSmartClean(); open(.dashboard) }.buttonStyle(GhostButtonStyle())
                    .disabled(state.isCleanScanning || state.isDeleting)
                Button("Space Lens") { open(.lens) }.buttonStyle(GhostButtonStyle())
                Button("Health") { open(.health) }.buttonStyle(GhostButtonStyle())
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Shown in the menu bar (\(MenuBarMetric.maxShown) max)")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 5) {
                    ForEach(MenuBarMetric.allCases.filter { $0 != .battery || monitor.battery != nil }) { metric in
                        let isOn = monitor.menuBarMetrics.contains(metric)
                        Button(metric.title) { monitor.toggleMenuBarMetric(metric) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
                            .opacity(isOn || monitor.menuBarMetrics.count < MenuBarMetric.maxShown ? 1 : 0.4)
                            .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
            }

            Divider().overlay(.white.opacity(0.12))
            HStack {
                Toggle("Launch at login", isOn: Binding(get: { monitor.launchAtLogin },
                                                                       set: { monitor.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                Spacer()
                Button("Quit") { AppDelegate.quit() }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(Theme.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private func gauge(_ title: LocalizedStringKey, fraction: Double, detail: String) -> some View {
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
