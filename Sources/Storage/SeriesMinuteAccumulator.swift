import Foundation

/// Builds the series values one sample contributes. Keys come from `HistorySeries`, so the
/// app and the background recorder write the same names. A value the hardware did not report
/// is simply absent: an Intel CPU has no performance/efficiency clusters, and a sensor that
/// is gone this minute is not zero.
public enum SeriesValues {
    public static func cpu(performance: Double?, efficiency: Double?) -> [String: Double] {
        var values: [String: Double] = [:]
        if let performance { values[HistorySeries.cpuPerformance] = performance }
        if let efficiency { values[HistorySeries.cpuEfficiency] = efficiency }
        return values
    }

    public static func temperature(_ readings: [(name: String, celsius: Double)]) -> [String: Double] {
        var values: [String: Double] = [:]
        for reading in readings {
            values[HistorySeries.temperature(reading.name)] = reading.celsius
        }
        return values
    }
}

/// Collects one sample's series values per minute and yields their sums and counts when the
/// minute ends. The history store divides the sums by the counts, so the app and the recorder
/// can merge a shared minute without averaging averages. A series absent from a sample is not
/// padded with zero.
public struct SeriesMinuteAccumulator: Sendable {
    private var minute: Date?
    private var sums: [String: (Double, Int)] = [:]

    public init() {}

    /// Adds one value per series; returns the finished previous minute's totals when `date`
    /// starts a new minute.
    public mutating func add(_ values: [String: Double], at date: Date = Date()) -> FinishedSeriesMinute? {
        let m = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var finished: FinishedSeriesMinute?
        if let current = minute, current != m {
            finished = flush(current)
        }
        minute = m
        for (series, value) in values where value.isFinite {
            let (sum, count) = sums[series] ?? (0, 0)
            sums[series] = (sum + value, count + 1)
        }
        return finished
    }

    private mutating func flush(_ time: Date) -> FinishedSeriesMinute? {
        defer { sums = [:] }
        guard !sums.isEmpty else { return nil }
        return FinishedSeriesMinute(time: time,
                                    totals: sums.mapValues { ColumnTotals(sum: $0.0, count: $0.1) })
    }
}
