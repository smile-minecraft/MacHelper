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

/// What each rule (or detector, or task) has removed over the records given: which ones keep
/// finding something, and which almost never do. Only successful removals count.
public struct OperationSourceStats: Sendable, Identifiable, Equatable {
    public let source: String
    public let bytes: UInt64
    public let items: Int
    /// Distinct days the source removed something.
    public let days: Int
    public let last: Date
    public var id: String { source }

    public static func compute(_ entries: [OperationLog.Entry], calendar: Calendar = .current) -> [OperationSourceStats] {
        var bytes: [String: UInt64] = [:], items: [String: Int] = [:], days: [String: Set<Date>] = [:], last: [String: Date] = [:]
        for e in entries where e.result == "trashed" || e.result == "deleted" {
            bytes[e.source, default: 0] += e.bytes
            items[e.source, default: 0] += 1
            days[e.source, default: []].insert(calendar.startOfDay(for: e.time))
            last[e.source] = max(last[e.source] ?? e.time, e.time)
        }
        return bytes.keys.map { s in
            OperationSourceStats(source: s, bytes: bytes[s]!, items: items[s]!, days: days[s]!.count, last: last[s]!)
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.source < $1.source }
    }
}

/// Removed bytes per calendar month, newest first.
public struct OperationMonthTotal: Sendable, Identifiable, Equatable {
    public let month: Date
    public let trashedBytes: UInt64
    public let deletedBytes: UInt64
    public var id: Date { month }

    public static func compute(_ entries: [OperationLog.Entry], calendar: Calendar = .current) -> [OperationMonthTotal] {
        var trashed: [Date: UInt64] = [:], deleted: [Date: UInt64] = [:]
        for e in entries {
            guard let month = calendar.dateInterval(of: .month, for: e.time)?.start else { continue }
            switch e.result {
            case "trashed": trashed[month, default: 0] += e.bytes
            case "deleted": deleted[month, default: 0] += e.bytes
            default: continue
            }
        }
        return Set(trashed.keys).union(deleted.keys).sorted(by: >).map {
            OperationMonthTotal(month: $0, trashedBytes: trashed[$0] ?? 0, deletedBytes: deleted[$0] ?? 0)
        }
    }
}
