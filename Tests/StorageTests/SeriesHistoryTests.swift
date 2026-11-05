import Foundation
import GRDB
import Testing
@testable import Storage

/// Individual sensor and CPU-cluster series live beside the minute overview. These tests
/// pin the shared switch, the sum/count merge, the last-seen list, and the retention and
/// clear scope. A missing reading or minute stays absent; nothing is padded with zero.
@Suite struct SeriesHistoryTests {
    private let minute0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "machelper-series-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func totals(_ sum: Double, count: Int = 1) -> ColumnTotals {
        ColumnTotals(sum: sum, count: count)
    }

    private func finished(_ time: Date, _ totals: [String: ColumnTotals]) -> FinishedSeriesMinute {
        FinishedSeriesMinute(time: time, totals: totals)
    }

    /// Builds a v1 database by hand, as the old app left it before the later migrations.
    private func makeLegacyV1Database(url: URL, time: Date) throws {
        let pool = try DatabasePool(path: url.path, configuration: Configuration())
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE sample (time datetime primary key on conflict replace,
                    cpu double, gpu double, memory double, temperature double, fan double, power double,
                    networkIn double, networkOut double, diskRead double, diskWrite double, battery double)
                """)
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
            try db.execute(sql: "INSERT INTO sample (time, cpu, temperature) VALUES (?, ?, ?)",
                           arguments: [time, 0.42, 61.0])
        }
        try pool.close()
    }

    /// Writes series rows directly, bypassing recording. Used to set up retention and clear
    /// cases without depending on the behavior those cases are meant to prove.
    private func insertSeries(url: URL,
                              _ rows: [(time: Date, series: String, sum: Double, count: Int)]) throws {
        let pool = try DatabasePool(path: url.path, configuration: Configuration())
        try pool.write { db in
            for row in rows {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO series_sample (time, series, value_sum, value_count)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [row.time, row.series, row.sum, row.count])
            }
        }
        try pool.close()
    }

    // MARK: Data format and migration

    @Test func legacyDatabaseMigratesAndAddsTheSeriesTable() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            try makeLegacyV1Database(url: url, time: minute0)

            let history = try MetricsHistory(url: url)
            #expect(try history.count() == 1)
            let sample = try history.samples(since: minute0, bucket: 60).first
            #expect(sample?.cpu == 0.42)
            #expect(sample?.temperature == 61)

            let pool = try DatabasePool(path: url.path, configuration: Configuration())
            let columns: [(name: String, type: String)] = try pool.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(series_sample)").map { row in
                    let name: String = row["name"]
                    let type: String = row["type"]
                    return (name, type)
                }
            }
            try pool.close()

            #expect(columns.map(\.name) == ["time", "series", "value_sum", "value_count"])
            #expect(columns.filter { $0.type == "TEXT" }.map(\.name) == ["series"])
        }
    }

    // MARK: Collection switch

    @Test func seriesCollectionSwitchDefaultsOffAndIsSharedAcrossConnections() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let first = try HistoryStore(url: url)
            #expect(try first.isSeriesCollectionEnabled() == false)
            #expect(try first.isProcessCollectionEnabled() == false)

            try first.setSeriesCollectionEnabled(true)
            #expect(try first.isSeriesCollectionEnabled() == true)
            // The series switch is separate from the process switch.
            #expect(try first.isProcessCollectionEnabled() == false)

            let second = try HistoryStore(url: url)
            #expect(try second.isSeriesCollectionEnabled() == true)

            try second.setSeriesCollectionEnabled(false)
            #expect(try first.isSeriesCollectionEnabled() == false)
        }
    }

    @Test func seriesCollectionOffDoesNotRecordAndOnDoes() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            let sensor = HistorySeries.temperature("PMU tdie1")
            let minute = finished(minute0, [sensor: totals(55)])

            try history.recordSeriesMinute(minute, now: minute0)
            #expect(try history.seriesSamples(sensor, since: minute0, until: minute0.addingTimeInterval(60)).isEmpty)

            try store.setSeriesCollectionEnabled(true)
            try history.recordSeriesMinute(minute, now: minute0)
            let stored = try history.seriesSamples(sensor, since: minute0, until: minute0.addingTimeInterval(60))
            #expect(stored.count == 1)
            #expect(stored.first?.value == 55)
        }
    }

    // MARK: Persisting and querying

    @Test func twoWritersMergeTheSameMinuteAndQuerySkipsMissingMinutes() throws {
        try withTempDirectory { dir in
            #expect(HistorySeries.cpuPerformance == "cpu.performance")
            #expect(HistorySeries.cpuEfficiency == "cpu.efficiency")

            let url = dir.appending(path: "history.sqlite")
            let first = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setSeriesCollectionEnabled(true)
            let second = try MetricsHistory(url: url)
            let performance = HistorySeries.cpuPerformance
            let efficiency = HistorySeries.cpuEfficiency

            // The overview columns keep their existing meaning while series are written.
            try first.recordMinute(
                FinishedMinute(time: minute0, totals: ["cpu": totals(0.5), "temperature": totals(61)]),
                now: minute0)

            // The app saw four observations and the recorder one; sums and counts must add.
            try first.recordSeriesMinute(
                finished(minute0, [performance: totals(2.0, count: 4)]),
                now: minute0)
            try second.recordSeriesMinute(
                finished(minute0, [performance: totals(0.9), efficiency: totals(0.5)]),
                now: minute0.addingTimeInterval(30))
            try first.recordSeriesMinute(
                finished(minute0.addingTimeInterval(120), [performance: totals(3.0)]),
                now: minute0.addingTimeInterval(180))

            let performanceSamples = try first.seriesSamples(
                performance, since: minute0, until: minute0.addingTimeInterval(180))
            #expect(performanceSamples.count == 2)
            #expect(performanceSamples.first?.time == minute0)
            #expect(abs((performanceSamples.first?.value ?? 0) - 0.58) < 1e-9)   // (2.0 + 0.9) / 5
            #expect(performanceSamples.last?.time == minute0.addingTimeInterval(120))
            #expect(performanceSamples.last?.value == 3.0)

            // The efficiency cluster was only present in the first minute; the missing
            // second minute has no point at all.
            let efficiencySamples = try first.seriesSamples(
                efficiency, since: minute0, until: minute0.addingTimeInterval(180))
            #expect(efficiencySamples.map(\.time) == [minute0])
            #expect(efficiencySamples.first?.value == 0.5)

            let overview = try first.samples(since: minute0, bucket: 60)
            #expect(overview.first?.cpu == 0.5)
            #expect(overview.first?.temperature == 61)
        }
    }

    @Test func availableSeriesListsTheLastMinuteAndKeepsRenamedSensorsSeparate() throws {
        try withTempDirectory { dir in
            #expect(HistorySeries.temperature("PMU tdie1") == "temperature.PMU tdie1")

            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setSeriesCollectionEnabled(true)
            let oldSensor = HistorySeries.temperature("PMU tdie1")
            let newSensor = HistorySeries.temperature("PMU tdie2")

            try history.recordSeriesMinute(finished(minute0, [oldSensor: totals(50)]), now: minute0)
            try history.recordSeriesMinute(
                finished(minute0.addingTimeInterval(60), [oldSensor: totals(52)]),
                now: minute0.addingTimeInterval(60))
            try history.recordSeriesMinute(
                finished(minute0.addingTimeInterval(120), [newSensor: totals(60)]),
                now: minute0.addingTimeInterval(120))

            let available = try history.availableSeries()
            #expect(available.map(\.series) == [oldSensor, newSensor])
            #expect(available.first { $0.series == oldSensor }?.lastSeen == minute0.addingTimeInterval(60))
            #expect(available.first { $0.series == newSensor }?.lastSeen == minute0.addingTimeInterval(120))

            // The old name keeps its own rows; the new name starts at its own first minute.
            let oldSamples = try history.seriesSamples(
                oldSensor, since: minute0, until: minute0.addingTimeInterval(180))
            #expect(oldSamples.count == 2)
            let newSamples = try history.seriesSamples(
                newSensor, since: minute0, until: minute0.addingTimeInterval(180))
            #expect(newSamples.map(\.time) == [minute0.addingTimeInterval(120)])
            #expect(newSamples.first?.value == 60)
        }
    }

    // MARK: Retention and clearing

    @Test func retentionPruningCoversSeriesWhileCollectionStaysOff() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setRetention(.oneDay)
            let oldSensor = HistorySeries.temperature("PMU tdie1")
            let recentSensor = HistorySeries.temperature("PMU tdie2")
            let old = minute0.addingTimeInterval(-2 * 86_400)
            try insertSeries(url: url, [
                (old, oldSensor, 50, 1),
                (minute0, recentSensor, 60, 1),
            ])

            // Collection is off (the default), so only the regular minute write can age
            // out series rows. A stopped series recorder must not keep old rows forever.
            try history.recordMinute(
                FinishedMinute(time: minute0.addingTimeInterval(60), totals: ["cpu": totals(0.2)]),
                now: minute0.addingTimeInterval(60))

            #expect(try history.seriesSamples(oldSensor, since: old, until: minute0).isEmpty)
            let recent = try history.seriesSamples(
                recentSensor, since: minute0, until: minute0.addingTimeInterval(60))
            #expect(recent.map(\.value) == [60])
        }
    }

    @Test func clearingSeriesLeavesOtherHistoryAndSettingsAndViceVersa() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setRetention(.fourteenDays)
            try store.setProcessCollectionEnabled(true)
            let sensor = HistorySeries.temperature("PMU tdie1")

            try history.recordMinute(
                FinishedMinute(time: minute0, totals: ["cpu": totals(0.5)]), now: minute0)
            try history.recordProcessMinute(
                FinishedProcessMinute(time: minute0, processes: [
                    "Safari": ProcessUsageTotals(cpu: totals(0.5),
                                                 memoryBytes: totals(300_000_000)),
                ]),
                now: minute0)
            try insertSeries(url: url, [(minute0, sensor, 55, 1)])

            try store.clear(.seriesSamples)
            let seriesAfterClear = try history.seriesSamples(
                sensor, since: minute0, until: minute0.addingTimeInterval(60))
            #expect(seriesAfterClear.isEmpty)
            #expect(try history.count() == 1)
            let processAfterSeriesClear = try history.processUsage(
                since: minute0, until: minute0.addingTimeInterval(60))
            #expect(processAfterSeriesClear.byCPU.map(\.name) == ["Safari"])
            #expect(try store.retention() == .fourteenDays)
            #expect(try store.isProcessCollectionEnabled() == true)

            // Clearing the minute or process history must leave the series alone.
            try insertSeries(url: url, [(minute0, sensor, 55, 1)])
            try store.clear(.minuteSamples)
            #expect(try history.count() == 0)
            let seriesAfterMinuteClear = try history.seriesSamples(
                sensor, since: minute0, until: minute0.addingTimeInterval(60))
            #expect(seriesAfterMinuteClear.map(\.value) == [55])
            let processAfterMinuteClear = try history.processUsage(
                since: minute0, until: minute0.addingTimeInterval(60))
            #expect(processAfterMinuteClear.byCPU.map(\.name) == ["Safari"])

            try store.clear(.processSamples)
            let processAfterProcessClear = try history.processUsage(
                since: minute0, until: minute0.addingTimeInterval(60))
            #expect(processAfterProcessClear.byCPU.isEmpty)
            let seriesAfterProcessClear = try history.seriesSamples(
                sensor, since: minute0, until: minute0.addingTimeInterval(60))
            #expect(seriesAfterProcessClear.map(\.value) == [55])
            #expect(try store.retention() == .fourteenDays)
        }
    }

    @Test func seriesWriteOnReadOnlyDatabaseThrowsAndKeepsExistingRows() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setSeriesCollectionEnabled(true)
            let sensor = HistorySeries.temperature("PMU tdie1")
            try insertSeries(url: url, [(minute0, sensor, 50, 1)])

            let reader = try MetricsHistory(url: url, readOnly: true)
            #expect(throws: (any Error).self) {
                try reader.recordSeriesMinute(
                    finished(minute0.addingTimeInterval(60), [sensor: totals(60)]),
                    now: minute0.addingTimeInterval(60))
            }

            let stored = try history.seriesSamples(
                sensor, since: minute0, until: minute0.addingTimeInterval(180))
            #expect(stored.map(\.value) == [50])   // the failed write added nothing
        }
    }
}
