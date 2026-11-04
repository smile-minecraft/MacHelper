import CSystemBridge
import Darwin
import Foundation

public struct ScanOptions: Sendable {
    /// Files at least this large become their own nodes; smaller ones are aggregated per directory.
    public var keepFilesLargerThan: UInt64 = 1 << 20
    /// Descend into other volumes mounted below the root (default: stay on one device, like `du -x`).
    public var crossDevices = false
    public var threads = max(2, ProcessInfo.processInfo.activeProcessorCount)
    /// Absolute paths not to descend into.
    public var skipPaths: Set<String> = []

    public init() {}
}

public struct ScanProgress: Sendable {
    public var files: Int
    public var directories: Int
    public var bytes: UInt64
    public var unreadableDirectories: Int

    public init(files: Int, directories: Int, bytes: UInt64, unreadableDirectories: Int) {
        self.files = files
        self.directories = directories
        self.bytes = bytes
        self.unreadableDirectories = unreadableDirectories
    }
}

public struct ScanResult: Sendable {
    public let root: DiskNode
    public let progress: ScanProgress
    public let elapsed: TimeInterval
    public let cancelled: Bool
}

/// Parallel directory scanner built on getattrlistbulk(2).
///
/// - Sizes are allocated bytes (what the file actually occupies), not logical length.
/// - Hard links: counted once per (device, inode).
/// - APFS clones: the first member of a clone family counts its full allocation; later members
///   count only their private (unshared) bytes.
/// - Never follows symlinks; stays on the starting device unless `crossDevices`.
public final class DiskScanner: @unchecked Sendable {
    private let options: ScanOptions
    private let lock = NSLock()
    private var counters = ScanProgress(files: 0, directories: 0, bytes: 0, unreadableDirectories: 0)
    private var seenHardLinks = Set<UInt64>()
    private var seenClones = Set<UInt64>()
    private var cancelled = false

    public init(options: ScanOptions = ScanOptions()) { self.options = options }

    public var progress: ScanProgress { lock.withLock { counters } }

    public func cancel() { lock.withLock { cancelled = true } }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Blocking. Call from a background task.
    public func scan(_ url: URL) throws -> ScanResult {
        let start = Date()
        let rootPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        var st = stat()
        guard lstat(rootPath, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        let rootDevice = Int32(st.st_dev)
        let root = DiskNode(name: (rootPath as NSString).lastPathComponent, isDirectory: true,
                            modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                            parent: nil, rootPath: rootPath)

        let queue = WorkQueue(initial: (root, rootPath))
        let group = DispatchGroup()
        for _ in 0..<options.threads {
            group.enter()
            let thread = Thread { [self] in
                let capacity = 2048
                let buffer = UnsafeMutablePointer<MHDirEntry>.allocate(capacity: capacity)
                defer { buffer.deallocate(); group.leave() }
                while let (node, path) = queue.take() {
                    let subdirs = isCancelled ? [] : readDirectory(node, path: path, rootDevice: rootDevice,
                                                                   buffer: buffer, capacity: capacity)
                    queue.finish(adding: subdirs)
                }
            }
            thread.stackSize = 1 << 20
            thread.qualityOfService = .utility
            thread.start()
        }
        group.wait()

        root.finalize()
        return ScanResult(root: root, progress: progress, elapsed: Date().timeIntervalSince(start), cancelled: isCancelled)
    }

    /// Reads one directory; returns its subdirectories to scan next.
    private func readDirectory(_ node: DiskNode, path: String, rootDevice: Int32,
                               buffer: UnsafeMutablePointer<MHDirEntry>, capacity: Int) -> [(DiskNode, String)] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            node.readError = errno
            lock.withLock { counters.unreadableDirectories += 1 }
            return []
        }
        defer { close(fd) }

        var subdirs: [(DiskNode, String)] = []
        var files = 0
        var bytes: UInt64 = 0
        // Files whose storage may be shared (hard links, APFS clones); resolved under the global lock.
        var shared: [SharedFile] = []

        while true {
            let n = mh_read_dir_entries(fd, buffer, Int32(capacity))
            if n < 0 { node.readError = errno; break }
            if n == 0 { break }
            for i in 0..<Int(n) {
                let e = buffer[i]
                guard e.error == 0 else { continue }
                let name = withUnsafeBytes(of: e.name) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                let modified = Date(timeIntervalSince1970: TimeInterval(e.modTime))

                if e.objType == 2 { // VDIR
                    let childPath = path.hasSuffix("/") ? path + name : path + "/" + name
                    if !options.crossDevices, e.devID != rootDevice { continue }
                    if options.skipPaths.contains(childPath) { continue }
                    let child = DiskNode(name: name, isDirectory: true, modified: modified, parent: node)
                    node.children.append(child)
                    subdirs.append((child, childPath))
                    continue
                }

                files += 1
                let alloc = e.allocSize
                let keep = alloc >= options.keepFilesLargerThan
                    ? DiskNode(name: name, isDirectory: false, modified: modified, parent: node) : nil
                if let keep { node.children.append(keep) }

                if e.linkCount > 1 {
                    shared.append(SharedFile(kind: .hardLink, key: UInt64(UInt32(bitPattern: e.devID)) << 40 ^ e.fileID,
                                             full: alloc, unshared: 0, node: keep))
                } else if e.cloneRefCount > 1, e.cloneID != 0 {
                    shared.append(SharedFile(kind: .clone, key: e.cloneID, full: alloc, unshared: e.privateSize, node: keep))
                } else {
                    record(alloc, keep: keep, in: node)
                    bytes += alloc
                }
            }
        }

        lock.withLock {
            for f in shared {
                let first = f.kind == .hardLink ? seenHardLinks.insert(f.key).inserted : seenClones.insert(f.key).inserted
                // A repeated hard link occupies nothing extra; a repeated clone only its private blocks.
                let counted = first ? f.full : (f.kind == .hardLink ? 0 : f.unshared)
                record(counted, keep: f.node, in: node)
                bytes += counted
            }
            counters.files += files
            counters.directories += 1
            counters.bytes += bytes
        }
        return subdirs
    }

    private func record(_ size: UInt64, keep: DiskNode?, in dir: DiskNode) {
        if let keep {
            keep.size = size
        } else {
            dir.smallFilesSize += size
            dir.smallFilesCount += 1
        }
    }
}

private struct SharedFile {
    enum Kind { case hardLink, clone }
    let kind: Kind
    let key: UInt64
    let full: UInt64
    let unshared: UInt64
    let node: DiskNode?
}

/// Shared stack of directories to read. `take()` blocks until work is available and returns nil
/// once the stack is empty and no worker can produce more.
private final class WorkQueue: @unchecked Sendable {
    private let cond = NSCondition()
    private var pending: [(DiskNode, String)]
    private var active = 0
    private var done = false

    init(initial: (DiskNode, String)) { pending = [initial] }

    func take() -> (DiskNode, String)? {
        cond.lock()
        defer { cond.unlock() }
        while pending.isEmpty && active > 0 && !done { cond.wait() }
        if pending.isEmpty || done {
            done = true
            cond.broadcast()
            return nil
        }
        active += 1
        return pending.removeLast()
    }

    func finish(adding subdirs: [(DiskNode, String)]) {
        cond.lock()
        defer { cond.unlock() }
        pending.append(contentsOf: subdirs)
        active -= 1
        if !subdirs.isEmpty || active == 0 { cond.broadcast() }
    }
}
