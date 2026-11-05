import Foundation
import GRDB
import Testing
@testable import Storage

/// Process history keeps only what the privacy promise allows: a name, CPU, and memory for
/// the top ten of each minute. These tests pin the shared switch, the minute merge, the
/// ranking bounds, and the clear and retention scope.
@Suite struct ProcessHistoryTests {
    private let minute0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "machelper-process-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func reading(_ name: String, pid: Int32, cpu: Double, memory: UInt64) -> ProcessUsageReading {
        ProcessUsageReading(pid: pid, name: name, cpu: cpu, memoryBytes: memory)
    }

    private func totals(cpu: Double, count: Int = 1, memory: Double, memoryCount: Int? = nil) -> ProcessUsageTotals {
        ProcessUsageTotals(cpu: ColumnTotals(sum: cpu, count: count),
                           memoryBytes: ColumnTotals(sum: memory, count: memoryCount ?? count))
    }

    private func finished(_ time: Date, hidden: Int = 0,
                          _ processes: [String: ProcessUsageTotals]) -> FinishedProcessMinute {
        FinishedProcessMinute(time: time, processes: processes, hiddenCount: hidden)
    }

    /// Builds a v1 database by hand, as the old app left it before the accumulator and
    /// settings migrations existed.
    private func makeLegacyV1Database(url: URL, time: Date, cpu: Double) throws {
        let pool = try DatabasePool(path: url.path, configuration: Configuration())
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE sample (time datetime primary key on conflict replace,
                    cpu double, gpu double, memory double, temperature double, fan double, power double,
                    networkIn double, networkOut double, diskRead double, diskWrite double, battery double)
                """)
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
            try db.execute(sql: "INSERT INTO sample (time, cpu) VALUES (?, ?)", arguments: [time, cpu])
        }
        try pool.close()
    }

    // MARK: Data format and migration

    @Test func legacyDatabaseMigratesAndTheProcessTableStoresOnlyNames() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            try makeLegacyV1Database(url: url, time: minute0, cpu: 0.42)

            let history = try MetricsHistory(url: url)
            #expect(try history.count() == 1)
            #expect(try history.samples(since: minute0, bucket: 60).first?.cpu == 0.42)

            let pool = try DatabasePool(path: url.path, configuration: Configuration())
            let columns: [(name: String, type: String)] = try pool.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(process_sample)").map { row in
                    let name: String = row["name"]
                    let type: String = row["type"]
                    return (name, type)
                }
            }
            try pool.close()

            #expect(columns.map(\.name) == ["time", "name", "cpu_sum", "cpu_count", "memory_sum", "memory_count"])
            // Paths, arguments, and process IDs never belong in history.
            #expect(columns.filter { $0.type == "TEXT" }.map(\.name) == ["name"])
        }
    }

    // MARK: Collection switch

    @Test func collectionSwitchDefaultsOffAndIsSharedAcrossConnections() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let first = try HistoryStore(url: url)
            #expect(try first.isProcessCollectionEnabled() == false)

            try first.setProcessCollectionEnabled(true)
            #expect(try first.isProcessCollectionEnabled() == true)

            let second = try HistoryStore(url: url)
            #expect(try second.isProcessCollectionEnabled() == true)

            try second.setProcessCollectionEnabled(false)
            #expect(try first.isProcessCollectionEnabled() == false)
        }
    }

    @Test func collectionOffDoesNotRecordAndCollectionOnDoes() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            let minute = finished(minute0, ["Safari": totals(cpu: 0.5, memory: 300_000_000)])

            try history.recordProcessMinute(minute, now: minute0)
            #expect(try history.processUsage(since: minute0, until: minute0.addingTimeInterval(60)).byCPU.isEmpty)

            try store.setProcessCollectionEnabled(true)
            try history.recordProcessMinute(minute, now: minute0)
            let recorded = try history.processUsage(since: minute0, until: minute0.addingTimeInterval(60))
            #expect(recorded.byCPU.map(\.name) == ["Safari"])
            #expect(recorded.byCPU.first?.averageCPU == 0.5)
            #expect(recorded.byCPU.first?.minuteCount == 1)
        }
    }

    // MARK: Minute accumulation

    @Test func accumulatorMergesSameNamedProcessesAndClosesTheMinute() {
        var accumulator = ProcessMinuteAccumulator()
        let readings = ProcessUsageReadings(
            byCPU: [reading("Helper", pid: 1, cpu: 0.2, memory: 10_000_000),
                    reading("Helper", pid: 2, cpu: 0.3, memory: 20_000_000),
                    reading("Main", pid: 3, cpu: 0.5, memory: 30_000_000)],
            byMemory: [reading("Helper", pid: 1, cpu: 0.2, memory: 10_000_000),
                       reading("Helper", pid: 2, cpu: 0.3, memory: 20_000_000),
                       reading("Main", pid: 3, cpu: 0.5, memory: 30_000_000)],
            hiddenCount: 2)

        #expect(accumulator.add(readings, at: minute0) == nil)
        let closed = accumulator.add(readings, at: minute0.addingTimeInterval(60))
        let helper = closed?.processes["Helper"]
        #expect(closed?.time == minute0)
        #expect(closed?.processes.count == 2)
        #expect(helper?.cpu.sum == 0.5)
        #expect(helper?.cpu.count == 1)   // two processes of one name are one observation
        #expect(helper?.memoryBytes.sum == 30_000_000)
        #expect(closed?.hiddenCount == 2)
    }

    @Test func accumulatorKeepsOnlyTheMinutesTopTenByCPUAndByMemory() {
        var accumulator = ProcessMinuteAccumulator()
        var byCPU: [ProcessUsageReading] = []
        var byMemory: [ProcessUsageReading] = []
        for index in 0..<12 {
            let value = Double(100 - index)
            byCPU.append(reading("CPU\(index)", pid: Int32(100 + index), cpu: value, memory: 1_000_000))
            byMemory.append(reading("Memory\(index)", pid: Int32(200 + index), cpu: 0.001,
                                    memory: UInt64(value) * 1_000_000_000))
        }
        let shared = reading("Shared", pid: 999, cpu: 94.5, memory: 94_500_000_000)
        byCPU.append(shared)
        byMemory.append(shared)

        #expect(accumulator.add(ProcessUsageReadings(byCPU: byCPU, byMemory: byMemory, hiddenCount: 0),
                                at: minute0) == nil)

        // A later snapshot in the same minute with lower-ranked names. Selecting a top ten
        // per snapshot would store another twenty rows; the minute ranking must drop them.
        var laterCPU: [ProcessUsageReading] = []
        var laterMemory: [ProcessUsageReading] = []
        for index in 0..<12 {
            let value = Double(50 - index)
            laterCPU.append(reading("LaterCPU\(index)", pid: Int32(300 + index), cpu: value, memory: 1_000_000))
            laterMemory.append(reading("LaterMemory\(index)", pid: Int32(400 + index), cpu: 0.001,
                                       memory: UInt64(value) * 1_000_000_000))
        }
        #expect(accumulator.add(ProcessUsageReadings(byCPU: laterCPU, byMemory: laterMemory, hiddenCount: 0),
                                at: minute0.addingTimeInterval(30)) == nil)

        let closed = accumulator.add(ProcessUsageReadings(byCPU: [], byMemory: [], hiddenCount: 0),
                                     at: minute0.addingTimeInterval(60))
        let names = Set(closed?.processes.keys.map { $0 } ?? [])

        #expect(names.count == 19)
        #expect(names.contains("CPU8"))
        #expect(names.contains("Memory8"))
        #expect(!names.contains("CPU9"))
        #expect(!names.contains("Memory9"))
        #expect(!names.contains("LaterCPU0"))
        #expect(!names.contains("LaterMemory0"))
        // The same process appears in both rankings; it is counted once, not twice.
        #expect(closed?.processes["Shared"]?.cpu.count == 1)
        #expect(closed?.processes["Shared"]?.cpu.sum == 94.5)
        #expect(closed?.processes["Shared"]?.memoryBytes.sum == 94_500_000_000)
    }

    // MARK: Persisting and querying

    @Test func twoWritersMergeTheSameMinuteAndKeepTheLargestHiddenCount() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let first = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setProcessCollectionEnabled(true)
            let second = try MetricsHistory(url: url)

            // The app saw two observations and the recorder one; sums and counts must add.
            try first.recordProcessMinute(
                finished(minute0, hidden: 3, ["Safari": totals(cpu: 0.4, count: 2, memory: 200_000_000)]),
                now: minute0)
            try second.recordProcessMinute(
                finished(minute0, hidden: 5, ["Safari": totals(cpu: 0.9, count: 1, memory: 400_000_000)]),
                now: minute0.addingTimeInterval(30))

            let usage = try first.processUsage(since: minute0, until: minute0.addingTimeInterval(60))
            #expect(usage.byCPU.map(\.name) == ["Safari"])
            #expect(abs((usage.byCPU.first?.averageCPU ?? 0) - 1.3 / 3) < 1e-9)
            #expect(abs((usage.byCPU.first?.averageMemoryBytes ?? 0) - 200_000_000) < 1e-9)   // (200 + 400) / 3
            #expect(usage.byCPU.first?.minuteCount == 1)
            #expect(usage.hiddenCount == 5)
        }
    }

    @Test func queryAveragesOnlyOverMinutesTheProcessAppeared() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setProcessCollectionEnabled(true)

            try history.recordProcessMinute(
                finished(minute0, ["Safari": totals(cpu: 0.2, memory: 100_000_000)]), now: minute0)
            try history.recordProcessMinute(
                finished(minute0.addingTimeInterval(60),
                         ["Safari": totals(cpu: 0.4, memory: 300_000_000),
                          "Helper": totals(cpu: 0.1, memory: 50_000_000)]),
                now: minute0.addingTimeInterval(60))

            // Three minutes in the range, but the third has no rows at all.
            let usage = try history.processUsage(since: minute0, until: minute0.addingTimeInterval(180))
            #expect(usage.totalMinuteCount == 3)

            let safari = usage.byCPU.first { $0.name == "Safari" }
            #expect(safari?.minuteCount == 2)
            #expect(abs((safari?.averageCPU ?? 0) - 0.3) < 1e-9)   // not 0.2, which would divide by three
            #expect(abs((safari?.averageMemoryBytes ?? 0) - 200_000_000) < 1e-9)

            let helper = usage.byCPU.first { $0.name == "Helper" }
            #expect(helper?.minuteCount == 1)
            #expect(abs((helper?.averageCPU ?? 0) - 0.1) < 1e-9)   // not 0.033…
            #expect(usage.byMemory.map(\.name) == ["Safari", "Helper"])
        }
    }

    // MARK: Retention and clearing

    @Test func retentionPruningAlsoRemovesExpiredProcessSamples() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setProcessCollectionEnabled(true)
            try store.setRetention(.thirtyDays)
            let old = minute0.addingTimeInterval(-2 * 86_400)

            try history.recordProcessMinute(
                finished(old, ["First": totals(cpu: 0.2, memory: 100_000_000)]), now: minute0)
            #expect(try history.processUsage(since: old, until: old.addingTimeInterval(60)).byCPU.map(\.name) == ["First"])

            // Changing the setting deletes nothing by itself; the next write prunes.
            try store.setRetention(.oneDay)
            #expect(try history.processUsage(since: old, until: old.addingTimeInterval(60)).byCPU.map(\.name) == ["First"])

            try history.recordProcessMinute(
                finished(minute0, ["New": totals(cpu: 0.5, memory: 200_000_000)]), now: minute0)
            #expect(try history.processUsage(since: old, until: old.addingTimeInterval(60)).byCPU.isEmpty)
            #expect(try history.processUsage(since: minute0, until: minute0.addingTimeInterval(60)).byCPU.map(\.name) == ["New"])

            // Old process rows must still expire after the user turns collection off;
            // otherwise the names would stay beyond retention because no process write runs.
            try store.setRetention(.thirtyDays)
            try history.recordProcessMinute(
                finished(old, ["WhileOn": totals(cpu: 0.3, memory: 150_000_000)]), now: minute0)
            try store.setRetention(.oneDay)
            try store.setProcessCollectionEnabled(false)
            try history.recordMinute(
                FinishedMinute(time: minute0.addingTimeInterval(60), totals: ["cpu": ColumnTotals(sum: 0.5, count: 1)]),
                now: minute0.addingTimeInterval(60))
            #expect(try history.processUsage(since: old, until: old.addingTimeInterval(60)).byCPU.isEmpty)
        }
    }

    @Test func clearingOneHistoryKindLeavesTheOtherAndSettings() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setProcessCollectionEnabled(true)
            try store.setRetention(.fourteenDays)
            try history.recordMinute(
                FinishedMinute(time: minute0, totals: ["cpu": ColumnTotals(sum: 0.5, count: 1)]), now: minute0)
            try history.recordProcessMinute(
                finished(minute0, hidden: 4, ["Safari": totals(cpu: 0.5, memory: 300_000_000)]), now: minute0)

            // The clear happens before the process row written afterwards, so the new
            // minute is not mistaken for one that was already accumulating at clear time.
            try store.clear(.processSamples, now: minute0.addingTimeInterval(-60))
            let afterProcessClear = try history.processUsage(since: minute0, until: minute0.addingTimeInterval(60))
            #expect(afterProcessClear.byCPU.isEmpty)
            #expect(afterProcessClear.hiddenCount == 0)
            #expect(try history.count() == 1)
            #expect(try store.retention() == .fourteenDays)
            #expect(try store.isProcessCollectionEnabled() == true)

            try history.recordProcessMinute(
                finished(minute0, ["Safari": totals(cpu: 0.5, memory: 300_000_000)]), now: minute0)
            try store.clear(.minuteSamples)
            #expect(try history.count() == 0)
            #expect(try history.processUsage(since: minute0, until: minute0.addingTimeInterval(60)).byCPU.map(\.name) == ["Safari"])
            #expect(try store.retention() == .fourteenDays)
        }
    }

    @Test func processWriteOnReadOnlyDatabaseThrowsAndKeepsExistingRows() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            try store.setProcessCollectionEnabled(true)
            try history.recordProcessMinute(
                finished(minute0, ["Safari": totals(cpu: 0.5, memory: 300_000_000)]), now: minute0)

            let reader = try MetricsHistory(url: url, readOnly: true)
            #expect(throws: (any Error).self) {
                try reader.recordProcessMinute(
                    finished(minute0.addingTimeInterval(60), ["Safari": totals(cpu: 0.9, memory: 400_000_000)]),
                    now: minute0.addingTimeInterval(60))
            }

            let usage = try history.processUsage(since: minute0, until: minute0.addingTimeInterval(180))
            #expect(usage.byCPU.map(\.name) == ["Safari"])
            #expect(usage.byCPU.first?.minuteCount == 1)   // the failed write added nothing
        }
    }
}
