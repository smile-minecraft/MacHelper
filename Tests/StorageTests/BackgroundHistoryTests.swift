import Foundation
import GRDB
import Testing
@testable import Storage

/// Regression tests for history recording beyond the app's lifetime: the app and a
/// user-level background recorder may both write the shared minute history, so merged
/// averages must not lose observations, and charts must not paint across missing minutes.
@Suite struct BackgroundHistoryTests {
    /// A whole minute in epoch time, stable across runs.
    private let minute0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "machelper-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    /// Builds a FinishedMinute with the given per-column totals (sum, count).
    private func finished(_ time: Date,
                          cpu: (sum: Double, count: Int)? = nil,
                          gpu: (sum: Double, count: Int)? = nil,
                          memory: (sum: Double, count: Int)? = nil,
                          temperature: (sum: Double, count: Int)? = nil,
                          battery: (sum: Double, count: Int)? = nil) -> FinishedMinute {
        var totals: [String: ColumnTotals] = [:]
        func apply(_ col: String, _ t: (sum: Double, count: Int)?) {
            guard let t, t.count > 0 else { return }
            totals[col] = ColumnTotals(sum: t.sum, count: t.count)
        }
        apply("cpu", cpu)
        apply("gpu", gpu)
        apply("memory", memory)
        apply("temperature", temperature)
        apply("battery", battery)
        return FinishedMinute(time: time, totals: totals)
    }

    /// Builds a v1 database by hand and fills it with old-era rows.
    private func makeLegacyV1Database(url: URL, rows: [(Date, [String: Double])]) throws {
        let pool = try DatabasePool(path: url.path, configuration: Configuration())
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE sample (time datetime primary key on conflict replace,
                    cpu double, gpu double, memory double, temperature double, fan double, power double,
                    networkIn double, networkOut double, diskRead double, diskWrite double, battery double)
                """)
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
            for (time, columns) in rows {
                let names = columns.keys.sorted()
                guard !names.isEmpty else { continue }
                let columnList = (["time"] + names).joined(separator: ", ")
                let placeholders = Array(repeating: "?", count: names.count + 1).joined(separator: ", ")
                let values: [DatabaseValueConvertible] = [time] + names.map { columns[$0]! }
                try db.execute(sql: "INSERT INTO sample (\(columnList)) VALUES (\(placeholders))",
                               arguments: StatementArguments(values))
            }
        }
        try pool.close()
    }

    // MARK: Existing data stays readable and writable

    @Test func legacyDatabaseRemainsReadable() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            try makeLegacyV1Database(url: url, rows: [(minute0, ["cpu": 0.42, "memory": 0.5])])

            let reopened = try MetricsHistory(url: url)
            #expect(try reopened.count() == 1)
            let rows = try reopened.samples(since: minute0, bucket: 60)
            #expect(rows.first?.cpu == 0.42)
            #expect(rows.first?.memory == 0.5)

            // The read-only path used by the CLI must not run migrations but must still read.
            let reader = try MetricsHistory(url: url, readOnly: true)
            #expect(try reader.count() == 1)
        }
    }

    // MARK: Merging a minute written partly by two writers

    @Test func overlappingWritersDoNotLoseEarlierValues() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)

            // App accumulates minute M with four CPU readings and one memory reading …
            try history.recordMinute(
                finished(minute0, cpu: (sum: 2.0, count: 4), memory: (sum: 0.4, count: 1)),
                now: minute0)
            // … then the background recorder flushes the same minute it only saw GPU data for.
            try history.recordMinute(
                finished(minute0, gpu: (sum: 2.4, count: 3)),
                now: minute0.addingTimeInterval(30))

            let rows = try history.samples(since: minute0, bucket: 60)
            #expect(rows.count == 1)
            #expect(rows.first?.cpu == 0.5)    // 2.0 / 4; must not be wiped by a REPLACE insert
            #expect(rows.first?.memory == 0.4)
            #expect(abs((rows.first?.gpu ?? 0) - 0.8) < 1e-9)    // 2.4 / 3
        }
    }

    @Test func handoffMergesColumnsByRealSampleCounts() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)

            // App hands off with four CPU readings averaged to 0.5 …
            try history.recordMinute(
                finished(minute0, cpu: (sum: 2.0, count: 4)),
                now: minute0)
            // … and the agent adds one more CPU reading of 0.9 for the same minute.
            try history.recordMinute(
                finished(minute0, cpu: (sum: 0.9, count: 1)),
                now: minute0.addingTimeInterval(30))

            let rows = try history.samples(since: minute0, bucket: 60)
            #expect(rows.count == 1)
            // The merged average over all five observations, not the app's 0.5, not 0.9.
            #expect(abs((rows.first?.cpu ?? 0) - 0.58) < 1e-9)
        }
    }

    @Test func legacyColumnSurvivesWrites() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            // A v1 row written by the old app: the average exists but the true sample
            // count is unknowable, so the merge must not invent one.
            try makeLegacyV1Database(url: url, rows: [(minute0, ["cpu": 0.5])])

            let history = try MetricsHistory(url: url)
            try history.recordMinute(
                finished(minute0, cpu: (sum: 0.9, count: 1)),
                now: minute0)

            let rows = try history.samples(since: minute0, bucket: 60)
            #expect(rows.first?.cpu == 0.5)    // the legacy aggregate is never overwritten
        }
    }

    @Test func unsampledMetricsStayAbsent() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let history = try MetricsHistory(url: url)

            try history.recordMinute(
                finished(minute0, memory: (sum: 0.5, count: 1)),
                now: minute0)

            let rows = try history.samples(since: minute0, bucket: 60)
            #expect(rows.first?.memory == 0.5)
            #expect(rows.first?.cpu == nil)
            #expect(rows.first?.battery == nil)
            #expect(rows.first?.power == nil)
        }
    }

    // MARK: Two connections, one database (real contention, same clock)

    private final class WriteErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [any Error] = []

        func record(_ error: any Error) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(error)
        }

        var errors: [any Error] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @Test func concurrentConnectionsMergeEveryObservationIntoOneMinute() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            // Create and migrate the database first; the race under test is the minute
            // merge, not first-time schema creation.
            _ = try MetricsHistory(url: url).count()

            let first = try MetricsHistory(url: url)
            let second = try MetricsHistory(url: url)
            let low = finished(minute0, cpu: (sum: 0.2, count: 1))
            let high = finished(minute0, cpu: (sum: 0.9, count: 1))
            let writeErrors = WriteErrorBox()

            // Two connections, each on its own thread, writing the same minute at once.
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                let history = index == 0 ? first : second
                let minute = index == 0 ? low : high
                do {
                    for _ in 0..<20 {
                        try history.recordMinute(minute, now: minute0)
                    }
                } catch {
                    writeErrors.record(error)
                }
            }
            #expect(writeErrors.errors.isEmpty, "write errors: \(writeErrors.errors)")

            // Every observation from both writers is in the accumulator: 20 × 0.2 and 20 × 0.9.
            let pool = try DatabasePool(path: url.path, configuration: Configuration())
            let total = try pool.read {
                try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(total_count), 0) FROM sample_accumulator WHERE time = ?",
                                 arguments: [minute0]) ?? 0
            }
            #expect(total == 40)
            try pool.close()

            let rows = try first.samples(since: minute0, bucket: 60)
            #expect(rows.count == 1)
            #expect(abs((rows.first?.cpu ?? 0) - 0.55) < 1e-9)    // (20 × 0.2 + 20 × 0.9) / 40
        }
    }

    // MARK: Chart segmentation

    @Test func segmentsSplitAtOneMissingBucket() {
        func points(_ offsets: [TimeInterval]) -> [MetricSample] {
            offsets.map { MetricSample(time: minute0.addingTimeInterval($0)) }
        }

        // Missing the 120s point between 0 and 180: the line must break, not join across it.
        let segments = HistorySegments.split(points([0, 60, 180]), time: \.time, maxGap: 60)
        #expect(segments.map(\.count) == [2, 1])
        if segments.count == 2 {
            #expect(segments[1].first?.time == minute0.addingTimeInterval(180))
        }

        let gappy = points([0, 60, 120, 600, 660, 3600])
        let all = HistorySegments.split(gappy, time: \.time, maxGap: 60)
        #expect(all.map(\.count) == [3, 2, 1])

        // A gap exactly at the threshold stays in the same segment; beyond it splits.
        #expect(HistorySegments.split(points([0, 60]), time: \.time, maxGap: 60).count == 1)
        #expect(HistorySegments.split(points([0, 61]), time: \.time, maxGap: 60).count == 2)

        #expect(HistorySegments.split([MetricSample](), time: \.time, maxGap: 60).isEmpty)
    }

    // MARK: Background service state

    private func heartbeat(lastHeartbeatAt: Date, lastSampleAt: Date?, lastError: String? = nil) -> MonitorAgentHeartbeat {
        MonitorAgentHeartbeat(pid: 4242, lastHeartbeatAt: lastHeartbeatAt,
                              lastSampleAt: lastSampleAt, lastError: lastError)
    }

    @Test func stateReflectsServiceAndHeartbeat() {
        let now = minute0.addingTimeInterval(10_000)
        let liveBeat = heartbeat(lastHeartbeatAt: now.addingTimeInterval(-30), lastSampleAt: now.addingTimeInterval(-30))
        let staleSample = heartbeat(lastHeartbeatAt: now.addingTimeInterval(-30), lastSampleAt: now.addingTimeInterval(-600))
        let noSample = heartbeat(lastHeartbeatAt: now.addingTimeInterval(-30), lastSampleAt: nil)
        let staleBeat = heartbeat(lastHeartbeatAt: now.addingTimeInterval(-600), lastSampleAt: now.addingTimeInterval(-30))
        let failing = heartbeat(lastHeartbeatAt: now.addingTimeInterval(-30), lastSampleAt: now.addingTimeInterval(-30),
                                lastError: "disk full")

        #expect(BackgroundRecordingStatus.evaluate(serviceStatus: .enabled, profileEnabled: true,
                                                   enabledModuleCount: 1,
                                                   heartbeat: liveBeat, now: now) == .running)
        #expect(BackgroundRecordingStatus.evaluate(serviceStatus: .enabled, profileEnabled: true,
                                                   enabledModuleCount: 1,
                                                   heartbeat: staleSample, now: now) == .stopped)
        #expect(BackgroundRecordingStatus.evaluate(serviceStatus: .enabled, profileEnabled: true,
                                                   enabledModuleCount: 1,
                                                   heartbeat: noSample, now: now) == .stopped)
        #expect(BackgroundRecordingStatus.evaluate(serviceStatus: .enabled, profileEnabled: true,
                                                   enabledModuleCount: 1,
                                                   heartbeat: staleBeat, now: now) == .stopped)
        #expect(BackgroundRecordingStatus.evaluate(serviceStatus: .enabled, profileEnabled: true,
                                                   enabledModuleCount: 1,
                                                   heartbeat: failing, now: now) == .failed(reason: "disk full"))
        #expect(BackgroundRecordingStatus.evaluate(serviceStatus: .requiresApproval, profileEnabled: true,
                                                   enabledModuleCount: 1,
                                                   heartbeat: nil, now: now) == .pendingApproval)
        #expect(BackgroundRecordingStatus.evaluate(serviceStatus: .notFound, profileEnabled: true,
                                                   enabledModuleCount: 1,
                                                   heartbeat: nil, now: now) == .failed(reason: "service not found"))
        #expect(BackgroundRecordingStatus.evaluate(serviceStatus: .notRegistered, profileEnabled: true,
                                                   enabledModuleCount: 1,
                                                   heartbeat: nil, now: now) == .failed(reason: "service not registered"))
        #expect(BackgroundRecordingStatus.evaluate(serviceStatus: .enabled, profileEnabled: false,
                                                   enabledModuleCount: 1,
                                                   heartbeat: liveBeat, now: now) == .notEnabled)
        // All metrics off: there is nothing to record, which must not look like a stopped recorder.
        #expect(BackgroundRecordingStatus.evaluate(serviceStatus: .enabled, profileEnabled: true,
                                                   enabledModuleCount: 0,
                                                   heartbeat: noSample, now: now) == .nothingToRecord)
    }

    // MARK: Profile

    @Test func profileRoundTripsThroughStore() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "monitor-agent.json")
            let profile = MonitorAgentProfile(backgroundRecordingEnabled: true,
                                              modules: [ModulePlan(module: "cpu", interval: 2)])
            try MonitorAgentProfileStore.save(profile, to: url)
            #expect(MonitorAgentProfileStore.load(from: url) == profile)

            // A corrupt file must not be silently accepted.
            try Data("not json".utf8).write(to: url)
            #expect(MonitorAgentProfileStore.load(from: url) == nil)
        }
    }

    // MARK: Background recorder loop

    @Test func recorderWritesFinishedMinutesAndHeartbeat() throws {
        try withTempDirectory { dir in
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            let history = try MetricsHistory(url: dir.appending(path: "history.sqlite"))
            let profile = MonitorAgentProfile(
                backgroundRecordingEnabled: true,
                modules: [ModulePlan(module: "cpu", interval: 1)])
            try MonitorAgentProfileStore.save(profile, to: profileURL)

            var recorder = MonitorAgentRecorder(
                profileURL: profileURL, heartbeatURL: heartbeatURL, history: history,
                sampler: { module in module == "cpu" ? ["cpu": 0.5] : [:] })

            // The minute is still open: nothing is written yet.
            recorder.tick(now: minute0.addingTimeInterval(1))
            #expect(try history.count() == 0)

            // The next sample starts a new minute, so the finished one is persisted.
            recorder.tick(now: minute0.addingTimeInterval(61))
            let rows = try history.samples(since: minute0, bucket: 60)
            #expect(rows.count == 1)
            #expect(rows.first?.cpu == 0.5)

            let beat = MonitorAgentHeartbeatStore.load(from: heartbeatURL)
            #expect(beat?.lastSampleAt == minute0.addingTimeInterval(61))
            #expect(beat?.lastError == nil)
        }
    }

    // MARK: Failure surfacing

    /// A failed history write must stay in the heartbeat until a write succeeds: the
    /// recorder crosses several ticks between heartbeats, so a per-tick error would be lost
    /// and the app would report Recording while every minute failed to persist.
    @Test func writeFailurePersistsInHeartbeatUntilAWriteSucceeds() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            _ = try MetricsHistory(url: url).count()   // create and migrate
            let readOnly = try MetricsHistory(url: url, readOnly: true)
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true,
                                    modules: [ModulePlan(module: "cpu", interval: 1)]),
                to: profileURL)

            var recorder = MonitorAgentRecorder(
                profileURL: profileURL, heartbeatURL: heartbeatURL, history: readOnly,
                sampler: { module in module == "cpu" ? ["cpu": 0.5] : [:] })

            // Open minute 0, then heartbeat at t+1 and t+55 so the write failure at t+61
            // lands between two timed heartbeats.
            recorder.tick(now: minute0.addingTimeInterval(1))
            recorder.tick(now: minute0.addingTimeInterval(55))
            recorder.tick(now: minute0.addingTimeInterval(61))

            // The failure reaches the file at once instead of waiting for the next beat.
            let failed = MonitorAgentHeartbeatStore.load(from: heartbeatURL)
            #expect(failed?.lastError?.contains("history write failed") == true)

            // Eleven seconds later the regular heartbeat runs; the error must still be there.
            recorder.tick(now: minute0.addingTimeInterval(72))
            let beat = MonitorAgentHeartbeatStore.load(from: heartbeatURL)
            #expect(beat?.lastError == failed?.lastError)
            #expect(beat?.lastHeartbeatAt == minute0.addingTimeInterval(72))
            #expect(BackgroundRecordingStatus.evaluate(
                serviceStatus: .enabled, profileEnabled: true, enabledModuleCount: 1,
                heartbeat: beat, now: minute0.addingTimeInterval(72))
                == .failed(reason: beat?.lastError ?? ""))
        }
    }

    @Test func recordMinuteOnReadOnlyDatabaseThrows() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            _ = try MetricsHistory(url: url)   // creates and migrates
            let reader = try MetricsHistory(url: url, readOnly: true)
            #expect(throws: (any Error).self) {
                try reader.recordMinute(FinishedMinute(time: minute0, totals: [:]),
                                        now: minute0)
            }
        }
    }
}
