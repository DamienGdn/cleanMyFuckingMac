import Foundation

/// App journal: an in-memory ring for the Logs screen plus a rotating file on disk.
public final class AppLog: @unchecked Sendable {
    public enum Level: String, CaseIterable, Sendable {
        case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR"
    }

    public struct Entry: Identifiable, Sendable {
        public let id: Int
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String
    }

    public static let shared = AppLog(directory: FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(CleanupCatalog.ownLogDirectory))
    public static let didChange = Notification.Name("CMFMLogDidChange")

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("app.log") }
    private var rotatedURL: URL { directory.appendingPathComponent("app.1.log") }

    private let queue = DispatchQueue(label: "cmfm.log")
    private let maxFileSize: Int
    private let maxEntries: Int
    private var entries: [Entry] = []
    private var nextID = 0
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(directory: URL, maxFileSize: Int = 2 << 20, maxEntries: Int = 3000) {
        self.directory = directory
        self.maxFileSize = maxFileSize
        self.maxEntries = maxEntries
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func log(_ level: Level, _ category: String, _ message: String) {
        let date = Date()
        queue.async { [self] in
            entries.append(Entry(id: nextID, date: date, level: level, category: category, message: message))
            nextID += 1
            if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
            append("\(formatter.string(from: date)) [\(level.rawValue)] [\(category)] \(message)\n")
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    public func snapshot() -> [Entry] {
        queue.sync { entries }
    }

    /// Empties the in-memory journal and deletes the log files.
    public func clear() {
        queue.sync {
            entries.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: rotatedURL)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Blocks until every pending entry is written.
    public func flush() {
        queue.sync {}
    }

    private func append(_ line: String) {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size > maxFileSize {
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: fileURL, to: rotatedURL)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

public enum Log {
    public static func debug(_ category: String, _ message: String) { AppLog.shared.log(.debug, category, message) }
    public static func info(_ category: String, _ message: String) { AppLog.shared.log(.info, category, message) }
    public static func warning(_ category: String, _ message: String) { AppLog.shared.log(.warning, category, message) }
    public static func error(_ category: String, _ message: String) { AppLog.shared.log(.error, category, message) }
}
