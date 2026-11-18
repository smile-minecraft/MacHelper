import Darwin
import Foundation

/// Sweep of agent test temp directories.
///
/// Agent-driven test suites (Cardiary) create their working directories with `mkdtemp()` directly
/// inside the user's private macOS temp folder, and nothing removes them. Only top-level entries of
/// the temp folder whose names are *exactly* a known test prefix followed by the six random
/// characters Node's `mkdtemp()` appends are touched, and only when they are old, unchanged, and
/// verifiably unused. Everything else — unknown names, other users' files, symlinks, mounted
/// filesystems, recently written children, open files — is skipped. Anything we cannot verify
/// means the whole sweep stands down and reports `verified: false`.
///
/// Removal follows the user's existing Auto Clean setting (`trashInstead`/`permanent`): the same
/// matrix low-risk rules use. With the Trash setting off (the default for older configs — missing
/// setting means delete) surviving candidates are deleted permanently, which is what actually frees
/// space; with the Trash setting on they move to the Trash and continue to occupy space until it is
/// emptied.
///
/// Open files are probed twice: once while planning and once again right before removal, together
/// with a re-walk of each surviving tree (see `run`). A process that opens a file inside a candidate
/// *during* the scan is caught in between. What neither probe nor re-check can close is a process
/// that opens its file in the instant between the final check and the removal: for a directory this
/// user owns there is no user-space barrier against that, and we do not pretend to close it.
public enum AgentTempClean {
    /// Identifier for the scheduled task outcome and the operations log.
    public static let taskID = "agent-temp.clean"
    /// Idle time a candidate must have accumulated before it may move. Not affected by the schedule frequency.
    public static let defaultRetention: TimeInterval = 7 * 86_400
    /// Upper bound on entries visited per candidate; protects the scheduled run from pathological trees.
    static let maxWalkedEntries = 200_000

    /// The only temporary directories this sweep considers, by exact prefix. Node's mkdtemp() appends
    /// six "[A-Za-z0-9]" characters to the prefix (verified with `node -e 'fs.mkdtempSync(...)'`).
    public static let knownPrefixes = [
        "cardiary-contract-", "cardiary-host-", "cardiary-import-",
        "cardiary-context-", "cardiary-mcp-concurrent-",
    ]

    static let nameRegex: NSRegularExpression = {
        let prefixes = knownPrefixes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "^(?:" + prefixes + ")[A-Za-z0-9]{6}$"
        // Force try: both the prefixes and the anchors are compile-time constants.
        return try! NSRegularExpression(pattern: pattern)
    }()

    public static func matchesKnownName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return nameRegex.firstMatch(in: name, range: range)?.range == range
    }

    /// How the removal action is chosen for a scheduled run: the same setting matrix the low-risk
    /// rules use. `permanent` wins; otherwise `trashInstead == true` removes to the Trash and
    /// anything else (including a missing setting) deletes permanently and frees space. Exposed so
    /// the scheduled run and its tests share one definition.
    public static func defaultOptions(for config: AutoCleanConfig) -> Options {
        var options = Options()
        options.useTrash = config.trashInstead == true && !config.permanent
        return options
    }

    /// What the sweep needs; defaults are the production values. Tests substitute the temp root,
    /// the `now` value, the open-files probe, and the executor (directory-backed removal backend).
    public struct Options: Sendable {
        /// nil = resolve and validate the production root (this user's macOS temp folder).
        public var tempRoot: URL?
        public var retention: TimeInterval = defaultRetention
        public var now: Date = Date()
        public var command: String = "autoclean"
        /// nil = the shared operations log. Tests pass an isolated log.
        public var log: OperationLog?
        /// nil = build a system-backed executor. Tests inject one with a directory-backed removal backend.
        public var executor: CleanExecutor?
        /// How survivors are removed. `true` (the default) moves them to the Trash; `false` deletes
        /// them permanently, which is what frees space. `AutoClean.run` sets this from the same
        /// setting matrix the low-risk rules use (`permanent` wins, then `trashInstead`), so an older
        /// config with no `trashInstead` deletes, matching the rest of Auto Clean.
        public var useTrash: Bool = true
        /// Returns the paths this user currently has open (cwd, files, sockets) as absolute paths,
        /// or nil when that cannot be established. Default is a single batched, NUL-field-delimited
        /// lsof invocation. Called twice per run: before planning and again before removal.
        public var openFiles: @Sendable (UInt32) -> [String]? = { uid in systemOpenFiles(uid: uid) }
        public init() {}
    }

    public struct AgentTempCleanResult: Sendable {
        /// False when the environment cannot be verified (temp root unusable or the open-file probe
        /// failed or changed). A root change stops subsequent removals.
        public let verified: Bool
        /// Why verification failed; nil otherwise.
        public let failure: String?
        public let items: [ItemOutcome]

        public init(verified: Bool, failure: String?, items: [ItemOutcome]) {
            self.verified = verified
            self.failure = failure
            self.items = items
        }

        public var movedCount: Int { items.filter { $0.result == .trashed || $0.result == .deleted }.count }
        public var movedBytes: UInt64 { items.filter { $0.result == .trashed || $0.result == .deleted }.reduce(0) { $0 + $1.bytes } }
        public var trashedCount: Int { items.filter { $0.result == .trashed }.count }
        public var deletedCount: Int { items.filter { $0.result == .deleted }.count }
        public var failedCount: Int { items.filter { $0.result == .failed }.count }
        public var skippedCount: Int { items.filter { $0.result == .skipped }.count }
        /// Task-level success: verification held and nothing failed to move.
        public var isSuccess: Bool { verified && failedCount == 0 }
        public var summary: String {
            if !verified { return failure ?? "could not be verified; nothing was touched" }
            var parts: [String] = []
            if trashedCount > 0 { parts.append("moved \(trashedCount) \(trashedCount == 1 ? "item" : "items") to the Trash (\(movedBytesOf(.trashed)) bytes)") }
            if deletedCount > 0 { parts.append("deleted \(deletedCount) \(deletedCount == 1 ? "item" : "items") (\(movedBytesOf(.deleted)) bytes)") }
            if parts.isEmpty { parts.append("nothing to remove") }
            if skippedCount > 0 { parts.append("skipped \(skippedCount)") }
            if failedCount > 0 { parts.append("\(failedCount) failed") }
            return parts.joined(separator: ", ")
        }
        private func movedBytesOf(_ kind: ItemOutcome.Result) -> UInt64 { items.filter { $0.result == kind }.reduce(0) { $0 + $1.bytes } }
    }

    /// Resolves and validates the production temp root. Anything unexpected means nil: the caller
    /// stands down. This is the macOS-supported per-user temp folder (FileManager backs it with
    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)`), normalized and checked module-internal before use.
    static func validatedTempRoot() -> URL? {
        let path = PathSafety.normalize(FileManager.default.temporaryDirectory.path)
        // e.g. /private/var/folders/62/8_c4v48d3zjdmkplgr9pp5s80000gn/T
        let shape = #"^/private/var/folders/[^/]{2}/[^/]+/T$"#
        guard path.range(of: shape, options: .regularExpression) != nil else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid() else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// One batched probe for this user's open files, cwds and sockets: `lsof -nP -u <uid> -F0pfn`.
    /// The process reports the candidate set directly, so checking 15k candidates costs one process
    /// instead of 15k. Fields are NUL-terminated (`-F0`), so a newline inside a name can never split
    /// a record into bogus fields. A non-zero exit, any stderr output, or output that does not match
    /// the expected field set means unverifiable — callers stand down.
    ///
    /// Darwin lsof privilege limits (as verified on macOS 26): scoped with `-u <uid>` it lists
    /// this user's own open files, which on macOS works for cwd and regular files alike (the deep
    /// cwd Swift test processes leave behind is included). Files of other users' processes are
    /// invisible (they also cannot traverse this user's private `/var/folders/.../T`, mode 0700),
    /// and any process lsof cannot inspect is reported on stderr — which fails the probe entirely,
    /// so unreadable means untouched. Deleted-but-open files still appear, so they count as in
    /// use as well. The full residual risk is a process opening a file in the instant between this
    /// probe (or the re-check before removal) and the actual removal; that cannot be excluded for
    /// a directory this user owns, and we do not claim it is.
    public static func systemOpenFiles(uid: UInt32) -> [String]? {
        let argv = ["/usr/sbin/lsof", "-nP", "-u", String(uid), "-F0pfn"]
        let (status, stdout, stderr) = execSeparated(argv, timeout: 15)
        guard status == 0, stderr.isEmpty else { return nil }
        return parseOpenFilesOutput(stdout)
    }

    /// Runs a command capturing stdout and stderr separately, killing it on timeout.
    static func execSeparated(_ argv: [String], timeout: TimeInterval) -> (status: Int32, stdout: Data, stderr: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, Data(), Data(error.localizedDescription.utf8)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, outData, errData)
    }

    /// Parses `-F0` output. Records are NUL-terminated; lsof ends each process set and each file
    /// set with an LF (012), so NL bytes can appear immediately before a field's identifier.
    /// Leading NL runs are stripped; every non-empty remainder must start with
    /// one of the requested field identifiers (`p`, `f`, `n`) — anything else means the output is
    /// not the expected shape and the whole probe is rejected, however clean the exit code was.
    /// Prefix and first-component matching downstream is pure-ASCII, so lossy UTF-8 decoding cannot
    /// hide a partial match. Note Darwin lsof 4.91 renders control characters inside names
    /// (e.g. LF) as escape sequences; deep path bytes are therefore never compared — matching only
    /// ever relies on the pure-ASCII prefix and first path component.
    static func parseOpenFilesOutput(_ data: Data) -> [String]? {
        var paths: [String] = []
        for raw in data.split(separator: 0, omittingEmptySubsequences: false) {
            var start = raw.startIndex
            while start < raw.endIndex, raw[start] == 0x0A { start = raw.index(after: start) }   // leading LF runs
            if start == raw.endIndex { continue }
            let first = raw[start]
            guard first == 0x70 || first == 0x66 || first == 0x6E else { return nil }              // p, f, n
            if first == 0x6E {                                                                      // n
                paths.append(String(decoding: raw[raw.index(after: start)...], as: UTF8.self))
            }
        }
        return paths
    }

    public static func run(options: Options = Options()) -> AgentTempCleanResult {
        guard let rootURL = options.tempRoot ?? validatedTempRoot() else {
            return AgentTempCleanResult(verified: false, failure: "the user's temporary folder could not be verified; nothing was touched", items: [])
        }
        let rootPath = PathSafety.normalize(rootURL.path)
        var rst = stat()
        guard lstat(rootPath, &rst) == 0, (rst.st_mode & S_IFMT) == S_IFDIR, rst.st_uid == getuid() else {
            return AgentTempCleanResult(verified: false, failure: "the temp root is not a directory owned by this user; nothing was touched", items: [])
        }
        let rootDev = rst.st_dev

        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: rootPath)
        } catch {
            return AgentTempCleanResult(verified: false, failure: "could not list the temp folder: \(error.localizedDescription); nothing was touched", items: [])
        }
        let candidates = names.filter(matchesKnownName).sorted()
        guard !candidates.isEmpty else { return AgentTempCleanResult(verified: true, failure: nil, items: []) }

        // Phase 1: one batched open-file probe, then the per-candidate checks.
        guard let openPaths = options.openFiles(getuid()) else {
            return AgentTempCleanResult(verified: false, failure: "could not check which files are open (lsof); nothing was touched", items: [])
        }
        let inUse = inUseCandidates(rootPath: rootPath, candidates: candidates, openPaths: openPaths)

        var items: [ItemOutcome] = []
        let survivors = filterCandidates(candidates, rootPath: rootPath, rootDev: rootDev, options: options, inUse: inUse, into: &items)
        guard !survivors.isEmpty else {
            return AgentTempCleanResult(verified: true, failure: nil, items: items)
        }

        // Phase 2 (final snapshot before removal): re-probe open files first, then re-verify the
        // root and every survivor as late as possible, so a replacement that happened during the
        // scan window is caught here and reported as unverifiable instead of silently skipped.
        guard let reOpenPaths = options.openFiles(getuid()) else {
            for candidate in survivors { items.append(skip(candidate.path, "could not be re-checked before removal")) }
            return AgentTempCleanResult(verified: false, failure: "could not re-check which files are open before removal; nothing was removed", items: items)
        }
        let reInUse = inUseCandidates(rootPath: rootPath, candidates: survivors.map(\.name), openPaths: reOpenPaths)
        let log = options.log ?? .shared
        let safety = PathSafety(protectedPaths: [], whitelist: [], allowedRoots: [rootPath], minimumDepth: 1)
        let executor = options.executor ?? CleanExecutor(safety: safety, log: log)
        var outcomes: [ItemOutcome] = []
        var failure: String?

        // The process snapshot is shared across the batch. File metadata is rechecked per item,
        // immediately before attempting removal. Neither check excludes concurrent access atomically.
        for candidate in survivors {
            guard failure == nil, sameRoot(rootPath, as: rst) else {
                failure = "the temp folder changed during the scan"
                items.append(skip(candidate.path, "the temp folder changed during the scan"))
                continue
            }
            if reInUse.contains(candidate.name) { items.append(skip(candidate.path, "in use (re-checked before removal)")); continue }
            var st = stat()
            guard lstat(candidate.path, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFDIR,
                  st.st_uid == getuid(),
                  Int64(st.st_dev) == candidate.device,
                  UInt64(st.st_ino) == candidate.inode else {
                items.append(skip(candidate.path, "the directory changed during the scan"))
                continue
            }
            let rewalk = walkTree(candidate.path, rootDev: rootDev, rootMtime: modificationDate(of: st))
            guard rewalk.ok,
                  rewalk.newest == candidate.walk.newest,
                  rewalk.bytes == candidate.walk.bytes else {
                items.append(skip(candidate.path, "the directory changed during the scan"))
                continue
            }
            if options.now.timeIntervalSince(rewalk.newest) < options.retention {
                items.append(skip(candidate.path, "changed within the retention period"))
                continue
            }
            var afterWalk = stat()
            guard sameRoot(rootPath, as: rst), lstat(candidate.path, &afterWalk) == 0,
                  afterWalk.st_dev == st.st_dev, afterWalk.st_ino == st.st_ino,
                  afterWalk.st_mode == st.st_mode, afterWalk.st_uid == st.st_uid,
                  afterWalk.st_ctimespec.tv_sec == st.st_ctimespec.tv_sec,
                  afterWalk.st_ctimespec.tv_nsec == st.st_ctimespec.tv_nsec else {
                items.append(skip(candidate.path, "the directory changed during the final check"))
                continue
            }
            let removal = RemovalItem(path: candidate.path, source: taskID, bytes: rewalk.bytes,
                                      action: options.useTrash ? .trash : .delete)
            outcomes.append(executor.executeItem(removal, dryRun: false))
        }
        executor.log.append(command: options.command, outcomes: outcomes)
        return AgentTempCleanResult(verified: failure == nil, failure: failure, items: items + outcomes)
    }

    private static func sameRoot(_ path: String, as original: stat) -> Bool {
        var current = stat()
        return lstat(path, &current) == 0 && (current.st_mode & S_IFMT) == S_IFDIR
            && current.st_uid == original.st_uid && current.st_dev == original.st_dev
            && current.st_ino == original.st_ino
    }

    /// A candidate that survived every first-pass check, pinned with the directory's device and
    /// inode so the final pre-removal pass can prove it is the same object, together with the walk
    /// that proved it old and unchanged.
    private struct VerifiedCandidate {
        let name: String
        let path: String
        let device: Int64
        let inode: UInt64
        let walk: Walk
    }

    /// Splits the first-pass candidates into survivors and skips (with reasons), recording skips
    /// into `items`. The survivors still must pass the final re-check in `run` before removal.
    private static func filterCandidates(_ candidates: [String], rootPath: String, rootDev: dev_t,
                                         options: Options, inUse: Set<String>,
                                         into items: inout [ItemOutcome]) -> [VerifiedCandidate] {
        var verified: [VerifiedCandidate] = []
        for name in candidates {
            let path = rootPath + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else { items.append(skip(path, "could not be inspected")); continue }
            guard (st.st_mode & S_IFMT) == S_IFDIR else { items.append(skip(path, "not a directory")); continue }
            guard st.st_uid == getuid() else { items.append(skip(path, "owned by another user")); continue }
            guard Int64(st.st_dev) == Int64(rootDev) else { items.append(skip(path, "mounted filesystem")); continue }
            if inUse.contains(name) { items.append(skip(path, "in use (an open file or working directory points inside)")); continue }
            let walk = walkTree(path, rootDev: rootDev, rootMtime: modificationDate(of: st))
            guard walk.ok else { items.append(skip(path, walk.error ?? "could not be verified")); continue }
            if options.now.timeIntervalSince(walk.newest) < options.retention {
                items.append(skip(path, "changed within the retention period"))
                continue
            }
            verified.append(VerifiedCandidate(name: name, path: path, device: Int64(st.st_dev), inode: UInt64(st.st_ino), walk: walk))
        }
        return verified
    }

    /// Names of candidates whose tree is referenced by at least one open path. Paths from lsof are
    /// run through the same normalization as the root, so alias prefixes still match. Used for the
    /// planning probe and again for the final pre-removal probe.
    static func inUseCandidates(rootPath: String, candidates: [String], openPaths: [String]) -> Set<String> {
        let prefix = rootPath + "/"
        let nameSet = Set(candidates)
        var hits = Set<String>()
        for raw in openPaths {
            let path = PathSafety.normalize(raw)
            guard path.hasPrefix(prefix) else { continue }
            let rest = path.dropFirst(prefix.count)
            let first = rest.prefix { $0 != "/" }
            if nameSet.contains(String(first)) { hits.insert(String(first)) }
        }
        return hits
    }

    struct Walk {
        let bytes: UInt64
        let newest: Date
        let ok: Bool
        let error: String?
    }

    /// Iterative post-order-free walk: sums entry sizes, tracks the newest mtime, and verifies that
    /// every descendant has the expected owner and sits on the same filesystem. Symlinks are never followed.
    static func walkTree(_ path: String, rootDev: dev_t, rootMtime: Date, expectedUID: uid_t = getuid()) -> Walk {
        var bytes: UInt64 = 0
        var newest = rootMtime
        var visited = 0
        var stack = [path]
        while let dir = stack.popLast() {
            let entries: [String]
            do {
                entries = try FileManager.default.contentsOfDirectory(atPath: dir)
            } catch {
                return Walk(bytes: 0, newest: newest, ok: false, error: "could not read \(dir)")
            }
            for entry in entries {
                visited += 1
                if visited > maxWalkedEntries {
                    return Walk(bytes: 0, newest: newest, ok: false, error: "too many items to verify")
                }
                let child = dir + "/" + entry
                var st = stat()
                guard lstat(child, &st) == 0 else {
                    return Walk(bytes: 0, newest: newest, ok: false, error: "could not inspect \(child)")
                }
                guard Int64(st.st_dev) == Int64(rootDev) else {
                    return Walk(bytes: 0, newest: newest, ok: false, error: "\(child) is a mounted filesystem")
                }
                guard st.st_uid == expectedUID else {
                    return Walk(bytes: 0, newest: newest, ok: false, error: "\(child) is owned by another user")
                }
                bytes += UInt64(max(0, Int64(st.st_size)))
                let m = modificationDate(of: st)
                if m > newest { newest = m }
                if (st.st_mode & S_IFMT) == S_IFDIR { stack.append(child) }
            }
        }
        return Walk(bytes: bytes, newest: newest, ok: true, error: nil)
    }

    static func modificationDate(of st: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    static func skip(_ path: String, _ reason: String) -> ItemOutcome {
        ItemOutcome(path: path, source: taskID, bytes: 0, result: .skipped, message: reason)
    }
}
