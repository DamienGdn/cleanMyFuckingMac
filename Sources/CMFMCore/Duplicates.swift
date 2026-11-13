import CryptoKit
import Foundation

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String
    /// Size of one copy.
    public let size: Int64
    public var files: [FileNode]
    /// Space freed by keeping a single copy.
    public var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
}

public enum DuplicateFinder {
    private static let headLength = 64 * 1024

    /// Groups byte-identical files: same length, then same first 64 KB, then same SHA-256.
    public static func find(candidates: [FileNode], isCancelled: () -> Bool = { false }) -> [DuplicateGroup] {
        struct Candidate { let node: FileNode; let length: Int64 }
        var seenInodes = Set<UInt64>()
        var byLength: [Int64: [Candidate]] = [:]
        for node in candidates where !node.isDirectory && !node.isAggregate {
            var st = stat()
            guard lstat(node.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else { continue }
            // Hard links to one inode are a single file on disk, not duplicates.
            guard seenInodes.insert(UInt64(st.st_ino)).inserted else { continue }
            byLength[Int64(st.st_size), default: []].append(Candidate(node: node, length: Int64(st.st_size)))
        }

        var groups: [DuplicateGroup] = []
        for (length, sameLength) in byLength where sameLength.count > 1 {
            var byHead: [String: [Candidate]] = [:]
            for candidate in sameLength {
                if isCancelled() { return [] }
                guard let digest = hash(candidate.node.path, limit: headLength) else { continue }
                byHead[digest, default: []].append(candidate)
            }
            for sameHead in byHead.values where sameHead.count > 1 {
                var byFull: [String: [Candidate]] = [:]
                for candidate in sameHead {
                    if isCancelled() { return [] }
                    let digest = length <= Int64(headLength) ? "head" : hash(candidate.node.path, limit: nil)
                    guard let digest else { continue }
                    byFull[digest, default: []].append(candidate)
                }
                for (digest, identical) in byFull where identical.count > 1 {
                    let files = identical.map(\.node).sorted { $0.path < $1.path }
                    groups.append(DuplicateGroup(id: "\(length)-\(digest)-\(files[0].path)", size: files[0].size, files: files))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    private static func hash(_ path: String, limit: Int?) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            guard let chunk = try? handle.read(upToCount: min(remaining, 1 << 20)), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
