import AppKit
import CMFMCore
import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        // Build-time helper: `--render-icon <dir>` writes the app icon set and exits.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-icon"), CommandLine.arguments.count > flag + 1 {
            IconRenderer.render(into: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            return
        }
        CleanMyFuckingMacApp.main()
    }
}

let mainWindowID = "main"

enum AppVersion {
    /// "v1.1.0" from the bundle; "dev" when run outside the .app (`swift run`).
    static let label = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? "dev"
}

/// Keeps the menu bar service alive. The Dock icon follows the main window, and Cmd+Q or
/// the Dock's Quit only close that window: `AppDelegate.quit()` and a session end really quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var isQuitting = false

    static func quit() {
        isQuitting = true
        NSApp.terminate(nil)
    }

    private static var mainWindows: [NSWindow] {
        NSApp.windows.filter { !($0 is NSPanel) && $0.canBecomeMain && $0.isVisible }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowDidBecomeMain), name: NSWindow.didBecomeMainNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
        // Logging out or shutting down must not be blocked by the service.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionWillEnd),
                                                          name: NSWorkspace.willPowerOffNotification, object: nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.isQuitting { return .terminateNow }
        Log.info("app", "Fenêtre fermée, le service reste actif dans la barre de menus")
        Self.mainWindows.forEach { $0.close() }
        return .terminateCancel
    }

    @objc private func windowDidBecomeMain(_ notification: Notification) {
        guard !(notification.object is NSPanel) else { return }
        NSApp.setActivationPolicy(.regular)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        // The closing window is still visible here: decide once it is gone.
        DispatchQueue.main.async {
            if Self.mainWindows.allSatisfy({ $0 === closing }) { NSApp.setActivationPolicy(.accessory) }
        }
    }

    @objc private func sessionWillEnd() {
        Self.isQuitting = true
    }
}

struct CleanMyFuckingMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var monitor = SystemMonitor()

    var body: some Scene {
        // A single window: closing it leaves the menu bar service running.
        Window("CleanMyFuckingMac", id: mainWindowID) {
            RootView()
                .environmentObject(state)
                .environmentObject(monitor)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)

        MenuBarExtra {
            MenuBarView().environmentObject(state).environmentObject(monitor)
        } label: {
            Image(systemName: "bolt.circle.fill")
            Text(Fmt.bytes(monitor.disk.free))
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var isBooting = true

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if isBooting {
                SplashView().transition(.opacity.combined(with: .scale(scale: 1.05)))
            } else {
                HStack(spacing: 0) {
                    Sidebar()
                    content
                        .padding(28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .confirmationDialog("Smart Clean : nettoyer \(Fmt.bytes(state.smartCleanTotal)) ?", isPresented: $state.isConfirmingSmartClean) {
            Button(state.permanentDelete ? "Supprimer définitivement" : "Mettre à la Corbeille", role: .destructive) {
                Task { await state.smartClean() }
            }
        } message: {
            Text("Caches d'apps, caches développeur, caches des navigateurs et journaux. "
                 + (state.permanentDelete ? "Suppression définitive : impossible à annuler." : "Tout part dans la Corbeille."))
        }
        .task {
            Log.info("app", "Démarrage de CleanMyFuckingMac \(AppVersion.label)")
            state.refreshSystem()
            state.loadApps()
            state.scanCleanup()
            // Keep the boot screen long enough to be read, not longer.
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeInOut(duration: 0.45)) { isBooting = false }
            if let directory = Snapshotter.directory {
                await Snapshotter.run(state: state, monitor: monitor, into: directory)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch state.section {
        case .dashboard: DashboardView()
        case .health: HealthView()
        case .lens: SpaceLensView()
        case .cleanup: CleanupView()
        case .files: LargeFilesView()
        case .apps: UninstallerView()
        case .performance: PerformanceView()
        case .logs: LogsView()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                LogoView(size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("CleanMy").font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("FuckingMac").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.top, 34)
            .padding(.bottom, 22)
            .padding(.horizontal, 6)

            ForEach(AppSection.allCases) { section in
                Button {
                    state.section = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol).frame(width: 20)
                        Text(section.title)
                        Spacer()
                    }
                    .font(.system(size: 13, weight: state.section == section ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(state.section == section ? AnyShapeStyle(.white.opacity(0.14)) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: state.disk.usedFraction).tint(Theme.pink)
                Text("\(Fmt.bytes(state.disk.free)) libres sur \(Fmt.bytes(state.disk.total))")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Text(AppVersion.label)
                    .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Theme.secondaryText.opacity(0.7))
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 12)
        .frame(width: 216)
        .background(.black.opacity(0.22))
    }
}

struct SplashView: View {
    @State private var appeared = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(Theme.pink.opacity(0.35)).frame(width: 220, height: 220).blur(radius: 60)
                    .scaleEffect(pulse ? 1.15 : 0.85)
                LogoView(size: 132)
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .rotationEffect(.degrees(appeared ? 0 : -12))
            }
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    Text("CleanMy").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("FuckingMac").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(Theme.accent)
                }
                Text("On regarde ce qui bouffe ton disque…").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            ProgressView().controlSize(.small).opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.62)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

enum IconRenderer {
    /// macOS icon grid: artwork fills 824 of 1024 points.
    private static let artworkRatio: CGFloat = 824.0 / 1024.0

    @MainActor
    static func render(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let pixels = CGFloat(points * scale)
            let renderer = ImageRenderer(content: LogoView(size: pixels * artworkRatio).frame(width: pixels, height: pixels))
            renderer.scale = 1
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("Rendu impossible pour \(points)@\(scale)x\n".utf8))
                exit(1)
            }
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try? png.write(to: directory.appendingPathComponent(name))
        }
    }
}
