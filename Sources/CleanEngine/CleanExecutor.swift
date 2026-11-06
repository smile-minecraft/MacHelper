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
    public init(path: String, source: String, bytes: UInt64, action: CleanAction) {
        self.path = path
        self.source = source
        self.bytes = bytes
        self.action = action
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

    public init(safety: PathSafety, log: OperationLog = .shared, permanent: Bool = false, alwaysTrash: Bool = false) {
        self.safety = safety
        self.log = log
        self.permanent = permanent
        self.alwaysTrash = alwaysTrash
    }

    static let trashDirectory = MacHelperPaths.home.appending(path: ".Trash").path

    func action(for item: RemovalItem) -> CleanAction {
        if permanent { return .delete }
        if alwaysTrash, !(item.path == Self.trashDirectory || item.path.hasPrefix(Self.trashDirectory + "/")) { return .trash }
        return item.action
    }

    public func execute(_ items: [RemovalItem], dryRun: Bool, command: String) -> CleanReport {
        let fm = FileManager.default
        var outcomes: [ItemOutcome] = []
        for item in items {
            let action = action(for: item)
            // Re-check right before removal: the tree may have changed since the preview.
            let verdict = safety.check(item.path)
            guard verdict == .allowed else {
                outcomes.append(ItemOutcome(path: item.path, source: item.source, bytes: 0, result: .skipped,
                                            message: "safety: \(verdict)"))
                continue
            }
            var st = stat()
            guard lstat(item.path, &st) == 0 else {
                outcomes.append(ItemOutcome(path: item.path, source: item.source, bytes: 0, result: .skipped,
                                            message: "no longer exists"))
                continue
            }
            if dryRun {
                outcomes.append(ItemOutcome(path: item.path, source: item.source, bytes: item.bytes,
                                            result: action == .trash ? .wouldTrash : .wouldDelete, message: nil))
                continue
            }
            let url = URL(fileURLWithPath: item.path)
            do {
                switch action {
                case .trash: try fm.trashItem(at: url, resultingItemURL: nil)
                case .delete: try fm.removeItem(at: url)
                }
                outcomes.append(ItemOutcome(path: item.path, source: item.source, bytes: item.bytes,
                                            result: action == .trash ? .trashed : .deleted, message: nil))
            } catch {
                outcomes.append(ItemOutcome(path: item.path, source: item.source, bytes: 0, result: .failed,
                                            message: (error as NSError).localizedDescription))
            }
        }
        if !dryRun { log.append(command: command, outcomes: outcomes) }
        return CleanReport(schemaVersion: 1, dryRun: dryRun, items: outcomes)
    }
}

extension CleanPlan {
    public var removalItems: [RemovalItem] {
        results.flatMap { r in
            r.candidates.filter(\.selected).map {
                RemovalItem(path: $0.path, source: r.rule.id, bytes: $0.size, action: r.rule.action)
            }
        }
    }
}
