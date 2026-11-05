import Foundation
import Testing
@testable import Storage

/// The background recorder samples processes on its own five-second cadence, not with the
/// module plan. The shared switch is read every cycle: while it is off the sampler must not
/// run at all, and the minute that closes while it is on is stored as process history.
@Suite struct ProcessCollectionRecorderTests {
    private let minute0 = Date(timeIntervalSince1970: 1_800_000_000)

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func record() {
            lock.lock()
            defer { lock.unlock() }
            value += 1
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test func recorderSamplesProcessesOnlyWhileCollectionIsOn() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "machelper-process-collection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appending(path: "history.sqlite")
        let history = try MetricsHistory(url: url)
        let store = try HistoryStore(url: url)
        let profileURL = dir.appending(path: "monitor-agent.json")
        let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
        try MonitorAgentProfileStore.save(
            MonitorAgentProfile(backgroundRecordingEnabled: true, modules: []), to: profileURL)

        let calls = CallCounter()
        let reading = ProcessUsageReading(pid: 42, name: "Safari", cpu: 0.5, memoryBytes: 300_000_000)
        let readings = ProcessUsageReadings(byCPU: [reading], byMemory: [reading], hiddenCount: 2)
        var recorder = MonitorAgentRecorder(
            profileURL: profileURL, heartbeatURL: heartbeatURL, history: history,
            sampler: { _ in [:] },
            processCollection: ProcessCollection(
                sample: {
                    calls.record()
                    return readings
                },
                isEnabled: { (try? store.isProcessCollectionEnabled()) ?? false }))

        // Off: the sampler and therefore the process names are never touched.
        recorder.tick(now: minute0)
        recorder.tick(now: minute0.addingTimeInterval(4))
        #expect(calls.count == 0)

        // On: one sample at the first five-second boundary, then one per boundary.
        try store.setProcessCollectionEnabled(true)
        recorder.tick(now: minute0.addingTimeInterval(5))
        #expect(calls.count == 1)
        recorder.tick(now: minute0.addingTimeInterval(6))
        #expect(calls.count == 1)
        recorder.tick(now: minute0.addingTimeInterval(10))
        #expect(calls.count == 2)

        // Crossing into the next minute stores the finished one.
        recorder.tick(now: minute0.addingTimeInterval(61))
        #expect(calls.count == 3)
        let usage = try history.processUsage(since: minute0, until: minute0.addingTimeInterval(120))
        #expect(usage.byCPU.map(\.name) == ["Safari"])
        #expect(usage.byCPU.first?.averageCPU == 0.5)
        #expect(usage.byCPU.first?.minuteCount == 1)
        #expect(usage.hiddenCount == 2)

        // Off again: no sampling on the following cycles either.
        try store.setProcessCollectionEnabled(false)
        recorder.tick(now: minute0.addingTimeInterval(66))
        recorder.tick(now: minute0.addingTimeInterval(71))
        #expect(calls.count == 3)
    }
}
