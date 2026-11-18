import Foundation
import Testing
@testable import Metrics

@Suite struct ProcessDiskIOSnapshotTests {
    private func reading(_ name: String, start: UInt64, read: UInt64, write: UInt64) -> ProcessDiskReading {
        ProcessDiskReading(name: name, startAbstime: start, readBytes: read, writeBytes: write)
    }

    private let paths: [Int32: String] = [
        1: "/Applications/Safari.app/Contents/MacOS/Safari",
        2: "/Applications/Safari.app/Contents/XPCServices/Net.xpc/Contents/MacOS/Net",
        3: "/usr/sbin/mDNSResponder",
    ]

    @Test func firstSnapshotHasNoRates() {
        let current: [Int32: ProcessDiskReading] = [
            1: reading("Safari", start: 100, read: 100, write: 10),
            3: reading("mDNSResponder", start: 100, read: 5_000, write: 0),
        ]
        let s = ProcessDiskIOSampler.snapshot(current: current, previous: nil, now: Date(),
                                              hiddenCount: 4, resolvePath: { paths[$0] })
        #expect(!s.hasRates)
        #expect(s.items.allSatisfy { $0.readBytesPerSecond == nil })
        #expect(s.items.allSatisfy { $0.writeBytesPerSecond == nil })
        #expect(s.items.first?.name == "mDNSResponder", "without rates, order is by total bytes")
        #expect(s.hiddenCount == 4)
    }

    @Test func groupsAppProcessesAndComputesRates() throws {
        let t0 = Date(timeIntervalSince1970: 1000)
        let prev: [Int32: ProcessDiskReading] = [
            1: reading("Safari", start: 100, read: 100, write: 10),
            2: reading("Net", start: 100, read: 1_000, write: 0),
            3: reading("mDNSResponder", start: 100, read: 50, write: 50),
        ]
        let cur: [Int32: ProcessDiskReading] = [
            1: reading("Safari", start: 100, read: 600, write: 10),
            2: reading("Net", start: 100, read: 3_000, write: 500),
            3: reading("mDNSResponder", start: 100, read: 40, write: 60),
        ]
        let s = ProcessDiskIOSampler.snapshot(current: cur, previous: (prev, t0),
                                              now: t0.addingTimeInterval(5), hiddenCount: 0,
                                              resolvePath: { paths[$0] })
        #expect(s.hasRates)
        let safari = try #require(s.items.first)
        #expect(safari.appPath == "/Applications/Safari.app")
        #expect(safari.processCount == 2)
        #expect(safari.readBytesPerSecond == 500.0)
        #expect(safari.writeBytesPerSecond == 100)
        // Counters that went backwards count as zero, not a spike.
        let mdns = try #require(s.items.first { $0.name == "mDNSResponder" })
        #expect(mdns.readBytesPerSecond == 0)
        #expect(mdns.writeBytesPerSecond == 2)
    }

    @Test func reusedPidWithDifferentStartCountsAsZero() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let prev: [Int32: ProcessDiskReading] = [9: reading("old", start: 1, read: 0, write: 0)]
        let cur: [Int32: ProcessDiskReading] = [9: reading("new", start: 2, read: 9_000, write: 0)]
        let s = ProcessDiskIOSampler.snapshot(current: cur, previous: (prev, t0),
                                              now: t0.addingTimeInterval(1), hiddenCount: 0,
                                              resolvePath: { _ in nil })
        #expect(s.items.first?.readBytesPerSecond == 0)
        #expect(s.items.first?.writeBytesPerSecond == 0)
    }

    @Test func exitedProcessesDisappearFromTheSnapshot() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let prev: [Int32: ProcessDiskReading] = [
            1: reading("gone", start: 100, read: 100, write: 0),
            3: reading("stayed", start: 100, read: 100, write: 0),
        ]
        let cur: [Int32: ProcessDiskReading] = [3: reading("stayed", start: 100, read: 200, write: 0)]
        let s = ProcessDiskIOSampler.snapshot(current: cur, previous: (prev, t0),
                                              now: t0.addingTimeInterval(1), hiddenCount: 0,
                                              resolvePath: { paths[$0] })
        #expect(s.items.map(\.name) == ["mDNSResponder"])
    }

    @Test func processesWithNoCountedIOAreExcluded() {
        let current: [Int32: ProcessDiskReading] = [
            1: reading("idle", start: 100, read: 0, write: 0),
            3: reading("working", start: 100, read: 8, write: 0),
        ]
        let s = ProcessDiskIOSampler.snapshot(current: current, previous: nil, now: Date(),
                                              hiddenCount: 0, resolvePath: { paths[$0] })
        #expect(s.items.map(\.name) == ["mDNSResponder"])
    }
}

@Suite struct ProcessDiskIOSamplerTests {
    @Test func emptyPidListYieldsNoSnapshot() {
        let sampler = ProcessDiskIOSampler(listPIDs: { [] },
                                           read: { _ in nil },
                                           resolvePath: { _ in nil },
                                           now: { Date() })
        #expect(sampler.sample() == nil)
    }

    @Test func unreadableProcessesAreCountedAsHiddenNotZero() {
        let sampler = ProcessDiskIOSampler(listPIDs: { [1, 2, 3] },
                                           read: { pid in
                                               pid == 2 ? (read: 0, write: 0, start: 1, name: "ok") : nil
                                           },
                                           resolvePath: { _ in nil },
                                           now: { Date() })
        let s = sampler.sample()
        #expect(s?.hiddenCount == 2)
        // pid 2 read nothing, so it is excluded from the items entirely rather than shown as zero.
        #expect(s?.items.isEmpty == true)
    }
}
