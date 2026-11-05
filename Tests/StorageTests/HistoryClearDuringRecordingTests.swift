import Foundation
import Testing
@testable import Storage

/// A clear happens in the database, but each recording process also holds the minute it is
/// still accumulating in memory. These tests pin that a minute already open at clear time
/// does not return after it closes, and that removed process names cannot be read from the
/// write-ahead log.
@Suite struct HistoryClearDuringRecordingTests {
    /// A fixed whole minute. Each write passes its own `now` around this time, so retention
    /// pruning never touches the rows under test.
    private let minute = Date(timeIntervalSince1970: 1_800_300_000)
    /// The user clears halfway through that minute.
    private var clearTime: Date { minute.addingTimeInterval(30) }

    private var nextMinute: Date { minute.addingTimeInterval(60) }

    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "machelper-clear-during-recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func totals(_ value: Double) -> ColumnTotals {
        ColumnTotals(sum: value, count: 1)
    }

    private func readings(name: String, cpu: Double) -> ProcessUsageReadings {
        ProcessUsageReadings(
            byCPU: [ProcessUsageReading(pid: 1, name: name, cpu: cpu, memoryBytes: 1_000)],
            byMemory: [], hiddenCount: 0)
    }

    @Test func clearDropsTheMinuteThatWasStillAccumulating() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)

            // The app sampled before the clear; the minute only closes after it.
            var accumulator = MinuteAccumulator()
            _ = accumulator.addTracked("cpu", 0.77, at: minute.addingTimeInterval(5))
            try store.clear(.minuteSamples, now: clearTime)
            let closed = accumulator.addTracked("cpu", 0.5, at: minute.addingTimeInterval(61))
            #expect(closed?.time == minute)
            try history.recordMinute(closed!, now: minute.addingTimeInterval(61))

            #expect(try history.count() == 0)

            // The following minute is not part of the clear and must still be recorded.
            try history.recordMinute(
                FinishedMinute(time: nextMinute, totals: ["cpu": totals(0.5)]),
                now: nextMinute.addingTimeInterval(60))
            #expect(try history.samples(since: nextMinute, bucket: 60).map(\.cpu) == [0.5])
        }
    }

    @Test func clearDropsTheProcessMinuteThatWasStillAccumulating() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setProcessCollectionEnabled(true)

            var accumulator = ProcessMinuteAccumulator()
            _ = accumulator.add(readings(name: "SecretProcess", cpu: 0.8),
                                at: minute.addingTimeInterval(5))
            try store.clear(.processSamples, now: clearTime)
            let closed = accumulator.add(readings(name: "SecretProcess", cpu: 0.4),
                                         at: minute.addingTimeInterval(61))
            #expect(closed?.time == minute)
            try history.recordProcessMinute(closed!, now: minute.addingTimeInterval(61))

            let afterClear = try history.processUsage(since: minute, until: nextMinute)
            #expect(afterClear.byCPU.isEmpty)
            #expect(afterClear.byMemory.isEmpty)
            #expect(afterClear.hiddenCount == 0)

            // The following minute is not part of the clear and must still be recorded.
            try history.recordProcessMinute(
                FinishedProcessMinute(time: nextMinute, processes: [
                    "NextProcess": ProcessUsageTotals(cpu: totals(0.6), memoryBytes: totals(2_000)),
                ]),
                now: nextMinute.addingTimeInterval(60))
            let later = try history.processUsage(since: nextMinute, until: nextMinute.addingTimeInterval(60))
            #expect(later.byCPU.map(\.name) == ["NextProcess"])
        }
    }

    @Test func clearDropsTheSeriesMinuteThatWasStillAccumulating() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setSeriesCollectionEnabled(true)
            let sensor = HistorySeries.temperature("PMU tdie1")

            var accumulator = SeriesMinuteAccumulator()
            _ = accumulator.add([sensor: 55], at: minute.addingTimeInterval(5))
            try store.clear(.seriesSamples, now: clearTime)
            let closed = accumulator.add([sensor: 60], at: minute.addingTimeInterval(61))
            #expect(closed?.time == minute)
            try history.recordSeriesMinute(closed!, now: minute.addingTimeInterval(61))

            #expect(try history.seriesSamples(sensor, since: minute, until: nextMinute).isEmpty)

            // The following minute is not part of the clear and must still be recorded.
            try history.recordSeriesMinute(
                FinishedSeriesMinute(time: nextMinute, totals: [sensor: totals(65)]),
                now: nextMinute.addingTimeInterval(60))
            let later = try history.seriesSamples(sensor, since: nextMinute, until: nextMinute.addingTimeInterval(60))
            #expect(later.map(\.value) == [65])
        }
    }

    @Test func clearTruncatesRemovedProcessNamesOutOfTheWriteAheadLog() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setProcessCollectionEnabled(true)
            let name = "SecretProcess"

            try history.recordProcessMinute(
                FinishedProcessMinute(time: minute, processes: [
                    name: ProcessUsageTotals(cpu: totals(0.5), memoryBytes: totals(1_000)),
                ]),
                now: minute)
            try store.clear(.processSamples, now: minute.addingTimeInterval(60))

            let writeAheadLog = try Data(contentsOf: URL(filePath: url.path + "-wal"))
            #expect(writeAheadLog.range(of: Data(name.utf8)) == nil)
        }
    }
}
