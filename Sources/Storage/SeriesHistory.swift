import Foundation

/// Stable string keys for the per-sensor and per-cluster series stored beside the minute
/// overview. The key is opaque to storage; the prefix lets the app group a series without
/// re-reading the hardware.
public enum HistorySeries {
    public static let cpuPerformance = "cpu.performance"
    public static let cpuEfficiency = "cpu.efficiency"

    /// HID sensor names and SMC keys are already unique on one machine. Keeping the raw
    /// name means a sensor whose name changes starts a new series instead of rewriting the
    /// old one.
    public static func temperature(_ sensorName: String) -> String {
        "temperature.\(sensorName)"
    }
}

/// One finished minute of series values, ready to persist. `totals` holds each series'
/// running sum and observation count; storage divides them when reading, so two writers
/// can merge a shared minute without averaging averages.
public struct FinishedSeriesMinute: Sendable, Equatable {
    public var time: Date
    public var totals: [String: ColumnTotals]

    public init(time: Date, totals: [String: ColumnTotals]) {
        self.time = time
        self.totals = totals
    }
}

/// One stored minute of a series. `value` is the average over the observations recorded
/// for that minute. A minute with no observations has no row and therefore no point.
public struct SeriesSample: Sendable, Equatable, Hashable {
    public var time: Date
    public var value: Double

    public init(time: Date, value: Double) {
        self.time = time
        self.value = value
    }
}

/// One averaged bucket of a series. `time` is the first stored minute in the bucket and
/// the chart's x position; `lastSampleTime` is the last stored minute the average covers.
/// A bucket never spans a gap in the stored minutes: a longer gap inside one bucket
/// becomes two buckets, so a chart can still break the line where the recorder stopped.
public struct SeriesBucket: Sendable, Equatable, Hashable {
    public var time: Date
    public var value: Double
    public var lastSampleTime: Date
    /// Stored minutes the average covers, not the number of observations inside them.
    public var storedMinuteCount: Int

    public init(time: Date, value: Double, lastSampleTime: Date, storedMinuteCount: Int) {
        self.time = time
        self.value = value
        self.lastSampleTime = lastSampleTime
        self.storedMinuteCount = storedMinuteCount
    }
}

/// A series present in the stored history and the last minute it was seen.
public struct AvailableSeries: Sendable, Equatable, Hashable {
    public var series: String
    public var lastSeen: Date

    public init(series: String, lastSeen: Date) {
        self.series = series
        self.lastSeen = lastSeen
    }
}
