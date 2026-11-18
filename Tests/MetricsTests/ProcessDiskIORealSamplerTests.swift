import Darwin
import Foundation
import Testing
@testable import Metrics

/// The production sampler reading this test process's own counters.
///
/// The write is bounded to 1 MiB in the temporary directory and is deleted before the test ends.
/// Nothing else is written to disk, and no other process is inspected for its content.
@Suite struct ProcessDiskIORealSamplerTests {
    private let writeSize = 1_048_576

    // Opt-in: reads this machine's real kernel counters and depends on the local disk and the load
    // at the time, so default runs skip it. Run with MACHELPER_LIVE_DISK_SAMPLE=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACHELPER_LIVE_DISK_SAMPLE"] == "1"))
    func realSamplerAttributesABoundedWriteToThisProcess() async throws {
        let pid = getpid()
        let sampler = ProcessDiskIOSampler()
        // The first sample only establishes the baseline; rates need two samples of one process.
        let before = try #require(sampler.sample())
        try await Task.sleep(for: .milliseconds(250))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("machelper-diskio-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes = Data(count: writeSize)
        bytes.withUnsafeMutableBytes { raw in
            // Incompressible bytes, so the write cannot shrink below the counter's own accounting.
            arc4random_buf(raw.baseAddress, raw.count)
        }
        try bytes.write(to: url)

        try await Task.sleep(for: .milliseconds(250))
        let after = try #require(sampler.sample())
        let interval = after.capturedAt.timeIntervalSince(before.capturedAt)
        #expect(interval > 0)

        let ownPath = try #require(ProcessSampler.path(pid))
        let ownAppPath = ProcessGrouping.outermostApp(ownPath)
        let ownID = ownAppPath ?? "\(ProcessSampler.name(pid)).\(pid)"
        let item = try #require(after.items.first { $0.id == ownID },
                                "the test process must appear in the real snapshot")
        let writeRate = try #require(item.writeBytesPerSecond)
        #expect(after.hasRates)
        // The runner lives under Xcode here, so the production grouping puts it in that app group;
        // the count is whatever the kernel shows for the group, not a synthetic 1.
        #expect(item.processCount >= 1)
        #expect(item.appPath == ownAppPath)
        #expect(item.totalWriteBytes >= UInt64(writeSize))
        #expect(writeRate > 0)
        // The counter delta over the interval must contain the whole write; allow a per-billion
        // rounding margin instead of comparing doubles for exact equality at the boundary.
        #expect(writeRate * interval >= Double(writeSize) * (1 - 1e-9),
                "counter delta \(writeRate * interval) is smaller than the \(writeSize) byte write")

        let rank = try #require(after.items.firstIndex { $0.id == item.id }) + 1
        let above = after.items.prefix(rank - 1)
        #expect(above.allSatisfy { ($0.totalBytesPerSecond ?? 0) >= (item.totalBytesPerSecond ?? 0) },
                "every row above the test process must have at least its rate")
        let top = after.items.prefix(5).map { "\($0.name)=\($0.totalBytesPerSecond ?? 0)B/s" }
        print("real sampler: pid=\(pid) processCount=\(item.processCount) "
              + "writeRate=\(writeRate)B/s interval=\(interval)s delta=\(writeRate * interval)B "
              + "rank=\(rank)/\(after.items.count) top=\(top.joined(separator: ", "))")
    }
}

/// Ranking from controlled counters, so the rate/total/identifier tie-break order is exact and
/// independent of what the machine happens to be doing. The real-write test above checks the
/// counters and the observed rank; this one pins the ordering the page relies on.
@Suite struct ProcessDiskIORankingTests {
    @Test func ratesDecideRankAndTiesFallBackToTotalThenIdentifier() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        func reading(_ read: UInt64) -> ProcessDiskReading {
            ProcessDiskReading(name: "p", startAbstime: 1, readBytes: read, writeBytes: 0)
        }
        let previous: [Int32: ProcessDiskReading] = [
            1: reading(397_000),     // Fast:    +3,000 in 1 s, total 400,000
            2: reading(1_000_000),   // Heavy:   +2,000 in 1 s, total 1,002,000
            3: reading(900_000),     // Slow:    +1,000 in 1 s, total 901,000
            4: reading(100),         // Light:   +2,000 in 1 s, total 2,100
            5: reading(10_000),      // Alpha:   +2,000 in 1 s, total 12,000
            6: reading(10_000),      // Beta:    +2,000 in 1 s, total 12,000
        ]
        let current: [Int32: ProcessDiskReading] = [
            1: reading(400_000),
            2: reading(1_002_000),
            3: reading(901_000),
            4: reading(2_100),
            5: reading(12_000),
            6: reading(12_000),
        ]
        let paths: [Int32: String] = [
            1: "/Applications/Fast.app/Contents/MacOS/Fast",
            2: "/Applications/Heavy.app/Contents/MacOS/Heavy",
            3: "/Applications/Slow.app/Contents/MacOS/Slow",
            4: "/Applications/Light.app/Contents/MacOS/Light",
            5: "/Applications/Alpha.app/Contents/MacOS/Alpha",
            6: "/Applications/Beta.app/Contents/MacOS/Beta",
        ]
        let snapshot = ProcessDiskIOSampler.snapshot(current: current, previous: (previous, t0),
                                                     now: t0.addingTimeInterval(1), hiddenCount: 0,
                                                     resolvePath: { paths[$0] })
        #expect(snapshot.items.map(\.id) == [
            "/Applications/Fast.app",
            "/Applications/Heavy.app",
            "/Applications/Alpha.app",
            "/Applications/Beta.app",
            "/Applications/Light.app",
            "/Applications/Slow.app",
        ])
        #expect(snapshot.items.map { $0.totalBytesPerSecond ?? 0 } == [3_000, 2_000, 2_000, 2_000, 2_000, 1_000])
    }
}
