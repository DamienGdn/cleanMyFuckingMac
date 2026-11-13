import Foundation

/// One entry of the scanned size tree. Small files and small directories are not
/// kept as nodes: they are folded into a single aggregate child per directory.
public final class FileNode: Identifiable, @unchecked Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    /// True for the synthetic "small files" child.
    public let isAggregate: Bool
    public let modified: Date?
    public let accessed: Date?
    public internal(set) var size: Int64
    public internal(set) var fileCount: Int
    public internal(set) var children: [FileNode] = []
    public internal(set) weak var parent: FileNode?
    var smallBytes: Int64 = 0

    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, size: Int64 = 0, fileCount: Int = 0,
                modified: Date? = nil, accessed: Date? = nil, isAggregate: Bool = false) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.fileCount = fileCount
        self.modified = modified
        self.accessed = accessed
        self.isAggregate = isAggregate
    }

    /// Chain from the root down to this node.
    public var ancestors: [FileNode] {
        var chain: [FileNode] = []
        var node: FileNode? = self
        while let current = node {
            chain.append(current)
            node = current.parent
        }
        return chain.reversed()
    }

    /// Removes this node from the tree and subtracts its size from every ancestor.
    public func detach() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var node: FileNode? = parent
        while let current = node {
            current.size -= size
            current.fileCount -= fileCount
            node = current.parent
        }
        self.parent = nil
    }

    /// Every real file node (no directories, no aggregates) of at least `minSize`, largest first.
    public func files(minSize: Int64) -> [FileNode] {
        var result: [FileNode] = []
        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            guard node.size >= minSize else { continue }
            if node.isDirectory {
                stack.append(contentsOf: node.children)
            } else if !node.isAggregate {
                result.append(node)
            }
        }
        return result.sorted { $0.size > $1.size }
    }
}

public enum PathFilter {
    private static let bundleSuffixes = [".app", ".photoslibrary", ".framework", ".bundle", ".xcodeproj", ".musiclibrary"]

    /// True when the path looks like a document the user put there, not app or tool internals.
    public static func isUserContent(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        let components = path.dropFirst(home.count + 1).split(separator: "/")
        for (index, component) in components.enumerated() {
            if component.hasPrefix(".") || component == "Library" || component == "node_modules" { return false }
            let isLast = index == components.count - 1
            if !isLast, bundleSuffixes.contains(where: { component.hasSuffix($0) }) { return false }
        }
        return true
    }
}

public enum Fmt {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
}
