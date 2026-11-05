import Foundation

/// Running sum and observation count for one metric column of one minute.
/// Averages must come from these totals, never from averaging averages.
public struct ColumnTotals: Sendable, Equatable {
    public var sum: Double
    public var count: Int

    public init(sum: Double, count: Int) {
        self.sum = sum
        self.count = count
    }

    public var average: Double { count > 0 ? sum / Double(count) : 0 }
}

/// A finished minute ready to persist: its start time plus each column's running sum
/// and observation count. The history layer turns these totals into averages, so the
/// writer never hands over a value that could disagree with its own counts.
public struct FinishedMinute: Sendable, Equatable {
    public var time: Date
    public var totals: [String: ColumnTotals]

    public init(time: Date, totals: [String: ColumnTotals]) {
        self.time = time
        self.totals = totals
    }
}
