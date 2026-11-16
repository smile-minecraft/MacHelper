import Foundation
import Testing
@testable import Metrics

@Suite struct NettopParserTests {
    @Test func parsesRowsAndSkipsHeader() {
        let text = """
        ,bytes_in,bytes_out,
        kernel_task.0,58251844,11085984,
        Spotify Helper.48160,7231956,557,
        com.apple.WebKit.Networking.912,10,20,
        broken,1,2,
        noBytes.12,,,
        """
        let rows = NettopParser.parse(text)
        #expect(rows.count == 3)
        #expect(rows[1] == NettopRow(name: "Spotify Helper", pid: 48160, inBytes: 7_231_956, outBytes: 557))
        #expect(rows[2].name == "com.apple.WebKit.Networking")
        #expect(rows[2].pid == 912)
    }
}

@Suite struct ProcessNetworkSnapshotTests {
    private func row(_ name: String, _ pid: Int32, _ i: UInt64, _ o: UInt64) -> (Int32, NettopRow) {
        (pid, NettopRow(name: name, pid: pid, inBytes: i, outBytes: o))
    }

    private let paths: [Int32: String] = [
        1: "/Applications/Safari.app/Contents/MacOS/Safari",
        2: "/Applications/Safari.app/Contents/XPCServices/Net.xpc/Contents/MacOS/Net",
        3: "/usr/sbin/mDNSResponder",
    ]

    @Test func firstSnapshotHasNoRates() {
        let current = Dictionary(uniqueKeysWithValues: [row("Safari", 1, 100, 10), row("mDNSResponder", 3, 5_000, 0)])
        let s = ProcessNetworkSampler.snapshot(current: current, previous: nil, now: Date(), resolvePath: { paths[$0] })
        #expect(!s.hasRates)
        #expect(s.items.allSatisfy { $0.inBytesPerSecond == nil })
        // Without rates the busiest by total bytes comes first.
        #expect(s.items.first?.name == "mDNSResponder")
    }

    @Test func groupsAppProcessesAndComputesRates() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let prev = Dictionary(uniqueKeysWithValues: [row("Safari", 1, 100, 10), row("Net", 2, 1_000, 0), row("mDNSResponder", 3, 50, 50)])
        let cur = Dictionary(uniqueKeysWithValues: [row("Safari", 1, 600, 10), row("Net", 2, 3_000, 500), row("mDNSResponder", 3, 40, 60)])
        let s = ProcessNetworkSampler.snapshot(current: cur, previous: (prev, t0), now: t0.addingTimeInterval(5),
                                               resolvePath: { paths[$0] })
        #expect(s.hasRates)
        let safari = try! #require(s.items.first)
        #expect(safari.appPath == "/Applications/Safari.app")
        #expect(safari.processCount == 2)
        #expect(safari.inBytesPerSecond == 500.0)
        #expect(safari.outBytesPerSecond == 100)
        // Counters that went backwards count as zero, not a spike.
        let mdns = try! #require(s.items.first { $0.name == "mDNSResponder" })
        #expect(mdns.inBytesPerSecond == 0)
        #expect(mdns.outBytesPerSecond == 2)
    }

    @Test func reusedPidWithNewNameStartsAtZero() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let prev = Dictionary(uniqueKeysWithValues: [row("old", 9, 0, 0)])
        let cur = Dictionary(uniqueKeysWithValues: [row("new", 9, 9_000, 0)])
        let s = ProcessNetworkSampler.snapshot(current: cur, previous: (prev, t0), now: t0.addingTimeInterval(1), resolvePath: { _ in nil })
        #expect(s.items.first?.inBytesPerSecond == 0)
    }
}

@Suite struct PowerBreakdownTests {
    private func reading(cpu: Double?, gpu: Double?, system: Double?) -> PowerReading {
        PowerReading(cpuWatts: cpu, gpuWatts: gpu, aneWatts: nil, dramWatts: nil, systemWatts: system,
                     hasSystemRail: system != nil, channels: [:])
    }

    @Test func restIsSystemMinusMeasuredParts() throws {
        let b = try #require(PowerBreakdown(reading(cpu: 8, gpu: 1, system: 20)))
        #expect(b.total == 20)
        #expect(b.chip == 9)
        #expect(b.rest == 11)
        #expect(b.components.map(\.part) == [.cpu, .gpu])
    }

    @Test func chipAboveSystemClampsRest() throws {
        let b = try #require(PowerBreakdown(reading(cpu: 15, gpu: 6, system: 20)))
        #expect(b.total == 21)
        #expect(b.rest == 0)
    }

    @Test func withoutSystemRailTotalIsParts() throws {
        let b = try #require(PowerBreakdown(reading(cpu: 3, gpu: 2, system: nil)))
        #expect(b.total == 5)
        #expect(b.rest == nil)
        #expect(PowerBreakdown(reading(cpu: nil, gpu: nil, system: nil)) == nil)
    }
}
