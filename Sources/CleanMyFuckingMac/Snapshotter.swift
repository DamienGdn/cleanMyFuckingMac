import AppKit
import SwiftUI

/// Development aid: when `CMFM_SNAPSHOT_DIR` is set, the app scans `CMFM_SNAPSHOT_ROOT`
/// (default: home), saves a PNG of every screen into that directory and quits. Read-only.
enum Snapshotter {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["CMFM_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    @MainActor
    static func run(state: AppState, monitor: SystemMonitor, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        state.startScan(root: ProcessInfo.processInfo.environment["CMFM_SNAPSHOT_ROOT"] ?? state.home)
        while state.isScanning || state.isCleanScanning || state.isLoadingApps {
            try? await Task.sleep(for: .milliseconds(200))
        }
        for section in AppSection.allCases {
            state.section = section
            try? await Task.sleep(for: .seconds(1.2))
            capture(to: directory.appendingPathComponent("\(section.rawValue).png"))
        }
        let panel = ImageRenderer(content: MenuBarView().environmentObject(state).environmentObject(monitor))
        panel.scale = 2
        if let image = panel.cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("menubar.png"))
        }
        NSApp.terminate(nil)
    }

    @MainActor
    private static func capture(to url: URL) {
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
