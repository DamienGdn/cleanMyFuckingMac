import Foundation

/// Thread-safe counters shared between a running scan and the UI.
public final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0
    private var cancelled = false

    public init() {}

    public func add(files: Int, bytes: Int64) {
        lock.lock(); self.files += files; self.bytes += bytes; lock.unlock()
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public var snapshot: (files: Int, bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        return (files, bytes)
    }
}

public enum DiskScanner {
    /// Files and directories below this size are folded into their parent's aggregate.
    public static let defaultMinNodeSize: Int64 = 1 << 20
    /// Directory levels listed by hand before handing subtrees to parallel fts walks.
    private static let fanOutDepth = 2

    struct StatInfo {
        let isDirectory: Bool
        let size: Int64
        let modified: Date
        let accessed: Date
        let device: dev_t
    }

    static func lstatInfo(_ path: String) -> StatInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return StatInfo(isDirectory: (st.st_mode & S_IFMT) == S_IFDIR,
                        size: Int64(st.st_blocks) * 512,
                        modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                        accessed: Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec)),
                        device: st.st_dev)
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// Builds the size tree of `root`. Never follows symlinks, never leaves the root's volume.
    /// Returns nil if the root is unreadable or the scan was cancelled.
    public static func scan(root: String, progress: ScanProgress,
                            minNodeSize: Int64 = defaultMinNodeSize) -> FileNode? {
        guard let rootInfo = lstatInfo(root), rootInfo.isDirectory else { return nil }
        let rootNode = FileNode(name: (root as NSString).lastPathComponent, path: root, isDirectory: true)
        var jobs: [FileNode] = []

        func expand(_ node: FileNode, depth: Int) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: node.path) else { return }
            for name in names {
                let path = join(node.path, name)
                guard let info = lstatInfo(path), info.device == rootInfo.device else { continue }
                if info.isDirectory {
                    let child = FileNode(name: name, path: path, isDirectory: true)
                    child.parent = node
                    node.children.append(child)
                    if depth + 1 < fanOutDepth { expand(child, depth: depth + 1) } else { jobs.append(child) }
                } else {
                    addFile(to: node, name: name, path: path, info: info, minNodeSize: minNodeSize)
                }
            }
        }
        expand(rootNode, depth: 0)

        let work = jobs
        DispatchQueue.concurrentPerform(iterations: work.count) { index in
            ftsFill(work[index], progress: progress, minNodeSize: minNodeSize)
        }
        if progress.isCancelled { return nil }

        func finalize(_ node: FileNode, depth: Int) {
            for child in node.children where child.isDirectory {
                if depth + 1 < fanOutDepth { finalize(child, depth: depth + 1) }
                node.size += child.size
                node.fileCount += child.fileCount
            }
            seal(node)
        }
        finalize(rootNode, depth: 0)
        return rootNode
    }

    /// Allocated size of a file or of a whole directory tree, without building nodes.
    public static func sizeOf(_ path: String) -> Int64 {
        guard let info = lstatInfo(path) else { return 0 }
        guard info.isDirectory else { return info.size }
        var total: Int64 = 0
        walk(path) { entry, kind in
            if kind != FTS_D, let st = entry.pointee.fts_statp { total += Int64(st.pointee.st_blocks) * 512 }
            return true
        }
        return total
    }

    private static func addFile(to node: FileNode, name: String, path: String, info: StatInfo, minNodeSize: Int64) {
        node.size += info.size
        node.fileCount += 1
        if info.size >= minNodeSize {
            let file = FileNode(name: name, path: path, isDirectory: false, size: info.size, fileCount: 1,
                                modified: info.modified, accessed: info.accessed)
            file.parent = node
            node.children.append(file)
        } else {
            node.smallBytes += info.size
        }
    }

    /// Turns the accumulated small bytes into one aggregate child and sorts children by size.
    private static func seal(_ node: FileNode) {
        if node.smallBytes > 0 {
            let aggregate = FileNode(name: String(localized: "Small files"), path: node.path + "/\u{0}small", isDirectory: false,
                                     size: node.smallBytes, isAggregate: true)
            aggregate.parent = node
            node.children.append(aggregate)
            node.smallBytes = 0
        }
        node.children.sort { $0.size > $1.size }
    }

    /// Visits every entry under `path`; the visitor returns false to stop.
    private static func walk(_ path: String, visit: (UnsafeMutablePointer<FTSENT>, Int32) -> Bool) {
        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(stream) }
        while let entry = fts_read(stream) {
            if !visit(entry, Int32(entry.pointee.fts_info)) { return }
        }
    }

    private static func ftsFill(_ root: FileNode, progress: ScanProgress, minNodeSize: Int64) {
        var stack: [FileNode] = []
        var pendingFiles = 0
        var pendingBytes: Int64 = 0

        walk(root.path) { entry, kind in
            switch kind {
            case FTS_D:
                if entry.pointee.fts_level == 0 {
                    stack.append(root)
                } else {
                    let path = String(cString: entry.pointee.fts_path)
                    stack.append(FileNode(name: (path as NSString).lastPathComponent, path: path, isDirectory: true))
                }
            case FTS_DP, FTS_DNR:
                // FTS_DNR (unreadable directory) replaces the post-order visit, so it closes the node too.
                guard let done = stack.popLast() else { break }
                if let st = entry.pointee.fts_statp { done.size += Int64(st.pointee.st_blocks) * 512 }
                guard let parent = stack.last else { seal(done); break }
                parent.size += done.size
                parent.fileCount += done.fileCount
                if done.size < minNodeSize {
                    parent.smallBytes += done.size
                } else {
                    seal(done)
                    done.parent = parent
                    parent.children.append(done)
                }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let top = stack.last, let st = entry.pointee.fts_statp else { break }
                let size = Int64(st.pointee.st_blocks) * 512
                top.size += size
                top.fileCount += 1
                if size >= minNodeSize {
                    let path = String(cString: entry.pointee.fts_path)
                    let file = FileNode(
                        name: (path as NSString).lastPathComponent, path: path, isDirectory: false,
                        size: size, fileCount: 1,
                        modified: Date(timeIntervalSince1970: TimeInterval(st.pointee.st_mtimespec.tv_sec)),
                        accessed: Date(timeIntervalSince1970: TimeInterval(st.pointee.st_atimespec.tv_sec)))
                    file.parent = top
                    top.children.append(file)
                } else {
                    top.smallBytes += size
                }
                pendingFiles += 1
                pendingBytes += size
                if pendingFiles == 4096 {
                    progress.add(files: pendingFiles, bytes: pendingBytes)
                    pendingFiles = 0
                    pendingBytes = 0
                    if progress.isCancelled { return false }
                }
            default:
                break
            }
            return true
        }
        progress.add(files: pendingFiles, bytes: pendingBytes)
    }
}
