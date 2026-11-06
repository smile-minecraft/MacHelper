import Foundation
import Testing
@testable import Diagnostics
import Storage

@Suite struct HealthReportTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func minutes(_ n: Int, cpu: Double, memory: Double = 0.5, temperature: Double = 60) -> [MetricSample] {
        (0..<n).map { MetricSample(time: now.addingTimeInterval(-Double($0) * 60), cpu: cpu, memory: memory, temperature: temperature) }
    }

    @Test func quietMacHasNoFindings() {
        let r = HealthCheck.evaluate(samples: minutes(60, cpu: 0.1), processes: nil, diskPoints: [], hours: 1,
                                     system: SystemSnapshot(swapUsedBytes: 0, uptimeSeconds: 3600, diskFreeBytes: 500e9, diskTotalBytes: 1e12),
                                     now: now)
        #expect(r.findings.isEmpty)
        #expect(r.overall == .ok)
        #expect(abs((r.cpu.average ?? 0) - 0.1) < 1e-9)
    }

    @Test func flagsLoadHeatSwapAndDisk() {
        let r = HealthCheck.evaluate(samples: minutes(60, cpu: 0.9, memory: 0.9, temperature: 98), processes: nil, diskPoints: [], hours: 1,
                                     system: SystemSnapshot(swapUsedBytes: 5e9, uptimeSeconds: 20 * 86_400, diskFreeBytes: 8e9, diskTotalBytes: 1e12),
                                     now: now)
        let ids = Set(r.findings.map(\.id))
        #expect(ids == ["cpu.busy", "memory.high", "memory.swap", "thermal.hot", "disk.low", "uptime"])
        #expect(r.overall == .critical)
        #expect(r.findings.first?.severity == .critical, "most severe first")
    }

    @Test func diskLevelsUseAbsoluteFreeSpace() {
        #expect(DiskSpaceLevels.level(freeBytes: 37.5e9) == .healthy)
        #expect(DiskSpaceLevels.level(freeBytes: 25e9) == .healthy)
        #expect(DiskSpaceLevels.level(freeBytes: 24.9e9) == .low)
        #expect(DiskSpaceLevels.level(freeBytes: 10e9) == .low)
        #expect(DiskSpaceLevels.level(freeBytes: 9.9e9) == .critical)
        // A big disk with a small share free is still fine when the amount is enough.
        let r = HealthCheck.evaluate(samples: minutes(60, cpu: 0.1), processes: nil, diskPoints: [], hours: 1,
                                     system: SystemSnapshot(diskFreeBytes: 100e9, diskTotalBytes: 4e12), now: now)
        #expect(!r.findings.contains { $0.id == "disk.low" })
        let low = HealthCheck.evaluate(samples: minutes(60, cpu: 0.1), processes: nil, diskPoints: [], hours: 1,
                                       system: SystemSnapshot(diskFreeBytes: 20e9, diskTotalBytes: 256e9), now: now)
        #expect(low.findings.first { $0.id == "disk.low" }?.severity == .warning)
    }

    @Test func sparseHistoryIsReported() {
        let r = HealthCheck.evaluate(samples: minutes(10, cpu: 0.1), processes: nil, diskPoints: [], hours: 24, system: SystemSnapshot(), now: now)
        #expect(r.findings.map(\.id) == ["coverage"])
    }

    @Test func busyProcessIsNamed() {
        let p = ProcessUsageHistory(byCPU: [ProcessUsageRank(name: "spinner", averageCPU: 0.8, averageMemoryBytes: 1e8, minuteCount: 50)],
                                    byMemory: [], totalMinuteCount: 60, hiddenCount: 0)
        let r = HealthCheck.evaluate(samples: minutes(60, cpu: 0.4), processes: p, diskPoints: [], hours: 1, system: SystemSnapshot(), now: now)
        #expect(r.findings.contains { $0.id == "cpu.process" && $0.title.contains("spinner") })
    }

    @Test func machelperItselfIsNeverTheBusyProcess() {
        let own = ProcessUsageRank(name: "MacHelper", averageCPU: 0.9, averageMemoryBytes: 1e8, minuteCount: 59)
        let other = ProcessUsageRank(name: "spinner", averageCPU: 0.7, averageMemoryBytes: 1e8, minuteCount: 40)
        let quiet = ProcessUsageRank(name: "quiet", averageCPU: 0.1, averageMemoryBytes: 1e8, minuteCount: 40)
        let onlyOwn = ProcessUsageHistory(byCPU: [own, quiet], byMemory: [], totalMinuteCount: 60, hiddenCount: 0)
        let r1 = HealthCheck.evaluate(samples: minutes(60, cpu: 0.4), processes: onlyOwn, diskPoints: [], hours: 1, system: SystemSnapshot(), now: now)
        #expect(!r1.findings.contains { $0.id == "cpu.process" }, "MacHelper's own use is not reported")
        #expect(!r1.topByCPU.contains { $0.name == "MacHelper" }, "nor listed among the busiest processes")
        let withOther = ProcessUsageHistory(byCPU: [own, other], byMemory: [], totalMinuteCount: 60, hiddenCount: 0)
        let r2 = HealthCheck.evaluate(samples: minutes(60, cpu: 0.4), processes: withOther, diskPoints: [], hours: 1, system: SystemSnapshot(), now: now)
        #expect(r2.findings.contains { $0.id == "cpu.process" && $0.title.contains("spinner") }, "the next real culprit is named")
    }
}

@Suite struct DiskSpaceTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func points(_ frees: [Double], total: Double = 1e12) -> [DiskSpacePoint] {
        frees.enumerated().map { DiskSpacePoint(time: start.addingTimeInterval(Double($0.offset) * 3600), free: $0.element, total: total) }
    }

    @Test func steadyDeclineForecastsFullDate() throws {
        // 1 GB per hour = 24 GB per day, from 100 GB.
        let f = try #require(DiskSpaceForecast.compute(points((0..<24).map { 100e9 - Double($0) * 1e9 })))
        #expect(abs(f.bytesPerDay + 24e9) < 1e6)
        #expect(abs((f.daysUntilFull ?? 0) - 77e9 / 24e9) < 0.01)
    }

    @Test func cleanupJumpRestartsTheTrend() throws {
        // Declining, then a 30 GB cleanup, then flat for 12 hours.
        let frees = (0..<12).map { 100e9 - Double($0) * 1e9 } + Array(repeating: 120e9, count: 13)
        let f = try #require(DiskSpaceForecast.compute(points(frees)))
        #expect(abs(f.bytesPerDay) < 1e6)
        #expect(f.daysUntilFull == nil)
    }

    @Test func tooLittleDataGivesNoForecast() {
        #expect(DiskSpaceForecast.compute(points([100e9, 99e9, 98e9])) == nil)
    }

    @Test func recordsOncePerHourAndClears() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "disk-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp.path + s) } }
        let h = try MetricsHistory(url: tmp)
        var calls = 0
        let measure: () -> (free: Double, total: Double)? = { calls += 1; return (10e9, 100e9) }
        try h.recordDiskSpaceIfNeeded(now: start, measure: measure)
        try h.recordDiskSpaceIfNeeded(now: start.addingTimeInterval(600), measure: measure)
        try h.recordDiskSpaceIfNeeded(now: start.addingTimeInterval(3600), measure: measure)
        #expect(calls == 2, "measured only when the hour had no point")
        #expect(try h.diskSpace(since: start.addingTimeInterval(-1)).count == 2)
        try HistoryStore(url: tmp).clear(.minuteSamples)
        #expect(try h.diskSpace(since: start.addingTimeInterval(-1)).isEmpty)
    }
}

@Suite struct SystemSnapshotPasswordTests {
    /// Reading background items locally runs sfltool, which asks for an administrator password.
    /// The default snapshot must never do that (the app gets the count from the Helper).
    @Test func defaultSnapshotDoesNotReadBackgroundItems() {
        let s = SystemSnapshot.current()
        #expect(s.activeBackgroundItems == nil)
        #expect(s.uptimeSeconds != nil)
    }
}
