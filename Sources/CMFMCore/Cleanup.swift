import Foundation

public struct CleanCategory: Identifiable, Sendable {
    public enum Source: Sendable {
        /// Every direct child of a home-relative directory is one item.
        case children(String)
        /// One home-relative path is one item.
        case path(String, label: String)
        /// `sub` inside every profile directory of a home-relative browser data directory.
        case profiles(base: String, subs: [String], label: String)
    }

    public let id: String
    public let title: String
    public let detail: String
    public let symbol: String
    /// Checked by default after a scan.
    public let selectedByDefault: Bool
    /// Deleted for good regardless of the user's Trash preference (the Trash itself).
    public let alwaysPermanent: Bool
    public let sources: [Source]
}

public struct CleanItem: Identifiable, Sendable {
    public let path: String
    public let label: String
    public let size: Int64
    public var id: String { path }
}

public struct CleanResult: Identifiable, Sendable {
    public let category: CleanCategory
    public let items: [CleanItem]
    public var id: String { category.id }

    public init(category: CleanCategory, items: [CleanItem]) {
        self.category = category
        self.items = items
    }
    public var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

public enum CleanupCatalog {
    /// Own log directory: never offered for cleaning.
    public static let ownLogDirectory = "Library/Logs/CleanMyFuckingMac"

    public static let categories: [CleanCategory] = [
        CleanCategory(id: "app-caches", title: "Caches d'applications",
                      detail: "Fichiers temporaires recréés automatiquement par les apps.",
                      symbol: "shippingbox.fill", selectedByDefault: true, alwaysPermanent: false,
                      sources: [.children("Library/Caches")]),
        CleanCategory(id: "dev-caches", title: "Caches développeur",
                      detail: "Paquets téléchargés et builds intermédiaires. Retéléchargés au besoin.",
                      symbol: "hammer.fill", selectedByDefault: true, alwaysPermanent: false,
                      sources: [
                        .path(".cache/uv", label: "uv (Python)"),
                        .path(".cache/pip", label: "pip"),
                        .path(".npm/_cacache", label: "npm"),
                        .path(".bun/install/cache", label: "Bun"),
                        .path("Library/pnpm/store", label: "pnpm"),
                        .path(".gradle/caches", label: "Gradle"),
                        .path(".pub-cache/hosted", label: "Dart / Flutter pub"),
                        .path(".cargo/registry/cache", label: "Cargo"),
                        .path(".cocoapods/repos", label: "CocoaPods"),
                        .path("Library/Developer/Xcode/DerivedData", label: "Xcode DerivedData"),
                        .path("Library/Developer/Xcode/iOS DeviceSupport", label: "Xcode iOS DeviceSupport"),
                        .path("Library/Developer/CoreSimulator/Caches", label: "Simulateur iOS"),
                      ]),
        CleanCategory(id: "browser-caches", title: "Caches profonds des navigateurs",
                      detail: "Caches de sites et de code. Sessions, mots de passe et historique conservés.",
                      symbol: "globe", selectedByDefault: true, alwaysPermanent: false,
                      sources: [
                        .profiles(base: "Library/Application Support/Google/Chrome",
                                  subs: ["Service Worker/CacheStorage", "Code Cache", "GPUCache"], label: "Chrome"),
                        .profiles(base: "Library/Application Support/BraveSoftware/Brave-Browser",
                                  subs: ["Service Worker/CacheStorage", "Code Cache", "GPUCache"], label: "Brave"),
                        .profiles(base: "Library/Application Support/Microsoft Edge",
                                  subs: ["Service Worker/CacheStorage", "Code Cache", "GPUCache"], label: "Edge"),
                      ]),
        CleanCategory(id: "logs", title: "Journaux",
                      detail: "Fichiers de log des applications.",
                      symbol: "doc.text.fill", selectedByDefault: true, alwaysPermanent: false,
                      sources: [.children("Library/Logs")]),
        CleanCategory(id: "ai-models", title: "Modèles IA téléchargés",
                      detail: "Modèles Hugging Face, Ollama, Torch, Chrome. À retélécharger si tu t'en ressers.",
                      symbol: "brain", selectedByDefault: false, alwaysPermanent: false,
                      sources: [
                        .children(".cache/huggingface/hub"),
                        .path(".cache/torch", label: "Torch"),
                        .path(".ollama/models", label: "Ollama"),
                        .path("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel",
                              label: "Chrome (modèle Gemini embarqué)"),
                      ]),
        CleanCategory(id: "trash", title: "Corbeille",
                      detail: "Suppression définitive : impossible à annuler.",
                      symbol: "trash.fill", selectedByDefault: false, alwaysPermanent: true,
                      sources: [.children(".Trash")]),
    ]
}

public enum CleanupScanner {
    /// Sizes every candidate of every category. Read-only.
    public static func scan(home: String, categories: [CleanCategory] = CleanupCatalog.categories) -> [CleanResult] {
        categories.map { category in
            let candidates = category.sources.flatMap { candidatePaths(for: $0, home: home) }
            var sizes = [Int64](repeating: 0, count: candidates.count)
            sizes.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
                    base[index] = DiskScanner.sizeOf(candidates[index].path)
                }
            }
            let items = zip(candidates, sizes)
                .filter { $0.1 > 0 }
                .map { CleanItem(path: $0.0.path, label: $0.0.label, size: $0.1) }
                .sorted { $0.size > $1.size }
            return CleanResult(category: category, items: items)
        }
    }

    static func candidatePaths(for source: CleanCategory.Source, home: String) -> [(path: String, label: String)] {
        let fm = FileManager.default
        let ownLogs = home + "/" + CleanupCatalog.ownLogDirectory
        switch source {
        case let .children(relative):
            let directory = home + "/" + relative
            let names = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
            return names
                .filter { $0 != ".DS_Store" }
                .map { (directory + "/" + $0, $0) }
                .filter { $0.0 != ownLogs }
        case let .path(relative, label):
            let path = home + "/" + relative
            return fm.fileExists(atPath: path) ? [(path, label)] : []
        case let .profiles(base, subs, label):
            let directory = home + "/" + base
            let profiles = ((try? fm.contentsOfDirectory(atPath: directory)) ?? [])
                .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            return profiles.flatMap { profile in
                subs.compactMap { sub -> (String, String)? in
                    let path = directory + "/" + profile + "/" + sub
                    return fm.fileExists(atPath: path) ? (path, "\(label) · \(profile) · \(sub)") : nil
                }
            }
        }
    }
}
