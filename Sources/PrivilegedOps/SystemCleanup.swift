import Darwin
import Foundation

/// Old system-wide diagnostics and logs that only root can delete.
///
/// The root Helper runs this. The app can only name a target by id; the folders, file name
/// patterns, depth and the 30-day age limit are fixed here. Every file is checked and deleted
/// through directory file descriptors opened with `O_NOFOLLOW`, so a folder swapped for a
/// symbolic link between the scan and the delete cannot redirect a deletion elsewhere.
public struct SystemCleanupTarget: Sendable {
    public let id: String
    /// Absolute folder the target is confined to.
    public let root: String
    /// 1 = only files directly in `root`; 2 = also one level of subfolders.
    public let maxDepth: Int
    /// Files modified more recently than this are kept.
    public let minimumAge: TimeInterval
    /// File name test (no path).
    public let matches: @Sendable (String) -> Bool

    public init(id: String, root: String, maxDepth: Int, minimumAge: TimeInterval = SystemCleanup.minimumAge,
                matches: @escaping @Sendable (String) -> Bool) {
        self.id = id
        self.root = root
        self.maxDepth = maxDepth
        self.minimumAge = minimumAge
        self.matches = matches
    }
}

public struct SystemCleanupRequest: Codable, Sendable, Equatable {
    public var targetIDs: [String]
    public var dryRun: Bool

    public init(targetIDs: [String], dryRun: Bool) {
        self.targetIDs = targetIDs
        self.dryRun = dryRun
    }
}

public struct SystemCleanupResult: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public let path: String
        public let bytes: UInt64

        public init(path: String, bytes: UInt64) {
            self.path = path
            self.bytes = bytes
        }
    }

    public struct Failure: Codable, Sendable, Equatable {
        public let path: String
        public let message: String

        public init(path: String, message: String) {
            self.path = path
            self.message = message
        }
    }

    public struct Target: Codable, Sendable, Equatable {
        public let id: String
        public let dryRun: Bool
        /// Matching files (deleted ones when not a dry run). At most `SystemCleanup.listLimit` entries.
        public var files: [File]
        public var count: Int
        public var bytes: UInt64
        public var failures: [Failure]
        /// The folder could not be opened (missing on this macOS, or not readable).
        public var unavailable: String?

        public init(id: String, dryRun: Bool, files: [File], count: Int, bytes: UInt64, failures: [Failure], unavailable: String?) {
            self.id = id
            self.dryRun = dryRun
            self.files = files
            self.count = count
            self.bytes = bytes
            self.failures = failures
            self.unavailable = unavailable
        }
    }

    public var targets: [Target]

    public init(targets: [Target]) { self.targets = targets }

    public var count: Int { targets.reduce(0) { $0 + $1.count } }
    public var bytes: UInt64 { targets.reduce(0) { $0 + $1.bytes } }
}

public enum SystemCleanupError: Error, CustomStringConvertible, Equatable {
    case unknownTarget(String)

    public var description: String {
        switch self {
        case .unknownTarget(let id): "unknown system cleanup target \(id)"
        }
    }
}

public enum SystemCleanup {
    public static let minimumAgeDays = 30
    public static let minimumAge: TimeInterval = TimeInterval(minimumAgeDays) * 86_400
    /// Files listed per target in a result; counts and bytes always cover everything.
    public static let listLimit = 500

    static let diagnosticExtensions: Set<String> = ["ips", "crash", "diag", "spin", "hang", "panic", "shutdownStall"]

    /// `x.log`, `x.log.0`, `x.log.0.gz`, `x.log.bz2`.
    static func isLogName(_ name: String) -> Bool {
        name.range(of: #"\.log(\.[0-9]+)?(\.(gz|bz2))?$"#, options: .regularExpression) != nil
    }

    static func isDiagnosticName(_ name: String) -> Bool {
        diagnosticExtensions.contains((name as NSString).pathExtension)
    }

    /// The fixed allowlist. Nothing outside these folders is ever touched.
    public static let targets: [SystemCleanupTarget] = [
        // Crash, hang and resource reports for every user and the system, including Retired/.
        SystemCleanupTarget(id: "system.diagnostic-reports", root: "/Library/Logs/DiagnosticReports", maxDepth: 2,
                            matches: isDiagnosticName),
        // Log files directly in /Library/Logs; the per-app subfolders are left alone.
        SystemCleanupTarget(id: "system.logs", root: "/Library/Logs", maxDepth: 1, matches: isLogName),
    ]

    public static func target(_ id: String) -> SystemCleanupTarget? { targets.first { $0.id == id } }

    /// Resolves ids against the allowlist; any unknown id rejects the whole request.
    public static func resolve(_ ids: [String], in allowlist: [SystemCleanupTarget] = targets) throws -> [SystemCleanupTarget] {
        var seen = Set<String>()
        return try ids.compactMap { id in
            guard let t = allowlist.first(where: { $0.id == id }) else { throw SystemCleanupError.unknownTarget(id) }
            return seen.insert(id).inserted ? t : nil
        }
    }

    public static func run(_ request: SystemCleanupRequest, allowlist: [SystemCleanupTarget] = targets,
                           now: Date = Date()) throws -> SystemCleanupResult {
        let resolved = try resolve(request.targetIDs, in: allowlist)
        return SystemCleanupResult(targets: resolved.map { process($0, dryRun: request.dryRun, now: now) })
    }

    /// Scans (and unless `dryRun`, deletes) one target.
    public static func process(_ target: SystemCleanupTarget, dryRun: Bool, now: Date = Date()) -> SystemCleanupResult.Target {
        var result = SystemCleanupResult.Target(id: target.id, dryRun: dryRun, files: [], count: 0, bytes: 0, failures: [], unavailable: nil)
        guard target.root.hasPrefix("/"), !target.root.split(separator: "/").contains("..") else {
            result.unavailable = "invalid root"
            return result
        }
        let fd = open(target.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            result.unavailable = String(cString: strerror(errno))
            return result
        }
        defer { close(fd) }
        let cutoff = now.timeIntervalSince1970 - target.minimumAge
        walk(fd, path: target.root, depth: 1, target: target, cutoff: cutoff, dryRun: dryRun, into: &result)
        return result
    }

    private static func walk(_ dirFD: Int32, path: String, depth: Int, target: SystemCleanupTarget, cutoff: TimeInterval,
                             dryRun: Bool, into result: inout SystemCleanupResult.Target) {
        for name in entries(dirFD) {
            let full = path + "/" + name
            var st = stat()
            guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                guard depth < target.maxDepth else { continue }
                let child = openat(dirFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { continue }
                walk(child, path: full, depth: depth + 1, target: target, cutoff: cutoff, dryRun: dryRun, into: &result)
                close(child)
            case S_IFREG:
                // A second hard link means the data lives on somewhere else as well; leave it.
                guard st.st_nlink == 1, target.matches(name) else { continue }
                let modified = TimeInterval(st.st_mtimespec.tv_sec)
                guard modified < cutoff else { continue }
                let bytes = UInt64(max(0, st.st_blocks)) * 512
                if !dryRun {
                    // Same directory descriptor that was checked: the parent cannot have been swapped.
                    guard unlinkat(dirFD, name, 0) == 0 else {
                        result.failures.append(.init(path: full, message: String(cString: strerror(errno))))
                        continue
                    }
                }
                result.count += 1
                result.bytes += bytes
                if result.files.count < listLimit { result.files.append(.init(path: full, bytes: bytes)) }
            default:
                continue  // symbolic links, sockets, devices: never touched
            }
        }
    }

    /// Names in a directory, read up front so deleting does not disturb iteration.
    private static func entries(_ dirFD: Int32) -> [String] {
        let copy = dup(dirFD)
        guard copy >= 0, let dir = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }
}
