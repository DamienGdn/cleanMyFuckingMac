import Foundation

public enum RemovalError: LocalizedError, Equatable {
    case refused(path: String, reason: String)
    case finderFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case let .refused(path, reason): return String(localized: "Deletion refused (\(reason)): \(path)")
        case let .finderFailed(message): return String(localized: "Finder could not move the items to the Trash: \(message)")
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

    /// Deletes the paths given as arguments; Finder asks for Touch ID or a password when needed.
    private static let finderTrashScript = """
        on run argv
            set targets to {}
            repeat with target in argv
                set end of targets to (POSIX file (target as text)) as alias
            end repeat
            tell application "Finder" to delete targets
        end run
        """

    public init(home: String) {
        self.home = URL(fileURLWithPath: home).standardizedFileURL.path
    }

    public func validate(_ rawPath: String) throws {
        func refuse(_ reason: String) -> RemovalError { .refused(path: rawPath, reason: reason) }
        guard rawPath.hasPrefix("/"), !rawPath.contains("\u{0}") else { throw refuse(String(localized: "invalid path")) }
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path

        if path.hasPrefix("/Applications/") {
            let components = path.split(separator: "/")
            guard components.count == 2, path.hasSuffix(".app") else {
                throw refuse(String(localized: "only apps in /Applications are allowed"))
            }
            return
        }

        guard path.hasPrefix(home + "/") else { throw refuse(String(localized: "outside the home folder")) }
        let components = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        // A top-level folder of the home, or a direct child of ~/Library, is a container, not a leaf.
        let minimumDepth = components.first == "Library" ? 3 : 2
        guard components.count >= minimumDepth else { throw refuse(String(localized: "protected root folder")) }
        for prefix in Self.forbiddenPrefixes where components.starts(with: prefix) {
            throw refuse(String(localized: "protected sensitive area"))
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

    /// Moves items the user may not move alone (root-owned apps, for instance) to the Trash through Finder,
    /// which shows the system authorization prompt (Touch ID or password). Blocks until Finder is done.
    /// Returns the paths that are gone afterwards.
    public func trashWithFinder(_ paths: [String]) throws -> Set<String> {
        for path in paths { try validate(path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Paths travel as arguments, never inside the script text.
        process.arguments = ["-e", Self.finderTrashScript] + paths
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let gone = Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
        if process.terminationStatus != 0, gone.isEmpty {
            let message = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemovalError.finderFailed(message: message)
        }
        return gone
    }

    /// Whether a failed move or delete was refused for lack of permission (and could succeed with authorization).
    public static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return underlying.code == Int(EACCES) || underlying.code == Int(EPERM)
        }
        return false
    }
}
