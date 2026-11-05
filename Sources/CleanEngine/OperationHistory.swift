import Foundation

/// The screen that groups recorded operations by the feature that produced them.
public enum OperationKind: String, CaseIterable, Sendable {
    case cleanup, uninstall, startup, maintenance, diskAnalysis, other

    public init(command: String) {
        switch command {
        case "clean", "autoclean", "purge": self = .cleanup
        case "uninstall": self = .uninstall
        case "startup": self = .startup
        case "optimize": self = .maintenance
        case "analyze": self = .diskAnalysis
        default: self = .other
        }
    }
}

public enum OperationStatus: String, Sendable {
    case succeeded, skipped, failed

    public init(result: String) {
        switch result {
        case "failed": self = .failed
        case "skipped": self = .skipped
        default: self = .succeeded
        }
    }
}

extension OperationLog.Entry {
    public var kind: OperationKind { OperationKind(command: command) }
    public var status: OperationStatus { OperationStatus(result: result) }
}

/// Totals for the records currently shown. Sizes stay split by what happened to the item:
/// moving it to the Trash and deleting it permanently are not the same disk-space effect.
public struct OperationHistorySummary: Sendable {
    public var trashedBytes: UInt64 = 0
    public var deletedBytes: UInt64 = 0
    public var succeededCount = 0
    public var skippedCount = 0
    public var failedCount = 0

    public var recordCount: Int { succeededCount + skippedCount + failedCount }

    public init(entries: [OperationLog.Entry]) {
        for entry in entries {
            switch entry.status {
            case .succeeded: succeededCount += 1
            case .skipped: skippedCount += 1
            case .failed: failedCount += 1
            }
            switch entry.result {
            case "trashed": trashedBytes += entry.bytes
            case "deleted": deletedBytes += entry.bytes
            default: break
            }
        }
    }
}

public struct OperationHistoryFilter: Sendable {
    public var kind: OperationKind?
    public var from: Date?
    public var to: Date?

    public init(kind: OperationKind? = nil, from: Date? = nil, to: Date? = nil) {
        self.kind = kind
        self.from = from
        self.to = to
    }

    public func matches(_ entry: OperationLog.Entry) -> Bool {
        if let kind, entry.kind != kind { return false }
        if let from, entry.time < from { return false }
        if let to, entry.time > to { return false }
        return true
    }

    public func apply(to entries: [OperationLog.Entry]) -> [OperationLog.Entry] {
        entries.filter(matches)
    }
}
