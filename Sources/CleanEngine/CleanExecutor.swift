import Foundation

public struct ItemOutcome: Codable, Sendable {
    public enum Result: String, Codable, Sendable { case trashed, deleted, wouldTrash, wouldDelete, skipped, failed }
    public let path: String
    public let source: String      // rule id, artifact detector id, …
    public let bytes: UInt64
    public let result: Result
    public let message: String?
}

public struct CleanReport: Codable, Sendable {
    public let schemaVersion: Int
    public let dryRun: Bool
    public let items: [ItemOutcome]

    public init(schemaVersion: Int, dryRun: Bool, items: [ItemOutcome]) {
        self.schemaVersion = schemaVersion
        self.dryRun = dryRun
        self.items = items
    }

    /// Space actually released now (permanent deletions).
    public var freedBytes: UInt64 { items.filter { $0.result == .deleted }.reduce(0) { $0 + $1.bytes } }
    /// Moved to the Trash: released once the Trash is emptied.
    public var trashedBytes: UInt64 { items.filter { $0.result == .trashed }.reduce(0) { $0 + $1.bytes } }
    public var plannedBytes: UInt64 {
        items.filter { $0.result == .wouldTrash || $0.result == .wouldDelete }.reduce(0) { $0 + $1.bytes }
    }
    public var failures: [ItemOutcome] { items.filter { $0.result == .failed } }
}

/// A removal request: what, how, and on whose behalf.
public struct RemovalItem: Sendable {
    public let path: String
    public let source: String
    public let bytes: UInt64
    public let action: CleanAction
    /// Bundle identifiers that must not be running for this item to be removed.
    public let skipIfRunning: [String]
    /// Executable names that must not be running for this item to be removed. Matched against the
    /// first 32 characters of the name, case-insensitively.
    public let skipIfProcessRunning: [String]
    /// The rule's age condition, re-checked at removal time: a file modified since the preview
    /// (a resumed session appending to it, for example) is left in place. 0 means no condition.
    public let minAgeDays: Int
    public init(path: String, source: String, bytes: UInt64, action: CleanAction,
                skipIfRunning: [String] = [], skipIfProcessRunning: [String] = [], minAgeDays: Int = 0) {
        self.path = path
        self.source = source
        self.bytes = bytes
        self.action = action
        self.skipIfRunning = skipIfRunning
        self.skipIfProcessRunning = skipIfProcessRunning
        self.minAgeDays = minAgeDays
    }
}

/// The two removal operations the executor can perform. Production always uses the system Trash
/// and permanent deletion; tests inject a directory-backed backend so they can exercise the real
/// executor without touching the user's Trash.
enum RemovalBackend: Sendable {
    case system
    case custom(trash: @Sendable (URL) throws -> Void, delete: @Sendable (URL) throws -> Void)

    func trash(_ url: URL) throws {
        switch self {
        case .system: try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        case .custom(let trash, _): try trash(url)
        }
    }

    func delete(_ url: URL) throws {
        switch self {
        case .system: try FileManager.default.removeItem(at: url)
        case .custom(_, let delete): try delete(url)
        }
    }
}

public struct CleanExecutor: Sendable {
    public let safety: PathSafety
    public let log: OperationLog
    /// Override: delete permanently instead of moving to the Trash.
    public let permanent: Bool
    /// Override: move everything to the Trash, even items whose rule deletes them. Items already in
    /// the Trash (emptying it) are still deleted. Ignored when `permanent` is set.
    public let alwaysTrash: Bool

    let removal: RemovalBackend
    /// Where the per-item guard reads "is it running?" from. Re-read for every item, never a
    /// snapshot from the start of the batch.
    let running: RunningApplications

    public init(safety: PathSafety, log: OperationLog = .shared, permanent: Bool = false, alwaysTrash: Bool = false) {
        self.init(safety: safety, log: log, permanent: permanent, alwaysTrash: alwaysTrash, removal: .system,
                  running: .system)
    }

    /// Test-only entry point. `removal`, `log` and `running` have no defaults, so a test that omits
    /// one fails to compile instead of silently using the system Trash, the shared operations log
    /// or this machine's process table.
    static func injected(safety: PathSafety, log: OperationLog, removal: RemovalBackend,
                         running: RunningApplications,
                         permanent: Bool = false, alwaysTrash: Bool = false) -> CleanExecutor {
        CleanExecutor(safety: safety, log: log, permanent: permanent, alwaysTrash: alwaysTrash, removal: removal,
                      running: running)
    }

    private init(safety: PathSafety, log: OperationLog, permanent: Bool, alwaysTrash: Bool,
                 removal: RemovalBackend, running: RunningApplications) {
        self.safety = safety
        self.log = log
        self.permanent = permanent
        self.alwaysTrash = alwaysTrash
        self.removal = removal
        self.running = running
    }

    static let trashDirectory = MacHelperPaths.home.appending(path: ".Trash").path

    func action(for item: RemovalItem) -> CleanAction {
        if permanent { return .delete }
        if alwaysTrash, !(item.path == Self.trashDirectory || item.path.hasPrefix(Self.trashDirectory + "/")) { return .trash }
        return item.action
    }

    /// Re-checks right before removal, so an agent that started after the scan stops the removal.
    /// Queried fresh for every guarded item: an agent that started while earlier items of the same
    /// batch were being removed is caught too. Unguarded items (uninstall leftovers, the Trash…)
    /// skip the query entirely.
    private func busyMarker(for item: RemovalItem) -> String? {
        if !item.skipIfRunning.isEmpty,
           let app = item.skipIfRunning.first(where: running.bundleIDs().contains) { return app }
        if !item.skipIfProcessRunning.isEmpty {
            let runningNames = Set(running.processNames().map { $0.lowercased() })
            return item.skipIfProcessRunning.first {
                runningNames.contains(String($0.prefix(CleanScanner.processNameLength)).lowercased())
            }
        }
        return nil
    }

    public func execute(_ items: [RemovalItem], dryRun: Bool, command: String) -> CleanReport {
        let outcomes = items.map { executeItem($0, dryRun: dryRun) }
        if !dryRun { log.append(command: command, outcomes: outcomes) }
        return CleanReport(schemaVersion: 1, dryRun: dryRun, items: outcomes)
    }

    /// Executes a single item without logging so callers can interleave checks and operations,
    /// then append the outcomes in one batch.
    func executeItem(_ item: RemovalItem, dryRun: Bool) -> ItemOutcome {
        let action = action(for: item)
        // Re-check the agent's guard right before removal: it may have started after the scan
        // or while this batch was already running.
        if let busy = busyMarker(for: item) {
            return ItemOutcome(path: item.path, source: item.source, bytes: 0, result: .skipped,
                                       message: "guard: \(busy) is running")
        }
        // Re-check right before removal: the tree may have changed since the preview.
        let verdict = safety.check(item.path)
        guard verdict == .allowed else {
            return ItemOutcome(path: item.path, source: item.source, bytes: 0, result: .skipped,
                                       message: "safety: \(verdict)")
        }
        var st = stat()
        guard lstat(item.path, &st) == 0 else {
            return ItemOutcome(path: item.path, source: item.source, bytes: 0, result: .skipped,
                                       message: "no longer exists")
        }
        // Re-check the rule's age condition: a file modified since the preview (a resumed
        // session appending to it) is live data again, whatever the preview said.
        if item.minAgeDays > 0 {
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if Date().timeIntervalSince(modified) < TimeInterval(item.minAgeDays) * 86_400 {
                return ItemOutcome(path: item.path, source: item.source, bytes: 0, result: .skipped,
                                           message: "age: modified since the preview")
            }
        }
        if dryRun {
            return ItemOutcome(path: item.path, source: item.source, bytes: item.bytes,
                                        result: action == .trash ? .wouldTrash : .wouldDelete, message: nil)
        }
        let url = URL(fileURLWithPath: item.path)
        do {
            switch action {
            case .trash: try removal.trash(url)
            case .delete: try removal.delete(url)
            }
            return ItemOutcome(path: item.path, source: item.source, bytes: item.bytes,
                                        result: action == .trash ? .trashed : .deleted, message: nil)
        } catch {
            return ItemOutcome(path: item.path, source: item.source, bytes: 0, result: .failed,
                                        message: (error as NSError).localizedDescription)
        }
    }
}

extension CleanPlan {
    public var removalItems: [RemovalItem] {
        results.flatMap { r in
            r.candidates.filter(\.selected).map {
                RemovalItem(path: $0.path, source: r.rule.id, bytes: $0.size, action: r.rule.action,
                            skipIfRunning: r.rule.skipIfRunning, skipIfProcessRunning: r.rule.skipIfProcessRunning,
                            minAgeDays: r.rule.minAgeDays)
            }
        }
    }
}
