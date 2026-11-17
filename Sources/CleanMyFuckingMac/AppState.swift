import AppKit
import CMFMCore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, health, lens, cleanup, files, apps, performance, logs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return String(localized: "Dashboard")
        case .health: return String(localized: "Mac Health")
        case .lens: return "Space Lens"
        case .cleanup: return String(localized: "Cleanup")
        case .files: return String(localized: "Large Files")
        case .apps: return String(localized: "Uninstaller")
        case .performance: return String(localized: "Performance")
        case .logs: return String(localized: "Logs")
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "speedometer"
        case .health: return "heart.text.square.fill"
        case .lens: return "square.grid.3x3.topleft.filled"
        case .cleanup: return "sparkles"
        case .files: return "doc.on.doc.fill"
        case .apps: return "xmark.app.fill"
        case .performance: return "bolt.fill"
        case .logs: return "list.bullet.rectangle.fill"
        }
    }
}

struct DeletionRequest {
    let path: String
    let size: Int64
    let permanent: Bool
}

struct DeletionOutcome {
    var freed: Int64 = 0
    var removed: Set<String> = []
    var errors: [String] = []
}

@MainActor
final class AppState: ObservableObject {
    nonisolated static let dataVolume = "/System/Volumes/Data"
    nonisolated static let largeFileThreshold: Int64 = 50 << 20

    let home = NSHomeDirectory()
    let remover: SafeRemover

    @Published var section: AppSection = .dashboard
    @Published var disk = SystemInfo.diskUsage()
    @Published var hasFullDiskAccess = false
    /// Deletes for good instead of moving to the Trash.
    @Published var permanentDelete = UserDefaults.standard.bool(forKey: "permanentDelete") {
        didSet { UserDefaults.standard.set(permanentDelete, forKey: "permanentDelete") }
    }

    // Space Lens and large files share one scan tree.
    @Published var isScanning = false
    @Published var scanRoot: String
    @Published var tree: FileNode?
    @Published var focus: FileNode?
    @Published var largeFiles: [FileNode] = []
    /// Bumped whenever the tree is mutated in place, so views re-read it.
    @Published var treeVersion = 0
    private(set) var scanProgress = ScanProgress()

    @Published var isCleanScanning = false
    @Published var cleanResults: [CleanResult] = []
    @Published var cleanSelection: Set<String> = []
    @Published var isDeleting = false
    @Published var lastOutcome: String?
    @Published var isConfirmingSmartClean = false

    @Published var isFindingDuplicates = false
    @Published var duplicateGroups: [DuplicateGroup]?

    @Published var isLoadingApps = false
    @Published var apps: [InstalledApp] = []

    init() {
        remover = SafeRemover(home: home)
        scanRoot = home
    }

    var cleanSelectedTotal: Int64 {
        cleanResults.flatMap(\.items).filter { cleanSelection.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    /// What Smart Clean removes: the safe default categories, never the Trash or AI models.
    var smartCleanTotal: Int64 {
        cleanResults.filter(\.category.isSmartCleanable).reduce(0) { $0 + $1.total }
    }

    var cleanableTotal: Int64 { cleanResults.reduce(0) { $0 + $1.total } }

    func refreshSystem() {
        disk = SystemInfo.diskUsage()
        hasFullDiskAccess = SystemInfo.hasFullDiskAccess(home: home)
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Disk scan

    func startScan(root: String? = nil) {
        guard !isScanning else { return }
        if let root { scanRoot = root }
        let target = scanRoot
        let progress = ScanProgress()
        scanProgress = progress
        isScanning = true
        duplicateGroups = nil
        Log.info("scan", "Scanning \(target)")
        Task.detached(priority: .userInitiated) {
            let start = Date()
            let result = DiskScanner.scan(root: target, progress: progress)
            let large = result?.files(minSize: AppState.largeFileThreshold) ?? []
            await MainActor.run {
                self.isScanning = false
                guard let result else {
                    Log.warning("scan", progress.isCancelled ? "Scan cancelled" : "Cannot read \(target)")
                    return
                }
                self.tree = result
                self.focus = result
                self.largeFiles = large
                self.treeVersion += 1
                let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
                Log.info("scan", "Scan done: \(Fmt.bytes(result.size)), \(result.fileCount) files, \(seconds) s")
            }
        }
    }

    func cancelScan() {
        scanProgress.cancel()
    }

    // MARK: Cleanup

    func scanCleanup() {
        Task { await rescanCleanup() }
    }

    func rescanCleanup() async {
        guard !isCleanScanning else { return }
        isCleanScanning = true
        lastOutcome = nil
        let home = home
        let results = await Task.detached(priority: .userInitiated) { CleanupScanner.scan(home: home) }.value
        cleanResults = results
        cleanSelection = Set(results.filter { $0.category.selectedByDefault }.flatMap(\.items).map(\.path))
        isCleanScanning = false
        Log.info("cleanup", "Scan: \(Fmt.bytes(cleanableTotal)) cleanable")
    }

    func cleanSelected() async {
        await clean { _, item in cleanSelection.contains(item.path) }
    }

    /// Rescans, then asks for confirmation before `smartClean()` deletes anything.
    func requestSmartClean() {
        guard !isCleanScanning, !isDeleting else { return }
        Task {
            await rescanCleanup()
            if smartCleanTotal > 0 { isConfirmingSmartClean = true } else { lastOutcome = String(localized: "Smart Clean: nothing to clean.") }
        }
    }

    func smartClean() async {
        Log.info("cleanup", "Smart Clean: \(Fmt.bytes(smartCleanTotal))")
        await clean { result, _ in result.category.isSmartCleanable }
    }

    private func clean(where shouldClean: (CleanResult, CleanItem) -> Bool) async {
        let requests = cleanResults.flatMap { result in
            result.items.filter { shouldClean(result, $0) }.map {
                DeletionRequest(path: $0.path, size: $0.size, permanent: permanentDelete || result.category.alwaysPermanent)
            }
        }
        let outcome = await delete(requests)
        cleanResults = cleanResults.map { result in
            CleanResult(category: result.category, items: result.items.filter { !outcome.removed.contains($0.path) })
        }
        cleanSelection.subtract(outcome.removed)
    }

    // MARK: Deletion

    /// The only way the app deletes anything: validated by SafeRemover, logged one by one.
    /// Items the user may not move alone (root-owned apps, for instance) are handed to Finder,
    /// which shows the system's Touch ID or password prompt.
    @discardableResult
    func delete(_ requests: [DeletionRequest]) async -> DeletionOutcome {
        guard !requests.isEmpty, !isDeleting else { return DeletionOutcome() }
        isDeleting = true
        let remover = remover
        let outcome = await Task.detached(priority: .userInitiated) {
            var outcome = DeletionOutcome()
            func succeeded(_ request: DeletionRequest, how: String) {
                outcome.freed += request.size
                outcome.removed.insert(request.path)
                Log.info("deletion", "\(how): \(request.path) (\(Fmt.bytes(request.size)))")
            }
            func failed(_ request: DeletionRequest, _ message: String) {
                outcome.errors.append(message)
                Log.error("deletion", "\(request.path): \(message)")
            }
            var protected: [DeletionRequest] = []
            for request in requests {
                do {
                    try remover.remove(request.path, permanent: request.permanent)
                    succeeded(request, how: request.permanent ? "Deleted" : "Trashed")
                } catch where !request.permanent && SafeRemover.isPermissionDenied(error) {
                    protected.append(request)
                } catch {
                    failed(request, error.localizedDescription)
                }
            }
            if !protected.isEmpty {
                Log.info("deletion", "\(protected.count) protected item(s): asking Finder, which requests authorization")
                do {
                    let trashed = try remover.trashWithFinder(protected.map(\.path))
                    for request in protected {
                        if trashed.contains(request.path) {
                            succeeded(request, how: "Trashed by Finder")
                        } else {
                            failed(request, String(localized: "Finder did not move it to the Trash."))
                        }
                    }
                } catch {
                    protected.forEach { failed($0, error.localizedDescription) }
                }
            }
            return outcome
        }.value
        isDeleting = false
        refreshSystem()

        let trashed = requests.contains { !$0.permanent && outcome.removed.contains($0.path) }
        var summary = [String(localized: "\(Fmt.bytes(outcome.freed)) processed, \(outcome.removed.count) item(s).")]
        if trashed { summary.append(String(localized: "Empty the Trash to reclaim the space.")) }
        if !outcome.errors.isEmpty { summary.append(String(localized: "\(outcome.errors.count) error(s), see Logs.")) }
        lastOutcome = summary.joined(separator: " ")
        return outcome
    }

    /// Deletes scanned nodes and keeps the tree and derived lists in sync.
    func delete(nodes: [FileNode], permanent: Bool? = nil) async {
        let mode = permanent ?? permanentDelete
        let outcome = await delete(nodes.map { DeletionRequest(path: $0.path, size: $0.size, permanent: mode) })
        for node in nodes where outcome.removed.contains(node.path) {
            if focus === node { focus = node.parent }
            node.detach()
        }
        largeFiles.removeAll { outcome.removed.contains($0.path) }
        if let groups = duplicateGroups {
            duplicateGroups = groups.compactMap { group in
                var group = group
                group.files.removeAll { outcome.removed.contains($0.path) }
                return group.files.count > 1 ? group : nil
            }
        }
        treeVersion += 1
    }

    // MARK: Duplicates

    func findDuplicates() {
        guard let tree, !isFindingDuplicates else { return }
        isFindingDuplicates = true
        let home = home
        Task.detached(priority: .userInitiated) {
            let candidates = tree.files(minSize: DiskScanner.defaultMinNodeSize)
                .filter { PathFilter.isUserContent($0.path, home: home) }
            let groups = DuplicateFinder.find(candidates: candidates)
            await MainActor.run {
                self.duplicateGroups = groups
                self.isFindingDuplicates = false
                Log.info("duplicates", "\(groups.count) group(s), \(Fmt.bytes(groups.reduce(0) { $0 + $1.wasted })) reclaimable")
            }
        }
    }

    // MARK: Apps

    func loadApps() {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        let home = home
        Task.detached(priority: .userInitiated) {
            let apps = AppInventory.list(home: home)
            await MainActor.run {
                self.apps = apps
                self.isLoadingApps = false
                Log.info("apps", "\(apps.count) applications found")
            }
        }
    }

    func uninstall(_ app: InstalledApp, leftovers: [CleanItem]) async {
        var requests = [DeletionRequest(path: app.path, size: app.size, permanent: false)]
        requests += leftovers.map { DeletionRequest(path: $0.path, size: $0.size, permanent: false) }
        let outcome = await delete(requests)
        if outcome.removed.contains(app.path) {
            apps.removeAll { $0.path == app.path }
        }
    }

    // MARK: Smart Scan

    func smartScan() {
        refreshSystem()
        scanCleanup()
        startScan(root: home)
        loadApps()
    }
}
