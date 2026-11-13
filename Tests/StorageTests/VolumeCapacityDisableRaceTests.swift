import Foundation
import GRDB
import Testing
@testable import Storage

/// Ordering between a background-recording disable and a capacity write that is already in
/// flight. Every database and profile lives in a temporary directory; the disk is a fake
/// reading and the write blocker is a second SQLite connection, not real disk activity.
@Suite struct VolumeCapacityDisableRaceTests {
    private struct LockProbeError: Error {}
    /// A whole hour (500_000 hours since 1970).
    private let hour0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let root = ProcessInfo.processInfo.environment["MACHELPER_TEST_TEMP_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let dir = root.appending(path: "machelper-capacity-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

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

    private final class ErrorBox: @unchecked Sendable {
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

    private func waitUntil(timeout: TimeInterval = 2, _ body: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try body() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return try body()
    }

    private func poolConfiguration() -> Configuration {
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        return config
    }

    /// Holds SQLite's writer lock from a second connection until `releaseBlocker` is
    /// signalled. This is the same lock the agent's capacity insert waits on.
    private func holdWriterLock(url: URL,
                                ready: DispatchSemaphore,
                                release: DispatchSemaphore,
                                done: DispatchSemaphore,
                                errors: ErrorBox) {
        DispatchQueue.global().async {
            do {
                let blocker = try DatabaseQueue(path: url.path, configuration: self.poolConfiguration())
                try blocker.writeWithoutTransaction { db in
                    try db.execute(sql: "BEGIN IMMEDIATE")
                    ready.signal()
                    release.wait()
                    try db.execute(sql: "ROLLBACK")
                }
                try blocker.close()
            } catch {
                errors.record(error)
            }
            done.signal()
        }
    }

    /// The independent review's exact reproduction: a capacity result has already been
    /// produced and is waiting for SQLite's writer lock when the user disables. The profile
    /// save must wait for that write instead of returning first and leaving a write that
    /// lands after the disable was reported complete.
    @Test func disableWaitsForAnInFlightCapacityWriteBeforeItReturns() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            let history = try MetricsHistory(url: url)
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true, modules: [],
                                    capacityGeneration: "generation-1"),
                to: profileURL)

            let blockerReady = DispatchSemaphore(value: 0)
            let releaseBlocker = DispatchSemaphore(value: 0)
            let blockerDone = DispatchSemaphore(value: 0)
            let blockerErrors = ErrorBox()
            holdWriterLock(url: url, ready: blockerReady, release: releaseBlocker,
                           done: blockerDone, errors: blockerErrors)
            defer { releaseBlocker.signal() }
            #expect(blockerReady.wait(timeout: .now() + 2) == .success)

            let capacityCalls = Counter()
            var recorder = MonitorAgentRecorder(
                profileURL: profileURL, heartbeatURL: heartbeatURL, history: history,
                sampler: { _ in [:] },
                volumeCapacity: VolumeCapacityCollection(sample: {
                    capacityCalls.increment()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                }))

            // Start the sample. Its result is applied away from the loop; the apply holds the
            // shared profile lock while it waits for SQLite's writer lock.
            recorder.tick(now: hour0.addingTimeInterval(1))
            #expect(waitUntil { capacityCalls.value == 1 })
            let holdsSharedLock = waitUntil {
                do {
                    try MonitorAgentProfileStore.withExclusiveLock(at: profileURL, timeout: 0.01) { }
                    return false
                } catch MonitorAgentProfileStoreError.lockTimeout {
                    return true
                } catch {
                    return false
                }
            }
            #expect(holdsSharedLock, "the in-flight apply must hold the shared profile lock")

            // The user disables. The save must not report success before the in-flight write
            // has finished. Release the blocker from another queue so the save itself is the
            // call that waits; without the shared lock it would return immediately.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { releaseBlocker.signal() }
            let saveBegin = Date()
            do {
                try MonitorAgentProfileStore.save(
                    MonitorAgentProfile(backgroundRecordingEnabled: false, modules: [],
                                        capacityGeneration: "generation-2"),
                    to: profileURL)
            } catch {
                Issue.record("the disable save failed: \(error)")
            }
            let saveElapsed = Date().timeIntervalSince(saveBegin)
            #expect(saveElapsed >= 0.15, "disable must wait for the in-flight capacity write")
            #expect(saveElapsed < 1.5, "disable must not wait indefinitely")
            #expect(MonitorAgentProfileStore.load(from: profileURL)?.backgroundRecordingEnabled == false)

            #expect(blockerDone.wait(timeout: .now() + 2) == .success)
            #expect(blockerErrors.isEmpty)

            // The write committed before the disable returned; after it, the disabled profile
            // prevents any new pass.
            let store = VolumeCapacityHistory(history: history)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).count == 1)
            recorder.tick(now: hour0.addingTimeInterval(2))
            #expect(capacityCalls.value == 1)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).count == 1)
        }
    }

    /// A sample taken under generation 1 must not be written after the user disables and
    /// re-enables before the sample finishes. The new generation takes a fresh sample.
    @Test func reEnablingBeforeTheApplyDoesNotResurrectThePreDisableSample() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            let history = try MetricsHistory(url: url)
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true, modules: [],
                                    capacityGeneration: "generation-1"),
                to: profileURL)

            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let calls = Counter()
            var recorder = MonitorAgentRecorder(
                profileURL: profileURL, heartbeatURL: heartbeatURL, history: history,
                sampler: { _ in [:] },
                volumeCapacity: VolumeCapacityCollection(sample: {
                    let call = calls.increment()
                    if call == 1 {
                        started.signal()
                        release.wait()
                    }
                    return [VolumeCapacityReading(
                        volume: "volume:AAAA/media:1111",
                        capacity: VolumeCapacity(free: call == 1 ? 100 : 200, total: 1_000))]
                }))
            defer { release.signal() }

            recorder.tick(now: hour0.addingTimeInterval(1))
            #expect(started.wait(timeout: .now() + 2) == .success)

            // Disable and re-enable while the first sample is still blocked.
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: false, modules: [],
                                    capacityGeneration: "generation-2"),
                to: profileURL)
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true, modules: [],
                                    capacityGeneration: "generation-3"),
                to: profileURL)
            release.signal()

            let store = VolumeCapacityHistory(history: history)
            let settled = waitUntil {
                recorder.tick(now: hour0.addingTimeInterval(2))
                return calls.value >= 1
            }
            #expect(settled)
            // The pre-disable sample is dropped even though the profile is enabled again.
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)

            // The re-enabled session takes its own sample and stores that value.
            recorder.tick(now: hour0.addingTimeInterval(10))
            let recorded = try waitUntil {
                recorder.tick(now: hour0.addingTimeInterval(11))
                return try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).count == 1
            }
            #expect(recorded)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).first?.free == 200)
            #expect(calls.value == 2)
        }
    }

    /// The app records while it runs even when background recording is off; the background
    /// recorder must not sample at all under the disabled profile.
    @Test func foregroundRecorderKeepsRecordingWhileBackgroundIsDisabled() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            let history = try MetricsHistory(url: url)
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: false, modules: [],
                                    capacityGeneration: "generation-2"),
                to: profileURL)

            let appCalls = Counter()
            var app = VolumeCapacityRecorder(
                history: VolumeCapacityHistory(history: history),
                sampler: {
                    appCalls.increment()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 70, total: 1_000))]
                })
            #expect(try app.tick(now: hour0).didSample == false)
            let appRecorded = try waitUntil { try app.tick(now: hour0.addingTimeInterval(1)).didSample }
            #expect(appRecorded)
            let store = VolumeCapacityHistory(history: history)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).map(\.free) == [70])

            let agentCalls = Counter()
            var agent = MonitorAgentRecorder(
                profileURL: profileURL, heartbeatURL: heartbeatURL, history: history,
                sampler: { _ in [:] },
                volumeCapacity: VolumeCapacityCollection(sample: {
                    agentCalls.increment()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 80, total: 1_000))]
                }))
            agent.tick(now: hour0.addingTimeInterval(2))
            agent.tick(now: hour0.addingTimeInterval(3))
            #expect(agentCalls.value == 0)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).map(\.free) == [70])
        }
    }

    /// A profile that becomes unreadable while a sample is in flight is a closed door, not a
    /// reason to write the old sample.
    @Test func unreadableProfileDiscardsAnInFlightSample() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            let history = try MetricsHistory(url: url)
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true, modules: [],
                                    capacityGeneration: "generation-1"),
                to: profileURL)

            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let calls = Counter()
            var recorder = MonitorAgentRecorder(
                profileURL: profileURL, heartbeatURL: heartbeatURL, history: history,
                sampler: { _ in [:] },
                volumeCapacity: VolumeCapacityCollection(sample: {
                    calls.increment()
                    started.signal()
                    release.wait()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                }))
            defer { release.signal() }

            recorder.tick(now: hour0.addingTimeInterval(1))
            #expect(started.wait(timeout: .now() + 2) == .success)
            try Data("not json".utf8).write(to: profileURL)
            release.signal()

            let store = VolumeCapacityHistory(history: history)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                recorder.tick(now: hour0.addingTimeInterval(2))
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)
            #expect(calls.value == 1)
        }
    }

    /// A lock failure is a capacity write failure and must reach the heartbeat instead of
    /// looking like a successful pass.
    @Test func agentSurfacesAProfileLockFailureInTheHeartbeat() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            let history = try MetricsHistory(url: url)
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true, modules: [],
                                    capacityGeneration: "generation-1"),
                to: profileURL)
            let lockPath = profileURL.path + ".lock"
            try FileManager.default.removeItem(atPath: lockPath)
            try FileManager.default.createDirectory(atPath: lockPath, withIntermediateDirectories: true)

            let calls = Counter()
            var recorder = MonitorAgentRecorder(
                profileURL: profileURL, heartbeatURL: heartbeatURL, history: history,
                sampler: { _ in [:] },
                volumeCapacity: VolumeCapacityCollection(sample: {
                    calls.increment()
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                }))

            recorder.tick(now: hour0.addingTimeInterval(1))
            let failed = waitUntil {
                recorder.tick(now: hour0.addingTimeInterval(2))
                return MonitorAgentHeartbeatStore.load(from: heartbeatURL)?
                    .lastError?.contains("volume capacity history write failed") == true
            }
            #expect(failed)
            let store = VolumeCapacityHistory(history: history)
            #expect(try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).isEmpty)
            #expect(calls.value == 1)
        }
    }

    /// A capacity write waiting for SQLite's writer lock runs on the worker, not on the agent
    /// loop. Other metrics and the heartbeat keep moving while it waits.
    @Test func blockedCapacityWriteDoesNotStallTheAgentLoop() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "history.sqlite")
            let profileURL = dir.appending(path: "monitor-agent.json")
            let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
            let history = try MetricsHistory(url: url)
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true,
                                    modules: [ModulePlan(module: "cpu", interval: 1)],
                                    capacityGeneration: "generation-1"),
                to: profileURL)

            let blockerReady = DispatchSemaphore(value: 0)
            let releaseBlocker = DispatchSemaphore(value: 0)
            let blockerDone = DispatchSemaphore(value: 0)
            let blockerErrors = ErrorBox()
            holdWriterLock(url: url, ready: blockerReady, release: releaseBlocker,
                           done: blockerDone, errors: blockerErrors)
            defer { releaseBlocker.signal() }
            #expect(blockerReady.wait(timeout: .now() + 2) == .success)

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
                    return [VolumeCapacityReading(volume: "volume:AAAA/media:1111",
                                                  capacity: VolumeCapacity(free: 100, total: 1_000))]
                }))

            recorder.tick(now: hour0.addingTimeInterval(1))
            #expect(waitUntil { capacityCalls.value == 1 })
            let holdsSharedLock = waitUntil {
                do {
                    try MonitorAgentProfileStore.withExclusiveLock(at: profileURL, timeout: 0.01) { }
                    return false
                } catch MonitorAgentProfileStoreError.lockTimeout {
                    return true
                } catch {
                    return false
                }
            }
            #expect(holdsSharedLock, "the in-flight apply must hold the shared profile lock")

            // Release the writer lock after the loop tick has had time to run.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { releaseBlocker.signal() }
            let begin = Date()
            recorder.tick(now: hour0.addingTimeInterval(11))
            let elapsed = Date().timeIntervalSince(begin)
            #expect(elapsed < 0.2, "the agent loop must not wait for the capacity write")
            #expect(moduleCalls.value >= 2)
            let beat = MonitorAgentHeartbeatStore.load(from: heartbeatURL)
            #expect(beat?.lastHeartbeatAt == hour0.addingTimeInterval(11))
            #expect(beat?.lastSampleAt == hour0.addingTimeInterval(11))
            #expect(beat?.lastError == nil)

            #expect(blockerDone.wait(timeout: .now() + 2) == .success)
            #expect(blockerErrors.isEmpty)
            let store = VolumeCapacityHistory(history: history)
            let recorded = try waitUntil {
                recorder.tick(now: hour0.addingTimeInterval(12))
                return try store.points(volume: "volume:AAAA/media:1111", since: .distantPast).count == 1
            }
            #expect(recorded)
        }
    }

    /// A profile written by an earlier app has no generation. It must still decode and keep
    /// recording under the stable legacy session token.
    @Test func oldProfileWithoutAGenerationStillDecodes() throws {
        try withTempDirectory { dir in
            let profileURL = dir.appending(path: "monitor-agent.json")
            let json = #"{"backgroundRecordingEnabled":true,"modules":[]}"#
            try Data(json.utf8).write(to: profileURL)
            let profile = MonitorAgentProfileStore.load(from: profileURL)
            #expect(profile?.backgroundRecordingEnabled == true)
            #expect(profile?.capacityGeneration == nil)
            #expect(MonitorAgentProfileStore.capacitySession(from: profileURL) == "legacy")

            // A disabled profile has no capacity session, even when it names a generation.
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: false, modules: [],
                                    capacityGeneration: "generation-2"),
                to: profileURL)
            #expect(MonitorAgentProfileStore.capacitySession(from: profileURL) == nil)
        }
    }

    /// A failed profile write must not look like a completed disable: the old enabled profile
    /// stays on disk so the recorder keeps running under the previous generation.
    @Test func failedProfileSaveLeavesTheEnabledProfileInPlace() throws {
        try withTempDirectory { dir in
            let profileURL = dir.appending(path: "monitor-agent.json")
            let enabled = MonitorAgentProfile(backgroundRecordingEnabled: true, modules: [],
                                              capacityGeneration: "generation-1")
            try MonitorAgentProfileStore.save(enabled, to: profileURL)

            // A directory at the sidecar lock path makes opening the lock fail, like a
            // permission or file-system failure would. The successful save above created a
            // lock file there, so replace it first.
            let lockPath = profileURL.path + ".lock"
            try FileManager.default.removeItem(atPath: lockPath)
            try FileManager.default.createDirectory(atPath: lockPath, withIntermediateDirectories: true)

            #expect(throws: (any Error).self) {
                try MonitorAgentProfileStore.save(
                    MonitorAgentProfile(backgroundRecordingEnabled: false, modules: [],
                                        capacityGeneration: "generation-2"),
                    to: profileURL)
            }
            #expect(MonitorAgentProfileStore.load(from: profileURL) == enabled)
        }
    }

    /// A lock held by another process must make the save fail after a bounded wait, not hang
    /// the app. The profile stays exactly as it was, so a failed disable is never reported as
    /// a completed one.
    @Test func profileSaveTimesOutWhenAnInFlightWriteHoldsTheLock() throws {
        try withTempDirectory { dir in
            let profileURL = dir.appending(path: "monitor-agent.json")
            let enabled = MonitorAgentProfile(backgroundRecordingEnabled: true, modules: [],
                                              capacityGeneration: "generation-1")
            try MonitorAgentProfileStore.save(enabled, to: profileURL)

            let held = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let holderDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { holderDone.signal() }
                do {
                    try MonitorAgentProfileStore.withSharedLock(at: profileURL) {
                        held.signal()
                        release.wait()
                    }
                } catch {
                    // The timeout assertion below reports the failure; nothing else to record.
                }
            }
            #expect(held.wait(timeout: .now() + 2) == .success)
            defer { release.signal() }

            let disabled = MonitorAgentProfile(backgroundRecordingEnabled: false, modules: [],
                                               capacityGeneration: "generation-2")
            let begin = Date()
            do {
                try MonitorAgentProfileStore.save(disabled, to: profileURL, timeout: 0.05)
                Issue.record("the save must not succeed while the shared lock is held")
            } catch let error as MonitorAgentProfileStoreError {
                #expect(error == .lockTimeout(path: profileURL.path + ".lock"))
            } catch {
                Issue.record("unexpected save error: \(error)")
            }
            #expect(Date().timeIntervalSince(begin) < 1)
            #expect(MonitorAgentProfileStore.load(from: profileURL) == enabled)

            release.signal()
            #expect(holderDone.wait(timeout: .now() + 2) == .success)
        }
    }

    /// A throw inside the locked body must release the lock, or one failed write would block
    /// every later profile change.
    @Test func profileLockIsReleasedWhenTheBodyThrows() throws {
        try withTempDirectory { dir in
            let profileURL = dir.appending(path: "monitor-agent.json")
            try MonitorAgentProfileStore.save(
                MonitorAgentProfile(backgroundRecordingEnabled: true, modules: []), to: profileURL)

            do {
                try MonitorAgentProfileStore.withExclusiveLock(at: profileURL) {
                    throw LockProbeError()
                }
                Issue.record("the locked body must throw")
            } catch is LockProbeError {
            }
            do {
                try MonitorAgentProfileStore.withExclusiveLock(at: profileURL, timeout: 0.1) { }
            } catch {
                Issue.record("the lock was not released: \(error)")
            }
        }
    }
}
