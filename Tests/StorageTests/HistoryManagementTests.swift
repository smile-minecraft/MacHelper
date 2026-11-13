import Foundation
import GRDB
import Testing
@testable import Storage

/// The history database is shared by the app and the background recorder, and it will hold
/// more than one kind of history. These tests pin the shared retention setting, the disk
/// footprint shown to the user, and the scope of a destructive clear.
/// The suite runs its tests one at a time so the clear-while-recording test never competes
/// with another test for a shared thread pool.
@Suite(.serialized) struct HistoryManagementTests {
    private let minute0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "machelper-history-management-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func record(_ history: MetricsHistory, cpu: Double, at time: Date, now: Date) throws {
        try history.recordMinute(
            FinishedMinute(time: time, totals: ["cpu": ColumnTotals(sum: cpu, count: 1)]),
            now: now)
    }

    private func openDatabase(_ url: URL) throws -> DatabasePool {
        try DatabasePool(path: url.path, configuration: Configuration())
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [any Error] = []

        func record(_ error: any Error) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(error)
        }

        var isEmpty: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storage.isEmpty
        }
    }

    @Test func retentionDefaultsToSevenDaysAndPersistsAcrossConnections() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")

            do {
                let store = try HistoryStore(url: url)
                #expect(try store.retention() == .sevenDays)
                try store.setRetention(.fourteenDays)
            }

            // Opening the recorder must not reset the user's choice to the built-in default.
            _ = try MetricsHistory(url: url)

            // Reopening is the app and recorder restart path: the value comes from the database.
            let reopened = try HistoryStore(url: url)
            #expect(try reopened.retention() == .fourteenDays)

            // A second connection is the background recorder's view of the same file.
            let otherProcess = try HistoryStore(url: url)
            #expect(try otherProcess.retention() == .fourteenDays)
        }
    }

    @Test func retentionChangeAppliesToTheNextWriteAndNeverRestoresDeletedRows() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let now = Date(timeIntervalSince1970: 1_800_100_000)
            // Open the recorder before the change: pruning must read the setting every time.
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)

            try record(history, cpu: 0.2, at: now.addingTimeInterval(-2 * 86_400), now: now)
            try record(history, cpu: 0.4, at: now.addingTimeInterval(-60), now: now)
            #expect(try history.count() == 2)

            // Changing the setting alone deletes nothing; the next write performs the prune.
            try store.setRetention(.oneDay)
            #expect(try history.count() == 2)
            try record(history, cpu: 0.4, at: now, now: now)
            #expect(try history.count() == 2)   // the 2-day-old row is gone

            try store.setRetention(.thirtyDays)
            #expect(try history.count() == 2)   // extending cannot bring back deleted rows

            try record(history, cpu: 0.6, at: now.addingTimeInterval(-3 * 86_400), now: now)
            #expect(try history.count() == 3)
        }
    }

    @Test func diskUsageIncludesTheDatabaseWalAndSharedMemoryFiles() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            try record(history, cpu: 0.5, at: minute0, now: minute0)
            let store = try HistoryStore(url: url)

            let usage = store.diskUsage()
            let database = fileSize(url)
            let writeAheadLog = fileSize(URL(filePath: url.path + "-wal"))
            let sharedMemory = fileSize(URL(filePath: url.path + "-shm"))

            #expect(usage.databaseBytes == database)
            #expect(usage.writeAheadLogBytes == writeAheadLog)
            #expect(usage.sharedMemoryBytes == sharedMemory)
            #expect(usage.totalBytes == database + writeAheadLog + sharedMemory)
            #expect(usage.databaseBytes > 0)
            #expect(usage.writeAheadLogBytes > 0)
        }
    }

    @Test func clearRemovesOnlyMinuteSamplesAndLeavesSettingsAndOtherKinds() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            try record(history, cpu: 0.2, at: minute0, now: minute0)
            try record(history, cpu: 0.4, at: minute0.addingTimeInterval(60), now: minute0.addingTimeInterval(60))
            let store = try HistoryStore(url: url)
            try store.setRetention(.fourteenDays)

            // A later history kind keeps its rows in the same database.
            let pool = try openDatabase(url)
            try pool.write { db in
                try db.execute(sql: "CREATE TABLE sensor_sample (time datetime PRIMARY KEY)")
                try db.execute(sql: "INSERT INTO sensor_sample (time) VALUES (?)", arguments: [minute0])
            }
            try pool.close()

            // The clear happens before the row written afterwards, so the new minute is
            // not mistaken for one that was already accumulating at clear time.
            try store.clear(.minuteSamples, now: minute0.addingTimeInterval(-60))

            let after = try openDatabase(url)
            let samples = try after.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sample") ?? -1
            }
            let accumulators = try after.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sample_accumulator") ?? -1
            }
            let sensors = try after.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sensor_sample") ?? -1
            }
            try after.close()

            #expect(samples == 0)
            #expect(accumulators == 0)
            #expect(sensors == 1)
            #expect(try store.retention() == .fourteenDays)

            // A row written after the clear starts from zero, not from a stale accumulator.
            try record(history, cpu: 0.9, at: minute0, now: minute0.addingTimeInterval(120))
            #expect(try history.samples(since: minute0, bucket: 60).first?.cpu == 0.9)
        }
    }

    @Test func clearOnReadOnlyDatabaseThrowsAndDeletesNothing() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            try record(history, cpu: 0.5, at: minute0, now: minute0)
            let reader = try HistoryStore(url: url, readOnly: true)

            #expect(throws: (any Error).self) {
                try reader.clear(.minuteSamples)
            }
            #expect(try history.count() == 1)
        }
    }

    @Test func clearingWhileRecordingLeavesNoOldRowsAndAcceptsLaterWrites() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let now = Date(timeIntervalSince1970: 1_800_200_000)
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)

            let oldStart = now.addingTimeInterval(-3_000)
            for index in 0..<50 {
                try record(history, cpu: 0.1,
                           at: oldStart.addingTimeInterval(Double(index) * 60), now: now)
            }

            // The clear and the recording run on their own threads. The group is entered
            // before either thread starts so the wait cannot pass before both have run.
            let failures = FailureBox()
            let group = DispatchGroup()
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                do {
                    try store.clear(.minuteSamples, now: now)
                } catch {
                    failures.record(error)
                }
            }
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                for index in 0..<20 {
                    let time = now.addingTimeInterval(Double(60 + index * 60))
                    do {
                        try history.recordMinute(
                            FinishedMinute(time: time, totals: ["cpu": ColumnTotals(sum: 0.5, count: 1)]),
                            now: time)
                    } catch {
                        failures.record(error)
                    }
                }
            }
            #expect(group.wait(timeout: .now() + 30) == .success)
            #expect(failures.isEmpty)

            let oldEnd = oldStart.addingTimeInterval(49 * 60)
            let oldRows = try history.samples(since: oldStart, bucket: 60).filter { $0.time <= oldEnd }
            #expect(oldRows.isEmpty)

            let later = now.addingTimeInterval(3_600)
            try record(history, cpu: 0.9, at: later, now: later)
            #expect(try history.samples(since: later, bucket: 60).contains { $0.cpu == 0.9 })
        }
    }
}
