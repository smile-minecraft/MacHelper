import Foundation
import GRDB
import Testing
@testable import Storage

/// The per-volume capacity table must stay independent of the published v6 `disk_space`
/// table: it stores only points keyed by the caller's opaque volume identifier, keeps one
/// point per volume per hour, and never invents points for missing hours or unknown
/// capacities. The table-creation function is what a later v7 migration will register.
@Suite struct VolumeCapacityHistoryTests {
    /// 1_800_000_000 is a whole hour (500_000 hours since 1970).
    private let hour0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        // Tests normally use the system temporary directory. A caller can point them at an
        // isolated directory (for example a scratch volume) with this environment variable.
        let root = ProcessInfo.processInfo.environment["MACHELPER_TEST_TEMP_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let dir = root.appending(path: "machelper-volume-capacity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    /// Opens the shared history database and completes the published v1-v6 migrations. The
    /// parent connection finishes migrating before any second connection opens, which is the
    /// cross-process initialization rule this database requires.
    private func migratedHistory(url: URL) throws -> MetricsHistory {
        let history = try MetricsHistory(url: url)
        try applyVolumeCapacityMigration(to: history.db)
        return history
    }

    /// Applies the future v7 step exactly as the app will register it. A standalone
    /// migrator with only this step works both before and after the production migrator
    /// gains the same identifier.
    private func applyVolumeCapacityMigration(to db: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v7") { db in
            try VolumeCapacityHistory.createTable(db)
        }
        try migrator.migrate(db)
    }

    private func openPool(_ url: URL) throws -> DatabasePool {
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        return try DatabasePool(path: url.path, configuration: config)
    }

    private func makeStore(_ db: any DatabaseWriter,
                           retention: TimeInterval = VolumeCapacityHistory.defaultRetention) -> VolumeCapacityHistory {
        VolumeCapacityHistory(db: db, retention: retention)
    }

    private func capacity(_ free: Double, _ total: Double) throws -> VolumeCapacity {
        try #require(VolumeCapacity(free: free, total: total))
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

    @Test func storesOnePointPerVolumeAndHour() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in try VolumeCapacityHistory.createTable(db) }
        let store = makeStore(queue)
        let now = hour0.addingTimeInterval(4 * 3_600)

        #expect(try store.record(try capacity(100, 1_000), volume: "volume-a",
                                 at: hour0.addingTimeInterval(5 * 60), now: now))
        // The second write in the same hour is a duplicate, not a replacement or an average.
        #expect(try store.record(try capacity(50, 1_000), volume: "volume-a",
                                 at: hour0.addingTimeInterval(55 * 60), now: now) == false)
        // The same hour for another volume is a separate point.
        #expect(try store.record(try capacity(200, 2_000), volume: "volume-b",
                                 at: hour0.addingTimeInterval(30 * 60), now: now))
        #expect(try store.record(try capacity(90, 1_000), volume: "volume-a",
                                 at: hour0.addingTimeInterval(3_600), now: now))

        let a = try store.points(volume: "volume-a",
                                 since: hour0.addingTimeInterval(-3_600),
                                 until: hour0.addingTimeInterval(7_200))
        #expect(a.map(\.time) == [hour0, hour0.addingTimeInterval(3_600)])
        #expect(a.map(\.free) == [100, 90])
        #expect(a.map(\.total) == [1_000, 1_000])

        let b = try store.points(volume: "volume-b",
                                 since: hour0.addingTimeInterval(-3_600),
                                 until: hour0.addingTimeInterval(7_200))
        #expect(b.count == 1)
        #expect(b.first?.time == hour0)
        #expect(b.first?.free == 200)
        #expect(b.first?.total == 2_000)

        // The range is half-open: `until` itself is not included.
        #expect(try store.points(volume: "volume-a", since: hour0, until: hour0).isEmpty)
    }

    @Test func oneBatchWritesEveryVolumeAndKeepsTheFirstPointPerHour() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in try VolumeCapacityHistory.createTable(db) }
        let store = makeStore(queue)

        // One sample from several volumes, including a second reading for the same volume and
        // an unmeasurable one. The whole batch commits once; the first point per hour wins.
        let readings = [
            VolumeCapacityReading(volume: "volume-a", capacity: try capacity(100, 1_000)),
            VolumeCapacityReading(volume: "volume-b", capacity: try capacity(200, 2_000)),
            VolumeCapacityReading(volume: "volume-a", capacity: try capacity(50, 1_000)),
            VolumeCapacityReading(volume: "volume-c", capacity: nil),
        ]
        #expect(try store.record(readings, at: hour0, now: hour0) == 2)
        #expect(try store.points(volume: "volume-a", since: .distantPast).map(\.free) == [100])
        #expect(try store.points(volume: "volume-b", since: .distantPast).map(\.free) == [200])
        #expect(try store.points(volume: "volume-c", since: .distantPast).isEmpty)
    }

    @Test func missingHoursAndUnknownCapacityStayAbsent() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in try VolumeCapacityHistory.createTable(db) }
        let store = makeStore(queue)
        let now = hour0.addingTimeInterval(4 * 3_600)

        // Record the later hour first so the query has to order the rows.
        #expect(try store.record(try capacity(80, 1_000), volume: "volume-a",
                                 at: hour0.addingTimeInterval(3 * 3_600), now: now))
        #expect(try store.record(try capacity(100, 1_000), volume: "volume-a", at: hour0, now: now))

        // Two stored hours 3 hours apart stay two points; the empty hours are not filled in.
        let points = try store.points(volume: "volume-a",
                                      since: hour0.addingTimeInterval(-3_600),
                                      until: hour0.addingTimeInterval(4 * 3_600))
        #expect(points.map(\.time) == [hour0, hour0.addingTimeInterval(3 * 3_600)])
        #expect(points.map(\.free) == [100, 80])

        // An unavailable reading is not stored as zero.
        #expect(try store.record(nil, volume: "volume-a", at: hour0.addingTimeInterval(3_600), now: now) == false)
        #expect(try store.points(volume: "volume-a",
                                 since: hour0, until: hour0.addingTimeInterval(2 * 3_600)).count == 1)

        // A genuinely full volume is a real zero-free reading, not an unknown one.
        #expect(VolumeCapacity(free: 0, total: 1_000) != nil)
        #expect(VolumeCapacity(free: .nan, total: 1_000) == nil)
        #expect(VolumeCapacity(free: 1, total: 0) == nil)
        #expect(VolumeCapacity(free: -1, total: 1_000) == nil)

        #expect(throws: VolumeCapacityHistoryError.emptyVolumeIdentifier) {
            try store.record(try capacity(1, 2), volume: "", at: hour0)
        }
    }

    @Test func v7TableCreationLeavesLegacyDiskSpaceAndHealthHistoryUntouched() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let now = hour0.addingTimeInterval(3 * 3_600)
            let sampleTime = now.addingTimeInterval(-3_600)
            let history = try MetricsHistory(url: url)

            try history.recordMinute(
                FinishedMinute(time: sampleTime, totals: ["cpu": ColumnTotals(sum: 0.5, count: 1)]),
                now: now)
            try history.recordDiskSpaceIfNeeded(now: now, measure: { (free: 123_000, total: 456_000) })

            let legacyDiskSpace = try history.diskSpace(since: now.addingTimeInterval(-2 * 3_600))
            let legacySamples = try history.samples(since: now.addingTimeInterval(-2 * 3_600), bucket: 60)
            #expect(legacyDiskSpace.count == 1)
            #expect(legacySamples.count == 1)
            #expect(legacySamples.first?.cpu == 0.5)

            // The future v7 step is registered after the published migrations, like the app
            // will register it. Running it against this database applies only the new step.
            try applyVolumeCapacityMigration(to: history.db)

            // The old single-volume rows are still exactly where they were.
            #expect(try history.diskSpace(since: now.addingTimeInterval(-2 * 3_600)) == legacyDiskSpace)
            #expect(try history.samples(since: now.addingTimeInterval(-2 * 3_600), bucket: 60) == legacySamples)
            #expect(try history.count() == 1)

            // Legacy rows carry no volume identity, so they never appear under a guessed one.
            let store = makeStore(history.db)
            #expect(try store.points(volume: "/", since: .distantPast).isEmpty)
            #expect(try store.points(volume: "startup", since: .distantPast).isEmpty)
            let newRowCount = try history.db.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM volume_capacity") ?? -1
            }
            #expect(newRowCount == 0)

            let tables = try history.db.read { db in
                let legacy = try db.tableExists("disk_space")
                let created = try db.tableExists("volume_capacity")
                return (legacy, created)
            }
            #expect(tables.0)
            #expect(tables.1)
        }
    }

    @Test func olderDatabaseWithoutTheTableHasNoPoints() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            _ = try MetricsHistory(url: url)   // v1-v6 only, like a database from the last release
            let reader = try MetricsHistory(url: url, readOnly: true)
            let store = makeStore(reader.db)
            #expect(try store.points(volume: "volume-a", since: .distantPast).isEmpty)
        }
    }

    @Test func retentionPrunesExpiredPointsForEveryVolumeAndKeepsTheBoundary() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in try VolumeCapacityHistory.createTable(db) }
        let retention: TimeInterval = 2 * 3_600
        let store = makeStore(queue, retention: retention)
        let boundary = hour0.addingTimeInterval(-retention)
        let expired = boundary.addingTimeInterval(-3_600)

        #expect(try store.record(try capacity(10, 100), volume: "volume-a", at: expired, now: expired))
        #expect(try store.record(try capacity(20, 100), volume: "volume-b", at: expired, now: expired))
        #expect(try store.record(try capacity(30, 100), volume: "volume-a", at: boundary, now: boundary))
        #expect(try store.record(try capacity(40, 100), volume: "volume-a", at: hour0, now: hour0))

        // A point exactly at the cutoff is kept; older points of every volume are pruned.
        let a = try store.points(volume: "volume-a", since: .distantPast)
        #expect(a.map(\.time) == [boundary, hour0])
        #expect(a.map(\.free) == [30, 40])
        #expect(try store.points(volume: "volume-b", since: .distantPast).isEmpty)
    }

    @Test func clearDeletesOnlyVolumeCapacityRows() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try migratedHistory(url: url)
            try history.recordDiskSpaceIfNeeded(now: hour0, measure: { (free: 1_000, total: 2_000) })
            let store = makeStore(history.db)
            #expect(try store.record(try capacity(100, 1_000), volume: "volume-a", at: hour0, now: hour0))

            // The future HistoryStore.clear path runs inside its own write transaction, so
            // it must call the static function rather than an instance method.
            try history.db.write { db in try VolumeCapacityHistory.deleteAll(db) }
            #expect(try store.points(volume: "volume-a", since: .distantPast).isEmpty)
            #expect(try history.diskSpace(since: hour0.addingTimeInterval(-3_600)).count == 1)

            #expect(try store.record(try capacity(200, 1_000), volume: "volume-b", at: hour0, now: hour0))
            try store.clear()
            #expect(try store.points(volume: "volume-b", since: .distantPast).isEmpty)
            #expect(try history.diskSpace(since: hour0.addingTimeInterval(-3_600)).count == 1)
        }
    }

    @Test func duplicateAndConcurrentWritesAcrossConnectionsKeepOnePoint() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            _ = try migratedHistory(url: url)   // the parent finishes v1-v7 before other connections open
            let poolA = try openPool(url)
            let poolB = try openPool(url)
            defer {
                try? poolA.close()
                try? poolB.close()
            }
            let storeA = makeStore(poolA)
            let storeB = makeStore(poolB)

            // A second connection writing the same hour must not duplicate or replace the point.
            #expect(try storeA.record(try capacity(100, 1_000), volume: "volume-a", at: hour0, now: hour0))
            #expect(try storeB.record(try capacity(50, 1_000), volume: "volume-a",
                                      at: hour0.addingTimeInterval(1_800), now: hour0) == false)
            #expect(try storeB.points(volume: "volume-a",
                                      since: hour0, until: hour0.addingTimeInterval(3_600)).map(\.free) == [100])

            // Two connections writing the same volume and hour at once still leave one point.
            let failures = FailureBox()
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                do {
                    try storeA.record(VolumeCapacity(free: 70, total: 1_000), volume: "volume-c",
                                      at: hour0.addingTimeInterval(3_600), now: hour0)
                } catch {
                    failures.record(error)
                }
            }
            DispatchQueue.global().async(group: group) {
                do {
                    try storeB.record(VolumeCapacity(free: 80, total: 1_000), volume: "volume-c",
                                      at: hour0.addingTimeInterval(3_600), now: hour0)
                } catch {
                    failures.record(error)
                }
            }
            #expect(group.wait(timeout: .now() + 30) == .success)
            #expect(failures.isEmpty)

            let concurrent = try storeA.points(volume: "volume-c",
                                               since: hour0.addingTimeInterval(3_600),
                                               until: hour0.addingTimeInterval(7_200))
            #expect(concurrent.count == 1)
            #expect([70.0, 80.0].contains(concurrent.first?.free ?? -1))

            // The same hour for a different volume is a separate point.
            #expect(try storeB.record(try capacity(90, 2_000), volume: "volume-d",
                                      at: hour0.addingTimeInterval(3_600), now: hour0))
            #expect(try storeA.points(volume: "volume-d",
                                      since: hour0.addingTimeInterval(3_600),
                                      until: hour0.addingTimeInterval(7_200)).count == 1)
        }
    }
}
