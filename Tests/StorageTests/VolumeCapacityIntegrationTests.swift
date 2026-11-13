import Foundation
import GRDB
import Testing
@testable import Storage

/// Integration of the per-volume capacity history with the shared database: the v7
/// migration, the clear boundary, the hourly recorder, and the background agent wiring.
/// Every database lives in a temporary directory and every disk is a fake reading.
@Suite struct VolumeCapacityIntegrationTests {
    /// A whole hour (500_000 hours since 1970).
    private let hour0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let root = ProcessInfo.processInfo.environment["MACHELPER_TEST_TEMP_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let dir = root.appending(path: "machelper-volume-capacity-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func capacity(_ free: Double, _ total: Double) throws -> VolumeCapacity {
        try #require(VolumeCapacity(free: free, total: total))
    }

    private func poolConfiguration() -> Configuration {
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        return config
    }

    /// Builds the database exactly as the last released app left it: the published v1-v6
    /// migrations, one health minute, and one legacy single-volume disk-space point.
    private func makeV6Database(url: URL) throws {
        let pool = try DatabasePool(path: url.path, configuration: poolConfiguration())
        try MetricsHistory.migrator.migrate(pool, upTo: "v6")
        try pool.write { db in
            try db.execute(sql: "INSERT INTO sample (time, cpu) VALUES (?, ?)",
                           arguments: [hour0.addingTimeInterval(-3_600), 0.5])
            try db.execute(sql: """
                INSERT INTO sample_accumulator (time, column, total_sum, total_count)
                VALUES (?, ?, ?, ?)
                """, arguments: [hour0.addingTimeInterval(-3_600), "cpu", 0.5, 1])
            try db.execute(sql: "INSERT INTO disk_space (time, free, total) VALUES (?, ?, ?)",
                           arguments: [hour0, 123_000.0, 456_000.0])
        }
        try pool.close()
    }

    private func migrationIdentifiers(_ db: any DatabaseReader) throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    // MARK: Migration

    @Test func v7MigrationKeepsLegacyRowsAndNeverGuessesTheirVolume() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            try makeV6Database(url: url)
            let beforePool = try DatabasePool(path: url.path, configuration: poolConfiguration())
            let before = try migrationIdentifiers(beforePool)
            try beforePool.close()
            #expect(before == ["v1", "v2", "v3", "v4", "v5", "v6"])

            let history = try MetricsHistory(url: url)
            #expect(try migrationIdentifiers(history.db) == ["v1", "v2", "v3", "v4", "v5", "v6", "v7"])

            // Existing health and disk-space rows are exactly as the old app left them.
            #expect(try history.count() == 1)
            #expect(try history.samples(since: hour0.addingTimeInterval(-7_200), bucket: 60).first?.cpu == 0.5)
            #expect(try history.diskSpace(since: hour0).map(\.free) == [123_000])
            #expect(try history.diskSpace(since: hour0).map(\.total) == [456_000])

            // Legacy rows have no volume identity. They must not appear under a guessed one.
            let store = VolumeCapacityHistory(history: history)
            #expect(try store.points(volume: "/", since: .distantPast).isEmpty)
            #expect(try store.points(volume: "startup", since: .distantPast).isEmpty)
            let capacityRows = try history.db.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM volume_capacity") ?? -1
            }
            #expect(capacityRows == 0)
        }
    }

    @Test func readOnlyOpenOfAV6DatabaseHasNoCapacityTableAndChangesNothing() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            try makeV6Database(url: url)

            // Read-only tools must open the old file without migrating it.
            let reader = try MetricsHistory(url: url, readOnly: true)
            let store = VolumeCapacityHistory(history: reader)
            #expect(try store.points(volume: "volume:AAAA/media:BBBB", since: .distantPast).isEmpty)

            let state = try reader.db.read { db in
                (try db.tableExists("volume_capacity"), try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"))
            }
            #expect(!state.0)
            #expect(state.1 == ["v1", "v2", "v3", "v4", "v5", "v6"])
        }
    }

    @Test func freshDatabaseStoresOnePointPerVolumeAndHourThroughTheSharedConnection() throws {
        try withTempDirectory { dir in
            let history = try MetricsHistory(url: dir.appending(path: "history.sqlite"))
            let store = VolumeCapacityHistory(history: history)

            #expect(try store.record(try capacity(100, 1_000), volume: "volume:AAAA/media:1111",
                                     at: hour0.addingTimeInterval(5 * 60), now: hour0))
            // The same hour for the same volume is a duplicate, not an average.
            #expect(try store.record(try capacity(50, 1_000), volume: "volume:AAAA/media:1111",
                                     at: hour0.addingTimeInterval(55 * 60), now: hour0) == false)
            // The same hour for another volume is a separate row.
            #expect(try store.record(try capacity(200, 2_000), volume: "volume:BBBB/media:2222",
                                     at: hour0.addingTimeInterval(30 * 60), now: hour0))

            let a = try store.points(volume: "volume:AAAA/media:1111",
                                     since: hour0, until: hour0.addingTimeInterval(3_600))
            #expect(a.map(\.free) == [100])
            #expect(a.map(\.total) == [1_000])
            let b = try store.points(volume: "volume:BBBB/media:2222", since: .distantPast)
            #expect(b.map(\.free) == [200])
        }
    }

    // MARK: Clear

    @Test func clearingMonitoringHistoryDropsCapacityRowsAndPreClearReadingsOnly() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            let capacityStore = VolumeCapacityHistory(history: history)
            let clearTime = hour0.addingTimeInterval(30 * 60)

            try capacityStore.record(try capacity(100, 1_000), volume: "volume:AAAA/media:1111",
                                     at: hour0.addingTimeInterval(5 * 60), now: hour0)
            try history.recordDiskSpaceIfNeeded(now: hour0, measure: { (free: 123_000, total: 456_000) })

            try store.clear(.minuteSamples, now: clearTime)
            #expect(try capacityStore.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)
            #expect(try history.diskSpace(since: hour0.addingTimeInterval(-3_600)).isEmpty)

            // A reading sampled before the clear and written afterwards is dropped whole.
            #expect(try capacityStore.record(try capacity(90, 1_000), volume: "volume:AAAA/media:1111",
                                             at: hour0.addingTimeInterval(10 * 60),
                                             now: hour0.addingTimeInterval(40 * 60)) == false)
            #expect(try capacityStore.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)

            // A reading sampled after the clear is new data, even in the same hour.
            #expect(try capacityStore.record(try capacity(80, 1_000), volume: "volume:AAAA/media:1111",
                                             at: hour0.addingTimeInterval(45 * 60),
                                             now: hour0.addingTimeInterval(46 * 60)))
            #expect(try capacityStore.points(volume: "volume:AAAA/media:1111", since: .distantPast).map(\.free) == [80])
        }
    }

    @Test func readingInTheSameSecondAsTheClearStaysCleared() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            let capacityStore = VolumeCapacityHistory(history: history)

            // The clear marker is stored as whole seconds. A reading taken 0.2 s before a
            // clear at 0.8 s must not slip through the truncated marker.
            try store.clear(.minuteSamples, now: hour0.addingTimeInterval(1_800.8))
            #expect(try capacityStore.record(try capacity(90, 1_000), volume: "volume:AAAA/media:1111",
                                             at: hour0.addingTimeInterval(1_800.2),
                                             now: hour0.addingTimeInterval(1_801)) == false)
            #expect(try capacityStore.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)

            // One second later is unambiguously new data.
            #expect(try capacityStore.record(try capacity(80, 1_000), volume: "volume:AAAA/media:1111",
                                             at: hour0.addingTimeInterval(1_801),
                                             now: hour0.addingTimeInterval(1_801)))
            #expect(try capacityStore.points(volume: "volume:AAAA/media:1111", since: .distantPast).map(\.free) == [80])
        }
    }

    @Test func unknownCapacityAndEmptyIdentityStoreNothing() throws {
        try withTempDirectory { dir in
            let history = try MetricsHistory(url: dir.appending(path: "history.sqlite"))
            let store = VolumeCapacityHistory(history: history)

            #expect(try store.record(nil, volume: "volume:AAAA/media:1111", at: hour0) == false)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)
            #expect(throws: VolumeCapacityHistoryError.emptyVolumeIdentifier) {
                try store.record(try capacity(1, 2), volume: "", at: hour0)
            }
            let rows = try history.db.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM volume_capacity") ?? -1
            }
            #expect(rows == 0)

            // The disk layer's raw values become a reading only when every part is usable.
            #expect(VolumeCapacityReading(volumeID: nil, totalBytes: 1_000, availableBytes: 500) == nil)
            #expect(VolumeCapacityReading(volumeID: "", totalBytes: 1_000, availableBytes: 500) == nil)
            #expect(VolumeCapacityReading(volumeID: "volume:AAAA/media:1111", totalBytes: nil, availableBytes: 500) == nil)
            #expect(VolumeCapacityReading(volumeID: "volume:AAAA/media:1111", totalBytes: 1_000, availableBytes: nil) == nil)
            #expect(VolumeCapacityReading(volumeID: "volume:AAAA/media:1111", totalBytes: 0, availableBytes: 500) == nil)
            let reading = VolumeCapacityReading(volumeID: "volume:AAAA/media:1111",
                                                totalBytes: 1_000, availableBytes: 500)
            #expect(reading?.volume == "volume:AAAA/media:1111")
            #expect(reading?.capacity?.free == 500)
            #expect(reading?.capacity?.total == 1_000)
        }
    }

    // MARK: Recorder timing

    /// A counter shared with the sampler closure, which swift-testing may run off the test's
    /// own thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        @discardableResult
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            storage += 1
            return storage
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Bool

        init(_ value: Bool) { storage = value }

        var value: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                storage = newValue
                lock.unlock()
            }
        }
    }

    /// Polls `body` until it returns true or the timeout elapses. The capacity worker runs on
    /// its own queue, so tests wait for the result instead of assuming it is synchronous.
    private func waitUntil(timeout: TimeInterval = 2, _ body: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try body() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return try body()
    }

    /// Ticks until the recorder throws a write failure, or returns false on timeout.
    private func waitForFailure(_ recorder: inout VolumeCapacityRecorder,
                                now: Date, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                _ = try recorder.tick(now: now)
            } catch {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    @Test func recorderSamplesOncePerHourAndSkipsUnmeasurableVolumes() throws {
        try withTempDirectory { dir in
            let history = try MetricsHistory(url: dir.appending(path: "history.sqlite"))
            let counter = Counter()
            var recorder = VolumeCapacityRecorder(
                history: VolumeCapacityHistory(history: history),
                sampler: {
                    counter.increment()
                    return [
                        VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                              capacity: VolumeCapacity(free: 100, total: 1_000)),
                        // A disk without a usable capacity is not written as zero.
                        VolumeCapacityReading(volume: "volume:BBBB/media:2222", capacity: nil),
                    ]
                })

            // The first tick starts the sample on the worker; a later tick applies it.
            #expect(try recorder.tick(now: hour0.addingTimeInterval(1)).didSample == false)
            let firstApplied = try waitUntil {
                try recorder.tick(now: hour0.addingTimeInterval(1)).didSample
            }
            #expect(firstApplied)
            #expect(counter.value == 1)

            // Every tick inside the same hour is a no-op; the loop can run every second.
            for second in 2...10 {
                #expect(try recorder.tick(now: hour0.addingTimeInterval(TimeInterval(second))).hourCompleted)
            }
            #expect(counter.value == 1)

            // The next hour starts and applies a second sample.
            #expect(try recorder.tick(now: hour0.addingTimeInterval(3_601)).didSample == false)
            let secondApplied = try waitUntil {
                try recorder.tick(now: hour0.addingTimeInterval(3_601)).didSample
            }
            #expect(secondApplied)
            #expect(counter.value == 2)

            let store = VolumeCapacityHistory(history: history)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).count == 2)
            #expect(try store.points(volume: "volume:BBBB/media:2222", since: .distantPast).isEmpty)
        }
    }

    @Test func recorderRetriesAFailedHourAfterTheRetryInterval() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            _ = try MetricsHistory(url: url)   // create and migrate
            let reader = try MetricsHistory(url: url, readOnly: true)
            let counter = Counter()
            var recorder = VolumeCapacityRecorder(
                history: VolumeCapacityHistory(history: reader),
                sampler: {
                    counter.increment()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                })

            // The first tick starts the sample; the write failure is reported on the tick
            // that applies the result.
            #expect(try recorder.tick(now: hour0).didSample == false)
            #expect(waitForFailure(&recorder, now: hour0))
            #expect(counter.value == 1)

            // Before the retry interval the recorder does not sample again.
            let waiting = try recorder.tick(now: hour0.addingTimeInterval(30))
            #expect(waiting.didSample == false && waiting.hourCompleted == false)
            #expect(counter.value == 1)

            // After it, the same hour is attempted again.
            #expect(try recorder.tick(now: hour0.addingTimeInterval(61)).didSample == false)
            #expect(waitForFailure(&recorder, now: hour0.addingTimeInterval(61)))
            #expect(counter.value == 2)
        }
    }

    @Test func recorderDoesNotRestoreAnHourClearedAfterItCompleted() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            let counter = Counter()
            var recorder = VolumeCapacityRecorder(
                history: VolumeCapacityHistory(history: history),
                sampler: {
                    counter.increment()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                })

            #expect(try recorder.tick(now: hour0.addingTimeInterval(5 * 60)).didSample == false)
            let capacityStore = VolumeCapacityHistory(history: history)
            let recorded = try waitUntil {
                _ = try recorder.tick(now: hour0.addingTimeInterval(5 * 60))
                return try capacityStore.points(volume: "volume:AAAA/media:1111", since: .distantPast).count == 1
            }
            #expect(recorded)

            // The user clears the history after this process already completed the hour. The
            // recorder must not write the hour back from its in-memory "done" state.
            try store.clear(.minuteSamples, now: hour0.addingTimeInterval(30 * 60))
            #expect(try recorder.tick(now: hour0.addingTimeInterval(40 * 60)).hourCompleted)
            #expect(try capacityStore.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)
            #expect(counter.value == 1)

            // The next hour is new data and records normally.
            #expect(try recorder.tick(now: hour0.addingTimeInterval(3_605)).didSample == false)
            let nextRecorded = try waitUntil {
                _ = try recorder.tick(now: hour0.addingTimeInterval(3_605))
                return try capacityStore.points(volume: "volume:AAAA/media:1111", since: .distantPast).count == 1
            }
            #expect(nextRecorded)
            #expect(counter.value == 2)
        }
    }

    @Test func twoRecordersWritingTheSameHourKeepTheFirstPoint() throws {
        try withTempDirectory { dir in
            let history = try MetricsHistory(url: dir.appending(path: "history.sqlite"))
            let store = VolumeCapacityHistory(history: history)
            let appGate = DispatchSemaphore(value: 0)
            let agentGate = DispatchSemaphore(value: 0)
            var app = VolumeCapacityRecorder(
                history: store,
                sampler: {
                    appGate.wait()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 70, total: 1_000))]
                })
            var agent = VolumeCapacityRecorder(
                history: store,
                sampler: {
                    agentGate.wait()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 80, total: 1_000))]
                })
            defer {
                appGate.signal()
                agentGate.signal()
            }

            // Start both workers, then release the app first so the first-wins order is
            // deterministic even though the samplers now run off the loop.
            #expect(try app.tick(now: hour0).didSample == false)
            #expect(try agent.tick(now: hour0).didSample == false)
            appGate.signal()
            #expect(try waitUntil { try app.tick(now: hour0).didSample })
            #expect(try store.points(volume: "volume:AAAA/media:1111",
                                     since: hour0, until: hour0.addingTimeInterval(3_600)).map(\.free) == [70])

            agentGate.signal()
            #expect(try waitUntil { try agent.tick(now: hour0).didSample })
            #expect(try store.points(volume: "volume:AAAA/media:1111",
                                     since: hour0, until: hour0.addingTimeInterval(3_600)).map(\.free) == [70])
        }
    }

    @Test func recorderDiscardsAFinishedResultWhenDisabledBeforeApplying() throws {
        try withTempDirectory { dir in
            let history = try MetricsHistory(url: dir.appending(path: "history.sqlite"))
            let store = VolumeCapacityHistory(history: history)
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let enabled = Flag(true)
            var recorder = VolumeCapacityRecorder(
                history: store,
                sampler: {
                    started.signal()
                    release.wait()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                },
                session: { enabled.value ? "test" : nil })
            defer { release.signal() }

            #expect(try recorder.tick(now: hour0).didStart)
            #expect(started.wait(timeout: .now() + 2) == .success)

            // The switch is turned off while the sample is in flight.
            enabled.value = false
            release.signal()

            var discarded: VolumeCapacityTickOutcome?
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                let outcome = try recorder.tick(now: hour0)
                if outcome.didDiscard { discarded = outcome; break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(discarded?.didDiscard == true)
            #expect(discarded?.didSample == false)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)

            // While disabled, no new pass starts.
            #expect(try recorder.tick(now: hour0.addingTimeInterval(1)).didStart == false)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)
        }
    }

    // MARK: Background agent

    @Test func agentRecordsCapacityWhileTheProfileIsEnabledEvenWithNoModules() throws {
        try withTempDirectory { dir in
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            let history = try MetricsHistory(url: dir.appending(path: "history.sqlite"))
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true, modules: []), to: profileURL)

            let counter = Counter()
            var recorder = MonitorAgentRecorder(
                profileURL: profileURL, heartbeatURL: heartbeatURL, history: history,
                sampler: { _ in [:] },
                volumeCapacity: VolumeCapacityCollection(sample: {
                    counter.increment()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                }))

            recorder.tick(now: hour0.addingTimeInterval(1))
            #expect(waitUntil { counter.value == 1 })

            // The first tick started the background sample; poll the agent loop until the
            // applied result is written.
            let store = VolumeCapacityHistory(history: history)
            let recorded = waitUntil {
                recorder.tick(now: hour0.addingTimeInterval(2))
                return (try? store.points(volume: "volume:AAAA/media:1111", since: .distantPast).count) == 1
            }
            #expect(recorded)
            #expect(counter.value == 1)

            // The same hour does not sample again, even though the loop ticks every second.
            recorder.tick(now: hour0.addingTimeInterval(3))
            #expect(counter.value == 1)

            // The next timed heartbeat carries the capacity signal, and capacity-only
            // recording is reported as running instead of nothing to record.
            recorder.tick(now: hour0.addingTimeInterval(12))
            let beat = MonitorAgentHeartbeatStore.load(from: heartbeatURL)
            #expect(beat?.lastCapacitySampleAt != nil)
            #expect(BackgroundRecordingStatus.evaluate(serviceStatus: .enabled, profileEnabled: true,
                                                       enabledModuleCount: 0, heartbeat: beat,
                                                       now: hour0.addingTimeInterval(12)) == .running)

            // With background recording disabled the agent must not keep recording.
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: false, modules: []), to: profileURL)
            recorder.tick(now: hour0.addingTimeInterval(3_610))
            #expect(counter.value == 1)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).count == 1)
        }
    }

    @Test func agentSurfacesCapacityWriteFailureInTheHeartbeat() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            _ = try MetricsHistory(url: url)   // create and migrate
            let reader = try MetricsHistory(url: url, readOnly: true)
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true, modules: []), to: profileURL)

            var recorder = MonitorAgentRecorder(
                profileURL: profileURL, heartbeatURL: heartbeatURL, history: reader,
                sampler: { _ in [:] },
                volumeCapacity: VolumeCapacityCollection(sample: {
                    [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                           capacity: VolumeCapacity(free: 100, total: 1_000))]
                }))

            recorder.tick(now: hour0.addingTimeInterval(1))
            let failed = waitUntil {
                recorder.tick(now: hour0.addingTimeInterval(1))
                return MonitorAgentHeartbeatStore.load(from: heartbeatURL)?
                    .lastError?.contains("volume capacity history write failed") == true
            }
            #expect(failed)
            let heartbeat = MonitorAgentHeartbeatStore.load(from: heartbeatURL)
            #expect(heartbeat?.lastError?.contains("volume capacity history write failed") == true)
            // The attempt is visible, but the write failed and must win over any success state.
            #expect(heartbeat?.lastCapacitySampleAt != nil)
            // Capacity-only recording must report the failure, not "nothing to record".
            let reason = heartbeat?.lastError ?? ""
            #expect(BackgroundRecordingStatus.evaluate(serviceStatus: .enabled, profileEnabled: true,
                                                       enabledModuleCount: 0, heartbeat: heartbeat,
                                                       now: hour0.addingTimeInterval(1))
                    == .failed(reason: reason))
        }
    }

    @Test func blockedCapacitySamplerDoesNotStallHeartbeatOrOtherMetrics() throws {
        try withTempDirectory { dir in
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            let history = try MetricsHistory(url: dir.appending(path: "history.sqlite"))
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true,
                                    modules: [ModulePlan(module: "cpu", interval: 1)]),
                to: profileURL)

            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let capacityCalls = Counter()
            let moduleCalls = Counter()
            var recorder = MonitorAgentRecorder(
                profileURL: profileURL, heartbeatURL: heartbeatURL, history: history,
                sampler: { module in
                    moduleCalls.increment()
                    return module == "cpu" ? ["cpu": 0.5] : [:]
                },
                volumeCapacity: VolumeCapacityCollection(sample: {
                    capacityCalls.increment()
                    started.signal()
                    release.wait()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                }))
            defer { release.signal() }

            recorder.tick(now: hour0.addingTimeInterval(1))
            #expect(started.wait(timeout: .now() + 2) == .success)

            // The capacity sampler is still blocked; the agent loop must keep running.
            let begin = Date()
            recorder.tick(now: hour0.addingTimeInterval(11))
            let elapsed = Date().timeIntervalSince(begin)
            #expect(elapsed < 1)
            #expect(moduleCalls.value >= 2)
            #expect(capacityCalls.value == 1)
            let beat = MonitorAgentHeartbeatStore.load(from: heartbeatURL)
            #expect(beat?.lastHeartbeatAt == hour0.addingTimeInterval(11))
            #expect(beat?.lastSampleAt == hour0.addingTimeInterval(11))
            // The capacity attempt is recorded even while its sampler is still blocked.
            #expect(beat?.lastCapacitySampleAt == hour0.addingTimeInterval(1))
            #expect(beat?.lastError == nil)

            // Many more ticks while blocked must not start another sample.
            for second in 12...30 {
                recorder.tick(now: hour0.addingTimeInterval(TimeInterval(second)))
            }
            #expect(capacityCalls.value == 1)

            // Releasing the sampler lets the result arrive; the point keeps the sample time.
            release.signal()
            let store = VolumeCapacityHistory(history: history)
            let recorded = waitUntil {
                recorder.tick(now: hour0.addingTimeInterval(31))
                return (try? store.points(volume: "volume:AAAA/media:1111", since: .distantPast).count) == 1
            }
            #expect(recorded)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).first?.time == hour0)

            // The next heartbeat carries the capacity signal.
            recorder.tick(now: hour0.addingTimeInterval(41))
            let after = MonitorAgentHeartbeatStore.load(from: heartbeatURL)
            #expect(after?.lastCapacitySampleAt != nil)
        }
    }

    @Test func disablingBackgroundRecordingDiscardsAnInFlightCapacitySample() throws {
        try withTempDirectory { dir in
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            let history = try MetricsHistory(url: dir.appending(path: "history.sqlite"))
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true, modules: []), to: profileURL)

            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let capacityCalls = Counter()
            var recorder = MonitorAgentRecorder(
                profileURL: profileURL, heartbeatURL: heartbeatURL, history: history,
                sampler: { _ in [:] },
                volumeCapacity: VolumeCapacityCollection(sample: {
                    capacityCalls.increment()
                    started.signal()
                    release.wait()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                }))
            defer { release.signal() }

            recorder.tick(now: hour0.addingTimeInterval(1))
            #expect(started.wait(timeout: .now() + 2) == .success)

            // Turn background recording off while the sample is blocked, then let it finish.
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: false, modules: []), to: profileURL)
            recorder.tick(now: hour0.addingTimeInterval(6))
            release.signal()
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                recorder.tick(now: hour0.addingTimeInterval(7))
                Thread.sleep(forTimeInterval: 0.01)
            }

            let store = VolumeCapacityHistory(history: history)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)
            #expect(capacityCalls.value == 1)
            // The attempt that started before the disable is visible in the heartbeat, but its
            // result was discarded and never written to history.
            let beat = MonitorAgentHeartbeatStore.load(from: heartbeatURL)
            #expect(beat?.lastCapacitySampleAt == hour0.addingTimeInterval(1))
        }
    }

    /// The exact race the independent review reproduced: the sample starts at t=1, the profile
    /// is written disabled at t=2, and the result finishes at t=3, before the agent's
    /// five-second profile reload. The result must be discarded; re-enabling later must take a
    /// fresh sample, not resurrect the discarded one.
    @Test func capacityResultIsDiscardedWhenTheProfileWasDisabledBeforeTheReload() throws {
        try withTempDirectory { dir in
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            let history = try MetricsHistory(url: dir.appending(path: "history.sqlite"))
            let store = VolumeCapacityHistory(history: history)
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true, modules: []), to: profileURL)

            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let capacityCalls = Counter()
            var recorder = MonitorAgentRecorder(
                profileURL: profileURL, heartbeatURL: heartbeatURL, history: history,
                sampler: { _ in [:] },
                volumeCapacity: VolumeCapacityCollection(sample: {
                    let call = capacityCalls.increment()
                    if call == 1 {
                        started.signal()
                        release.wait()
                    }
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                }))
            defer { release.signal() }

            // t=1: the sample starts and blocks.
            recorder.tick(now: hour0.addingTimeInterval(1))
            #expect(started.wait(timeout: .now() + 2) == .success)

            // t=2: the user disables background recording. The agent has not reloaded yet.
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: false, modules: []), to: profileURL)

            // t=3: the result arrives before the five-second reload. It must be discarded.
            release.signal()
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                recorder.tick(now: hour0.addingTimeInterval(3))
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)
            #expect(capacityCalls.value == 1)

            // The reload at t=6 confirms the disable and must not start another sample.
            recorder.tick(now: hour0.addingTimeInterval(6))
            #expect(capacityCalls.value == 1)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)

            // Re-enabling takes a fresh sample; the discarded result is never written.
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true, modules: []), to: profileURL)
            recorder.tick(now: hour0.addingTimeInterval(12))
            let recorded = waitUntil {
                recorder.tick(now: hour0.addingTimeInterval(13))
                return (try? store.points(volume: "volume:AAAA/media:1111", since: .distantPast).count) == 1
            }
            #expect(recorded)
            #expect(capacityCalls.value == 2)
        }
    }

    @Test func emptyCapacitySampleRetriesWithinTheHour() throws {
        try withTempDirectory { dir in
            let history = try MetricsHistory(url: dir.appending(path: "history.sqlite"))
            let calls = Counter()
            var recorder = VolumeCapacityRecorder(
                history: VolumeCapacityHistory(history: history),
                sampler: {
                    calls.increment()
                    if calls.value == 1 { return [] }
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                })

            // The first pass is empty. It counts as a sample but must not close the hour, or a
            // login before Disk Arbitration is ready would delay the first point by an hour.
            var firstOutcome: VolumeCapacityTickOutcome?
            #expect(try recorder.tick(now: hour0).didSample == false)
            let applied = try waitUntil {
                let outcome = try recorder.tick(now: hour0)
                if outcome.didSample { firstOutcome = outcome; return true }
                return false
            }
            #expect(applied)
            #expect(firstOutcome?.hourCompleted == false)
            #expect(calls.value == 1)
            let store = VolumeCapacityHistory(history: history)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)

            // Before the retry interval no new sample.
            #expect(try recorder.tick(now: hour0.addingTimeInterval(30)).didSample == false)
            #expect(calls.value == 1)

            // After it, the same hour is sampled again and the point is written.
            #expect(try recorder.tick(now: hour0.addingTimeInterval(61)).didSample == false)
            let recorded = try waitUntil {
                _ = try recorder.tick(now: hour0.addingTimeInterval(61))
                return try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).count == 1
            }
            #expect(recorded)
            #expect(calls.value == 2)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).first?.time == hour0)
        }
    }

    @Test func blockedCapacitySampleTakenBeforeAClearIsNotWritten() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)
            let store = try HistoryStore(url: url)
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            var recorder = VolumeCapacityRecorder(
                history: VolumeCapacityHistory(history: history),
                sampler: {
                    started.signal()
                    release.wait()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                })
            defer { release.signal() }

            #expect(try recorder.tick(now: hour0).didSample == false)
            #expect(started.wait(timeout: .now() + 2) == .success)

            // The user clears while the sample is blocked; the reading was taken before it.
            try store.clear(.minuteSamples, now: hour0.addingTimeInterval(30 * 60))
            release.signal()

            let capacityStore = VolumeCapacityHistory(history: history)
            let deadline = Date().addingTimeInterval(2)
            var applied = false
            var recorded = false
            while Date() < deadline {
                let outcome = try recorder.tick(now: hour0.addingTimeInterval(31 * 60))
                if outcome.didSample { applied = true }
                recorded = try capacityStore.points(volume: "volume:AAAA/media:1111", since: .distantPast).count == 1
                if recorded { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            // The blocked result really came back; the clear boundary, not a lost sample,
            // is what kept it out of the table.
            #expect(applied)
            #expect(!recorded)
            #expect(try capacityStore.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)
        }
    }
}
