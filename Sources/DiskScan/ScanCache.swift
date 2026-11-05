import CryptoKit
import Foundation

/// One node of a saved scan tree: a serializable mirror of `DiskNode`.
/// Files that were too small to keep as nodes live in their directory's `smallFilesSize`.
public struct CachedNode: Codable, Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var modified: Date
    /// Allocated bytes on disk (as reported by the original scan).
    public var size: UInt64
    public var fileCount: Int
    public var smallFilesSize: UInt64
    public var smallFilesCount: Int
    /// errno captured during the scan if this directory could not be read, otherwise 0.
    public var readError: Int32
    /// True when this node stands for a cloud-only (dataless) folder that was skipped, never opened or read.
    public var skippedCloudOnly: Bool
    public var children: [CachedNode]

    public init(name: String, isDirectory: Bool, modified: Date, size: UInt64,
                fileCount: Int, smallFilesSize: UInt64, smallFilesCount: Int,
                readError: Int32, skippedCloudOnly: Bool, children: [CachedNode]) {
        self.name = name
        self.isDirectory = isDirectory
        self.modified = modified
        self.size = size
        self.fileCount = fileCount
        self.smallFilesSize = smallFilesSize
        self.smallFilesCount = smallFilesCount
        self.readError = readError
        self.skippedCloudOnly = skippedCloudOnly
        self.children = children
    }

    init(diskNode: DiskNode) {
        self.init(name: diskNode.name, isDirectory: diskNode.isDirectory, modified: diskNode.modified,
                  size: diskNode.size, fileCount: diskNode.fileCount,
                  smallFilesSize: diskNode.smallFilesSize, smallFilesCount: diskNode.smallFilesCount,
                  readError: diskNode.readError, skippedCloudOnly: diskNode.skippedCloudOnly,
                  children: diskNode.children.map(CachedNode.init(diskNode:)))
    }
}

/// A complete, restorable record of one scan.
///
/// Restored trees describe what was on disk at `scannedAt`; the volume may be unmounted,
/// permissions may have changed, or a path may now name different content. They exist so the
/// UI can show the previous picture together with `scannedAt`. They are never authoritative
/// for any operation that reads or removes data.
public struct ScanResultSnapshot: Codable, Sendable {
    public static let currentSchemaVersion = 1

    /// Bumped when the on-disk format changes; unknown versions are rejected on load.
    public let schemaVersion: Int
    /// Absolute path the scan was rooted at (symlinks resolved).
    public let rootPath: String
    public let scannedAt: Date
    public let elapsed: TimeInterval
    public let progress: ScanProgress
    public let root: CachedNode

    /// Captures `result`'s tree and scan metadata. Pure mapping with no I/O.
    public init(result: ScanResult, scannedAt: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        rootPath = result.root.path
        self.scannedAt = scannedAt
        elapsed = result.elapsed
        progress = result.progress
        root = CachedNode(diskNode: result.root)
    }

    /// Rebuilds the tree with `restoredFromCache` set on every node.
    /// Restoration must not open or traverse `rootPath`: every byte shown comes from this snapshot.
    public func rebuildTree() -> DiskNode? {
        func makeNode(from cached: CachedNode, parent: DiskNode?, rootPath: String?) -> DiskNode {
            let node = DiskNode(name: cached.name, isDirectory: cached.isDirectory, modified: cached.modified,
                                parent: parent, rootPath: rootPath)
            node.restoredFromCache = true
            node.size = cached.size
            node.fileCount = cached.fileCount
            node.smallFilesSize = cached.smallFilesSize
            node.smallFilesCount = cached.smallFilesCount
            node.readError = cached.readError
            node.skippedCloudOnly = cached.skippedCloudOnly
            return node
        }

        let rootNode = makeNode(from: root, parent: nil, rootPath: rootPath)
        // Iterative so very deep trees cannot overflow the stack.
        var stack: [(cached: CachedNode, parent: DiskNode)] = [(root, rootNode)]
        while let (cached, parent) = stack.popLast() {
            parent.children = cached.children.map { makeNode(from: $0, parent: parent, rootPath: nil) }
            for (cachedChild, node) in zip(cached.children, parent.children) {
                stack.append((cachedChild, node))
            }
        }
        return rootNode
    }
}

public enum ScanCacheError: Error, Equatable {
    /// A cancelled scan must never be persisted.
    case cancelledScan
}

/// Persistent store for one snapshot per scanned location.
///
/// Layout: `<directory>/<16 hex of SHA-256 of rootPath>.json`, sibling to the change-comparison
/// snapshots in `MacHelper/scans` but kept separate so the two never overwrite each other.
/// The directory is created owner-only (0o700) and files are written owner-only (0o600).
/// Snapshots contain absolute paths of the user's files; they stay on this Mac, are readable
/// only by this user, and are never uploaded or shared.
///
/// Reading a snapshot never opens, lists, or stats anything under `rootPath`; it only reads
/// the snapshot file itself. Saving is atomic (temporary file, then rename) and replaces only
/// the previous snapshot of that location. A cancelled scan persists nothing, so the previous
/// snapshot is left intact.
public struct ScanResultCache: Sendable {
    public static let defaultDirectoryName = "scan-results"

    public let directory: URL

    /// `nil` uses `~/Library/Application Support/MacHelper/scan-results`. Tests pass their own directory.
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacHelper/\(Self.defaultDirectoryName)")
    }

    /// Saves `snapshot`, atomically replacing this location's previous snapshot.
    public func save(_ snapshot: ScanResultSnapshot) throws {
        let url = fileURL(for: snapshot.rootPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // An existing directory keeps its old mode, so drop group and other access before
        // anything is written. The owner's own bits are left as they are.
        let mode = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int) ?? 0o700
        if mode & 0o077 != 0 {
            try FileManager.default.setAttributes([.posixPermissions: mode & 0o700], ofItemAtPath: directory.path)
        }
        // Atomic write: a temporary file in this directory, then rename, replacing the old snapshot.
        // The file is created owner-only, so its contents are never readable by others, not
        // even between the write and a later chmod.
        try Self.writeOwnerOnly(JSONEncoder().encode(snapshot), to: url)
    }

    private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == 0, fsync(fd) != 0 { failure = errno }
        close(fd)
        if failure == 0, rename(temporary, url.path) != 0 { failure = errno }
        if failure != 0 {
            unlink(temporary)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    /// Persists the outcome of a completed scan. A cancelled scan is refused before anything
    /// is written, so any previously saved snapshot stays intact.
    public func save(result: ScanResult, scannedAt: Date = Date()) throws {
        guard !result.cancelled else { throw ScanCacheError.cancelledScan }
        try save(ScanResultSnapshot(result: result, scannedAt: scannedAt))
    }

    /// Returns the saved snapshot for `rootPath`, or nil when it is missing, unreadable,
    /// carries another `rootPath`, or has an unsupported `schemaVersion`. Never touches `rootPath`.
    public func load(rootPath: String) -> ScanResultSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(for: rootPath)) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(ScanResultSnapshot.self, from: data) else { return nil }
        guard snapshot.schemaVersion == ScanResultSnapshot.currentSchemaVersion,
              snapshot.rootPath == rootPath else { return nil }
        return snapshot
    }

    /// Deletes the saved snapshot for `rootPath`. Succeeds when none exists.
    public func clear(rootPath: String) throws {
        do {
            try FileManager.default.removeItem(at: fileURL(for: rootPath))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Nothing saved for this location: clearing is already done.
        }
    }

    /// Exposed for tests that plant damaged snapshot files at the expected location.
    func fileURL(for rootPath: String) -> URL {
        let digest = SHA256.hash(data: Data(rootPath.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).json")
    }
}

/// Gate for any operation that reads or removes data.
///
/// A restored tree is a record of the past: the volume may be unmounted, permissions may have
/// changed, and a path may name different content than it did at scan time
/// (a file moved back to the cloud, or replaced by new content). None of these can be told
/// apart from inside the snapshot, so restored trees can be browsed only — no removing,
/// no collecting, and no content hashing (hashing would read the file and, for dataless
/// cloud files, could materialize it). Only a live scan re-authorizes those operations.
public enum ScanCacheSafety {
    /// True only when `node` itself came from a live scan. Every node of a restored tree carries
    /// `restoredFromCache`, so restored trees are rejected whether the caller passes the root or
    /// any descendant.
    public static func isLiveScan(_ node: DiskNode) -> Bool {
        !node.restoredFromCache
    }
}
