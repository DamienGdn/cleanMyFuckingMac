import AppKit
import CMFMCore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, health, lens, cleanup, files, apps, performance, logs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Tableau de bord"
        case .health: return "Santé du Mac"
        case .lens: return "Space Lens"
        case .cleanup: return "Nettoyage"
        case .files: return "Gros fichiers"
        case .apps: return "Désinstalleur"
        case .performance: return "Performance"
        case .logs: return "Journaux"
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
        Log.info("scan", "Analyse de \(target)")
        Task.detached(priority: .userInitiated) {
            let start = Date()
            let result = DiskScanner.scan(root: target, progress: progress)
            let large = result?.files(minSize: AppState.largeFileThreshold) ?? []
            await MainActor.run {
                self.isScanning = false
                guard let result else {
                    Log.warning("scan", progress.isCancelled ? "Analyse annulée" : "Lecture impossible : \(target)")
                    return
                }
                self.tree = result
                self.focus = result
                self.largeFiles = large
                self.treeVersion += 1
                let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
                Log.info("scan", "Analyse terminée : \(Fmt.bytes(result.size)), \(result.fileCount) fichiers, \(seconds) s")
            }
        }
    }

    func cancelScan() {
        scanProgress.cancel()
    }

    // MARK: Cleanup

    func scanCleanup() {
        guard !isCleanScanning else { return }
        isCleanScanning = true
        lastOutcome = nil
        let home = home
        Task.detached(priority: .userInitiated) {
            let results = CleanupScanner.scan(home: home)
            await MainActor.run {
                self.cleanResults = results
                self.cleanSelection = Set(results.filter { $0.category.selectedByDefault }.flatMap(\.items).map(\.path))
                self.isCleanScanning = false
                Log.info("nettoyage", "Analyse : \(Fmt.bytes(self.cleanableTotal)) nettoyables")
            }
        }
    }

    func cleanSelected() async {
        let requests = cleanResults.flatMap { result in
            result.items.filter { cleanSelection.contains($0.path) }.map {
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
    @discardableResult
    func delete(_ requests: [DeletionRequest]) async -> DeletionOutcome {
        guard !requests.isEmpty, !isDeleting else { return DeletionOutcome() }
        isDeleting = true
        let remover = remover
        let outcome = await Task.detached(priority: .userInitiated) {
            var outcome = DeletionOutcome()
            for request in requests {
                do {
                    try remover.remove(request.path, permanent: request.permanent)
                    outcome.freed += request.size
                    outcome.removed.insert(request.path)
                    Log.info("suppression", "\(request.permanent ? "Supprimé" : "Corbeille") : \(request.path) (\(Fmt.bytes(request.size)))")
                } catch {
                    outcome.errors.append(error.localizedDescription)
                    Log.error("suppression", "\(request.path) : \(error.localizedDescription)")
                }
            }
            return outcome
        }.value
        isDeleting = false
        refreshSystem()

        let trashed = requests.contains { !$0.permanent && outcome.removed.contains($0.path) }
        var summary = "\(Fmt.bytes(outcome.freed)) traités, \(outcome.removed.count) élément(s)."
        if trashed { summary += " Vide la Corbeille pour récupérer l'espace." }
        if !outcome.errors.isEmpty { summary += " \(outcome.errors.count) erreur(s), voir Journaux." }
        lastOutcome = summary
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
                Log.info("doublons", "\(groups.count) groupe(s), \(Fmt.bytes(groups.reduce(0) { $0 + $1.wasted })) récupérables")
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
                Log.info("apps", "\(apps.count) applications trouvées")
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
