import CoreServices
import Foundation

/// Suggestions found in a scanned tree: big files that look unused, and folders that look bloated
/// (grew a lot since the last scan, oversized caches or logs, or crammed with files). Read-only.
public struct SpaceInsights: Codable, Sendable {
    public struct Options: Sendable {
        /// Files at least this big are checked for use.
        public var minFileSize: UInt64 = 100 << 20
        /// Not opened, changed or added for this many days.
        public var unusedDays = 180
        /// A folder that grew by at least this much since the previous scan…
        public var grewBy: UInt64 = 1 << 30
        /// …and by at least this share of its old size (new folders always count).
        public var grewRatio = 0.5
        public var largeCache: UInt64 = 5 << 30
        public var largeLogs: UInt64 = 1 << 30
        /// Files directly inside one folder.
        public var manyFiles = 50_000
        public var limit = 200

        public init() {}
    }

    public struct UnusedFile: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable { case diskImage, archive, installer, video, virtualMachine, other }
        public var id: String { path }
        public let path: String
        public let size: UInt64
        /// The latest of: last opened (Spotlight), modified, added to its folder.
        public let lastUsed: Date
        public let kind: Kind
    }

    public struct BloatedFolder: Codable, Sendable, Hashable, Identifiable {
        public enum Reason: String, Codable, Sendable, Comparable {
            case grew, largeCache, largeLogs, manyFiles
            private var rank: Int { [.grew: 0, .largeCache: 1, .largeLogs: 2, .manyFiles: 3][self]! }
            public static func < (a: Reason, b: Reason) -> Bool { a.rank < b.rank }
        }
        public var id: String { path }
        public let path: String
        public let size: UInt64
        public var reasons: [Reason]
        /// Growth since `since` (reason `grew`).
        public var grownBy: UInt64?
        public var since: Date?
        /// Files directly inside (reason `manyFiles`).
        public var directFiles: Int?
        /// The biggest item inside and its size, to say where the space is.
        public var largestChild: String?
        public var largestChildSize: UInt64?
    }

    public let schemaVersion: Int
    public let root: String
    public let generatedAt: Date
    public let unusedDays: Int
    public let unusedFiles: [UnusedFile]
    public let bloatedFolders: [BloatedFolder]

    public var unusedBytes: UInt64 { unusedFiles.reduce(0) { $0 + $1.size } }

    /// `lastUse` returns when a file was last opened or added (Spotlight); injectable for tests.
    public static func find(in root: DiskNode, previous: ScanSnapshot? = nil, options: Options = Options(),
                            now: Date = Date(), lastUse: (String) -> Date? = SpaceInsights.spotlightLastUse) -> SpaceInsights {
        let cutoff = now.addingTimeInterval(-TimeInterval(options.unusedDays) * 86_400)
        var unused: [UnusedFile] = []
        var folders: [String: BloatedFolder] = [:]
        let rootPath = root.path

        func add(_ n: DiskNode, _ reason: BloatedFolder.Reason, update: (inout BloatedFolder) -> Void = { _ in }) {
            var f = folders[n.path] ?? BloatedFolder(path: n.path, size: n.size, reasons: [])
            if !f.reasons.contains(reason) { f.reasons.append(reason); f.reasons.sort() }
            if let big = n.children.max(by: { $0.size < $1.size }), n.size > 0, Double(big.size) >= 0.3 * Double(n.size) {
                f.largestChild = big.name
                f.largestChildSize = big.size
            }
            update(&f)
            folders[n.path] = f
        }

        // (node, inside a package or hidden tool folder, inside a Library folder)
        var stack: [(DiskNode, Bool, Bool)] = [(root, false, false)]
        while let (n, skipped, library) = stack.popLast() {
            let inside = skipped || (n !== root && Self.isSkipped(n.name))
            let inLibrary = library || (n.isDirectory && n.name == "Library")
            if !n.isDirectory {
                // Files under a Library folder belong to apps, not to the user: never suggested.
                // Model weights are read by AI tools without updating any date, so their age says nothing.
                if !inside, !inLibrary, n.size >= options.minFileSize, n.modified < cutoff, !Self.isModelWeights(n.name) {
                    let last = max(n.modified, lastUse(n.path) ?? .distantPast)
                    if last < cutoff { unused.append(UnusedFile(path: n.path, size: n.size, lastUsed: last, kind: Self.kind(n.name))) }
                }
                continue
            }
            if !inside, n !== root {
                let lower = n.name.lowercased()
                if Self.cacheNames.contains(lower), n.size >= options.largeCache { add(n, .largeCache) }
                if Self.logNames.contains(lower), n.size >= options.largeLogs { add(n, .largeLogs) }
                if n.smallFilesCount + n.children.filter({ !$0.isDirectory }).count >= options.manyFiles {
                    let count = n.smallFilesCount + n.children.filter { !$0.isDirectory }.count
                    add(n, .manyFiles) { $0.directFiles = count }
                }
            }
            stack.append(contentsOf: n.children.map { ($0, inside, inLibrary) })
        }

        // Growth since the previous scan of the same place: the deepest folder that explains it.
        if let previous, previous.root == rootPath {
            // Same depth and size floor as the saved snapshots (smaller only for tiny test thresholds).
            let current = ScanSnapshot(root: root, date: now, minSize: min(10 << 20, options.grewBy / 10))
            for c in current.changes(since: previous, minDelta: options.grewBy, limit: 50) where c.delta > 0 {
                let before = c.before ?? 0
                guard before == 0 || Double(c.delta) >= options.grewRatio * Double(before),
                      c.path != rootPath, let node = root.descendant(atPath: c.path), !Self.pathIsSkipped(c.path, under: rootPath) else { continue }
                add(node, .grew) { f in
                    f.grownBy = UInt64(c.delta)
                    f.since = previous.date
                }
            }
        }

        // A folder whose finding is explained by a flagged folder inside it (≥ 80 % of its size) is left out.
        let all = Array(folders.values)
        let bloated = all.filter { parent in
            !all.contains { child in
                child.path.hasPrefix(parent.path + "/") && Double(child.size) >= 0.8 * Double(parent.size)
                    && Set(child.reasons).isSuperset(of: parent.reasons)
            }
        }
        return SpaceInsights(schemaVersion: 1, root: rootPath, generatedAt: now, unusedDays: options.unusedDays,
                             unusedFiles: Array(unused.sorted { $0.size > $1.size }.prefix(options.limit)),
                             bloatedFolders: Array(bloated.sorted { $0.size > $1.size }.prefix(options.limit)))
    }

    // MARK: Rules

    static let cacheNames: Set<String> = ["caches", "cache", ".cache", "cachedata", "code cache", "gpucache", "deriveddata", "_cacache"]
    static let logNames: Set<String> = ["logs", "log", "diagnosticreports"]

    /// Packages and app data that the user doesn't manage file by file (photo and music libraries,
    /// app bundles, version control, the Trash), and hidden tool folders.
    static let packageExtensions: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle",
                                                 "logicx", "band", "aplibrary", "xcarchive", "framework", "bundle", "plugin",
                                                 "photolibrary", "migratedphotolibrary", "lrdata", "lrcat-data", "nosync"]

    static func isSkipped(_ name: String) -> Bool {
        if [".Trash", ".Trashes", ".git", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", "node_modules"].contains(name) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && packageExtensions.contains(ext)
    }

    /// Growth inside packages and the Trash is not reported either.
    static func pathIsSkipped(_ path: String, under root: String) -> Bool {
        path.dropFirst(root.count).split(separator: "/").contains { isSkipped(String($0)) }
    }

    static let modelExtensions: Set<String> = ["safetensors", "gguf", "ggml", "ckpt", "pt", "pth", "onnx", "mlmodel", "npz", "h5", "tflite"]

    static func isModelWeights(_ name: String) -> Bool { modelExtensions.contains((name as NSString).pathExtension.lowercased()) }

    static func kind(_ name: String) -> UnusedFile.Kind {
        switch (name as NSString).pathExtension.lowercased() {
        case "dmg", "iso", "img", "sparseimage", "cdr": .diskImage
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst": .archive
        case "pkg", "mpkg", "xip", "ipsw": .installer
        case "mov", "mp4", "m4v", "mkv", "avi", "webm", "mts", "braw", "r3d": .video
        case "vmdk", "vdi", "qcow2", "utm", "pvm", "hdd", "vhd", "vhdx": .virtualMachine
        default: .other
        }
    }

    /// Spotlight's last-opened and date-added for a file; nil when Spotlight knows neither.
    public static func spotlightLastUse(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        let added = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
        return [used, added].compactMap { $0 }.max()
    }
}
