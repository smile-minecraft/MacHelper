import CryptoKit
import Darwin
import Foundation

/// Files with identical content.
public struct DuplicateGroup: Codable, Sendable, Hashable, Identifiable {
    public struct File: Codable, Sendable, Hashable, Identifiable {
        public var id: String { path }
        public let path: String
        public let modified: Date
        /// An APFS clone of another file in the group: they share storage, so deleting just one of them
        /// frees (almost) nothing.
        public let sharesStorage: Bool
    }

    public var id: String { hash }
    public let hash: String
    /// Size of one copy, in bytes.
    public let size: UInt64
    /// Oldest first: the usual one to keep.
    public let files: [File]

    /// Space freed by keeping one copy: clones of one another count as a single copy.
    public let reclaimable: UInt64
}

public enum DuplicateFinder {
    /// Finds groups of identical regular files among `paths` (files only, symlinks ignored). Content is
    /// compared by size, then the first and last 64 KB, then a full SHA-256.
    public static func find(paths: [String], minSize: UInt64 = 1 << 20,
                            isCancelled: @Sendable () -> Bool = { false }) -> [DuplicateGroup] {
        struct Info { let path: String; let size: UInt64; let dev: Int32; let ino: UInt64; let modified: Date; let clone: UInt64 }
        var bySize: [UInt64: [Info]] = [:]
        for p in Set(paths) {
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, UInt64(st.st_size) >= minSize else { continue }
            let info = Info(path: p, size: UInt64(st.st_size), dev: st.st_dev, ino: st.st_ino,
                            modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)), clone: cloneID(p))
            bySize[info.size, default: []].append(info)
        }
        var groups: [DuplicateGroup] = []
        for (size, infos) in bySize where infos.count > 1 {
            if isCancelled() { break }
            // Hard links are one file: keep one path per (device, inode).
            var seenInode: Set<String> = []
            var unique: [Info] = []
            for i in infos {
                if seenInode.insert("\(i.dev):\(i.ino)").inserted { unique.append(i) }
            }
            guard unique.count > 1 else { continue }
            let byQuick = Dictionary(grouping: unique) { quickHash($0.path, size: size) ?? "" }
            for (quick, candidates) in byQuick where !quick.isEmpty && candidates.count > 1 {
                let byFull = Dictionary(grouping: candidates) { fullHash($0.path, isCancelled: isCancelled) ?? "" }
                for (hash, same) in byFull where !hash.isEmpty && same.count > 1 {
                    let clones = Dictionary(grouping: same.filter { $0.clone != 0 }, by: \.clone).filter { $0.value.count > 1 }
                    let cloneIDs = Set(clones.keys)
                    let files = same.sorted { $0.modified < $1.modified }.map {
                        DuplicateGroup.File(path: $0.path, modified: $0.modified, sharesStorage: cloneIDs.contains($0.clone))
                    }
                    // Independent copies on disk: each unshared file, plus one per clone family.
                    let copies = same.filter { !cloneIDs.contains($0.clone) }.count + cloneIDs.count
                    groups.append(DuplicateGroup(hash: hash, size: size, files: files,
                                                 reclaimable: size * UInt64(max(copies - 1, 0))))
                }
            }
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    static func quickHash(_ path: String, size: UInt64) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        let chunk = 65_536
        guard let head = try? h.read(upToCount: chunk) ?? Data() else { return nil }
        hasher.update(data: head)
        if size > UInt64(chunk * 2) {
            try? h.seek(toOffset: size - UInt64(chunk))
            if let tail = try? h.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ path: String, isCancelled: @Sendable () -> Bool) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() { return nil }
            let data: Data?
            do { data = try h.read(upToCount: 4 << 20) } catch { return nil }
            guard let data, !data.isEmpty else { break }   // nil or empty: end of file
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// APFS clone ID (0 if not on APFS or unavailable). Files with the same ID share blocks.
    static func cloneID(_ path: String) -> UInt64 {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)
        var buf = [UInt8](repeating: 0, count: 32)
        let rc = buf.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) }
        guard rc == 0 else { return 0 }
        return buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
    }
}

// MARK: - Scan snapshots (what changed since the last scan)

/// Directory sizes from one scan, saved so the next scan of the same folder can show what grew.
public struct ScanSnapshot: Codable, Sendable {
    public let root: String
    public let date: Date
    /// Directory path → allocated bytes, for directories of at least `minSize` up to `depth` levels.
    public let sizes: [String: UInt64]

    public init(root: DiskNode, date: Date = Date(), depth: Int = 6, minSize: UInt64 = 10 << 20) {
        self.root = root.path
        self.date = date
        var sizes: [String: UInt64] = [:]
        var stack: [(DiskNode, Int)] = [(root, 0)]
        while let (n, d) = stack.popLast() {
            guard n.isDirectory, n.size >= minSize else { continue }
            sizes[n.path] = n.size
            if d < depth { stack.append(contentsOf: n.children.map { ($0, d + 1) }) }
        }
        self.sizes = sizes
    }

    public struct Change: Codable, Sendable, Hashable, Identifiable {
        public var id: String { path }
        public let path: String
        public let before: UInt64?
        public let after: UInt64?
        public var delta: Int64 { Int64(after ?? 0) - Int64(before ?? 0) }
    }

    /// Biggest changes from `old` to `self`, most significant first. Only the deepest changed folder of
    /// a chain is reported (a parent that grew only because its child did is left out).
    public func changes(since old: ScanSnapshot, minDelta: UInt64 = 50 << 20, limit: Int = 40) -> [Change] {
        let paths = Set(sizes.keys).union(old.sizes.keys)
        var changes = paths.compactMap { p -> Change? in
            let c = Change(path: p, before: old.sizes[p], after: sizes[p])
            return c.delta.magnitude >= minDelta ? c : nil
        }
        // Drop a parent whose change is explained (≥ 80 %) by one of its changed children.
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        changes.removeAll { parent in
            byPath.values.contains { child in
                child.path.hasPrefix(parent.path + "/") && (child.delta.signum() == parent.delta.signum())
                    && Double(child.delta.magnitude) >= 0.8 * Double(parent.delta.magnitude)
            }
        }
        return Array(changes.sorted { $0.delta.magnitude > $1.delta.magnitude }.prefix(limit))
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/MacHelper/scans")
    }

    static func file(for root: String) -> URL {
        let digest = SHA256.hash(data: Data(root.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).json")
    }

    /// The last saved snapshot of `root`, if any.
    public static func load(root: String) -> ScanSnapshot? {
        guard let data = try? Data(contentsOf: file(for: root)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(ScanSnapshot.self, from: data)
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try e.encode(self).write(to: Self.file(for: root), options: .atomic)
    }
}

// MARK: - File kinds (for filtering)

public enum FileKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case video, image, audio, archive, diskImage, application, document, developer, other
    public var id: String { rawValue }

    private static let table: [FileKind: Set<String>] = [
        .video: ["mov", "mp4", "m4v", "mkv", "avi", "wmv", "flv", "webm", "mts", "m2ts", "mpg", "mpeg", "3gp", "braw", "r3d"],
        .image: ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "raw", "cr2", "cr3", "nef", "arw",
                 "dng", "psd", "ai", "svg", "exr"],
        .audio: ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "ogg", "opus", "caf", "logicx"],
        .archive: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz4", "cpgz"],
        .diskImage: ["dmg", "iso", "img", "sparseimage", "sparsebundle", "vmdk", "vdi", "qcow2", "raw-img", "xip", "pkg", "mpkg", "ipsw"],
        .application: ["app", "ipa", "apk", "exe", "msi"],
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "rtf", "md", "epub", "csv"],
        .developer: ["o", "a", "dylib", "so", "jar", "class", "pyc", "wasm", "sqlite", "db", "log", "core", "dSYM"],
    ]

    public static func of(_ name: String) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        return table.first { $0.value.contains(ext) }?.key ?? .other
    }
}
