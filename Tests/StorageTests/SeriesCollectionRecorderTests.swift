import Foundation
import Testing
@testable import Storage

/// The background recorder collects series beside the overview columns. The shared switch
/// is read on the module cadence: while it is off the series sampler must not run, and
/// turning it off drops the open minute so values from before and after are never merged.
@Suite struct SeriesCollectionRecorderTests {
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

    @Test func recorderCollectsSeriesOnlyWhileTheSwitchIsOnAndResetsWhenTurnedOff() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "machelper-series-collection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appending(path: "history.sqlite")
        let history = try MetricsHistory(url: url)
        let store = try HistoryStore(url: url)
        let profileURL = dir.appending(path: "monitor-agent.json")
        let heartbeatURL = dir.appending(path: "monitor-agent-status.json")
        try MonitorAgentProfileStore.save(
            MonitorAgentProfile(backgroundRecordingEnabled: true,
                                modules: [ModulePlan(module: "cpu", interval: 1)]),
            to: profileURL)

        let calls = CallCounter()
        let performance = HistorySeries.cpuPerformance
        let efficiency = HistorySeries.cpuEfficiency
        var recorder = MonitorAgentRecorder(
            profileURL: profileURL, heartbeatURL: heartbeatURL, history: history,
            sampler: { module in module == "cpu" ? ["cpu": 0.5] : [:] },
            seriesCollection: SeriesCollection(
                sample: { module in
                    guard module == "cpu" else { return [:] }
                    calls.record()
                    let n = Double(calls.count)
                    return [performance: n * 0.1, efficiency: n * 0.05]
                },
                isEnabled: { (try? store.isSeriesCollectionEnabled()) ?? false }))

        // Off (the default): the sampler is never called and nothing is accumulated.
        recorder.tick(now: minute0)
        #expect(calls.count == 0)

        // On: the module cadence drives the samples; two in one minute average to one row.
        try store.setSeriesCollectionEnabled(true)
        recorder.tick(now: minute0.addingTimeInterval(5))
        recorder.tick(now: minute0.addingTimeInterval(10))
        #expect(calls.count == 2)
        #expect(try history.seriesSamples(performance, since: minute0,
                                          until: minute0.addingTimeInterval(60)).isEmpty)

        // Crossing the minute boundary writes the finished minute.
        recorder.tick(now: minute0.addingTimeInterval(61))
        #expect(calls.count == 3)
        let firstMinute = try history.seriesSamples(performance, since: minute0,
                                                    until: minute0.addingTimeInterval(60))
        #expect(abs((firstMinute.first?.value ?? 0) - 0.15) < 1e-9)   // (0.1 + 0.2) / 2
        let firstEfficiency = try history.seriesSamples(efficiency, since: minute0,
                                                        until: minute0.addingTimeInterval(60))
        #expect(abs((firstEfficiency.first?.value ?? 0) - 0.075) < 1e-9)

        // Off again: no sampling. The value sampled at t+61 belongs to the open minute and
        // must be dropped with the accumulator, not carried across the off period.
        try store.setSeriesCollectionEnabled(false)
        recorder.tick(now: minute0.addingTimeInterval(66))
        recorder.tick(now: minute0.addingTimeInterval(71))
        #expect(calls.count == 3)
        #expect(try history.seriesSamples(performance, since: minute0.addingTimeInterval(60),
                                          until: minute0.addingTimeInterval(120)).isEmpty)

        // On again: only the new sample counts, so the reopened minute is 0.4, not 0.35.
        try store.setSeriesCollectionEnabled(true)
        recorder.tick(now: minute0.addingTimeInterval(76))
        #expect(calls.count == 4)
        recorder.tick(now: minute0.addingTimeInterval(121))
        #expect(calls.count == 5)
        let secondMinute = try history.seriesSamples(performance, since: minute0.addingTimeInterval(60),
                                                     until: minute0.addingTimeInterval(120))
        #expect(abs((secondMinute.first?.value ?? 0) - 0.4) < 1e-9)
    }
}
