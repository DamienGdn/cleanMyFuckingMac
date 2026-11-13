import Foundation

public enum RemovalError: LocalizedError, Equatable {
    case refused(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .refused(path, reason): return "Suppression refusée (\(reason)) : \(path)"
        }
    }
}

/// The single door every deletion goes through. It refuses anything that is not
/// clearly a leaf inside the user's home (or an app bundle in /Applications).
public struct SafeRemover: Sendable {
    public let home: String

    /// Home-relative prefixes that are never touched.
    private static let forbiddenPrefixes: [[String]] = [
        [".ssh"], [".gnupg"], [".aws"], [".kube"],
        ["Library", "Keychains"], ["Library", "Mobile Documents"], ["Library", "Mail"],
        ["Library", "Messages"], ["Library", "CloudStorage"],
    ]

    public init(home: String) {
        self.home = URL(fileURLWithPath: home).standardizedFileURL.path
    }

    public func validate(_ rawPath: String) throws {
        func refuse(_ reason: String) -> RemovalError { .refused(path: rawPath, reason: reason) }
        guard rawPath.hasPrefix("/"), !rawPath.contains("\u{0}") else { throw refuse("chemin invalide") }
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path

        if path.hasPrefix("/Applications/") {
            let components = path.split(separator: "/")
            guard components.count == 2, path.hasSuffix(".app") else { throw refuse("seules les apps de /Applications sont autorisées") }
            return
        }

        guard path.hasPrefix(home + "/") else { throw refuse("hors du dossier personnel") }
        let components = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        // A top-level folder of the home, or a direct child of ~/Library, is a container, not a leaf.
        let minimumDepth = components.first == "Library" ? 3 : 2
        guard components.count >= minimumDepth else { throw refuse("dossier racine protégé") }
        for prefix in Self.forbiddenPrefixes where components.starts(with: prefix) {
            throw refuse("zone sensible protégée")
        }
    }

    /// Moves the item to the Trash, or deletes it for good when `permanent` is true.
    public func remove(_ path: String, permanent: Bool) throws {
        try validate(path)
        let url = URL(fileURLWithPath: path)
        if permanent {
            try FileManager.default.removeItem(at: url)
        } else {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }
}
