import Foundation
import Testing
@testable import Metrics

/// Live-system tests read this machine instead of supplied values. They are off by default and
/// never run in CI: `MACHELPER_LIVE_TESTS=1 swift test --filter ProcessSamplerTests`.
enum MetricsLiveTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MACHELPER_LIVE_TESTS"] == "1" }
}

/// A process table a test owns: which pids exist, what they have used, and whether their
/// executable can still be named. A pid can be removed between two samples to model a process
/// that ended mid-sample.
final class FakeProcessTable: ProcessDataSource, @unchecked Sendable {
    struct Entry {
        var cpuNanos: UInt64
        var footprint: UInt64
        var path: String?
        var name: String
        /// False models another user's process: its counters cannot be read without the Helper.
        var readable: Bool = true
    }

    private let lock = NSLock()
    private var entries: [Int32: Entry]
    private var clock: UInt64 = 1_000_000_000

    init(_ entries: [Int32: Entry]) {
        self.entries = entries
    }

    func pids() -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.sorted()
    }

    func counters(pid: Int32) -> (cpuNanos: UInt64, footprint: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[pid], entry.readable else { return nil }
        return (entry.cpuNanos, entry.footprint)
    }

    func executablePath(pid: Int32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[pid]?.path
    }

    func name(pid: Int32) -> String {
        lock.lock()
        defer { lock.unlock() }
        return entries[pid]?.name ?? ""
    }

    /// The clock advances with every sample, so a second sample on the same sampler has a delta.
    func uptime() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        clock += 1_000_000_000
        return clock
    }

    func remove(_ pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        entries[pid] = nil
    }

    func setCPUNanos(_ pid: Int32, to value: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        entries[pid]?.cpuNanos = value
    }

    /// Puts a pid back, the way the system may hand a pid to a new process later.
    func insert(_ pid: Int32, _ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        entries[pid] = entry
    }

    func loseName(_ pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        entries[pid]?.path = nil
        entries[pid]?.name = ""
    }
}

@Suite struct ProcessSamplerTests {
    /// A fixed process table: the sample's ordering, counts and names must be the table's, never
    /// whatever happens to run on this machine.
    @Test func repeatedSamplingKeepsCountsNamesAndOrder() {
        var entries: [Int32: FakeProcessTable.Entry] = [:]
        for pid in Int32(100)...Int32(124) {
            entries[pid] = FakeProcessTable.Entry(
                cpuNanos: UInt64(pid) * 1_000_000, footprint: UInt64(pid) * 1_024,
                path: "/Applications/App\(pid).app/Contents/MacOS/App\(pid)", name: "App\(pid)")
        }
        let table = FakeProcessTable(entries)
        let sampler = ProcessSampler(source: table)
        var first: ProcessSnapshot?
        var second: ProcessSnapshot?
        for i in 0..<30 {
            let snapshot = sampler.sample(top: 20)
            let cpus = snapshot.byCPU.map(\.cpu)
            #expect(cpus == cpus.sorted(by: >), "byCPU is busiest first")
            #expect(snapshot.byCPU.count <= 20 && snapshot.byMemory.count <= 20)
            #expect(snapshot.byCPU.allSatisfy { $0.cpu >= 0 && !$0.name.isEmpty })
            #expect(snapshot.byMemory.allSatisfy { !$0.name.isEmpty })
            if i == 0 { first = snapshot }
            if i == 1 { second = snapshot }
        }
        #expect(first != nil && second != nil)
        // The second sample on the same sampler sees deltas; counts must stay stable.
        #expect(first!.byCPU.count == second!.byCPU.count)
        #expect(first!.byMemory.count == second!.byMemory.count)
        // 25 processes, more than the 20 rows asked for: each list is the top 20 of all of them.
        #expect(first!.byCPU.count == 20 && first!.byMemory.count == 20)
        #expect(first!.byMemory.map(\.pid) == Array((Int32(105)...Int32(124)).reversed()))
    }

    /// A process that ends between its counters and its path lookup must be dropped, not shown as
    /// a blank row, and not counted as a process this user cannot inspect.
    @Test func aProcessThatEndsMidSampleIsDropped() {
        let table = FakeProcessTable([
            1: .init(cpuNanos: 5_000, footprint: 1_000, path: "/bin/one", name: "one"),
            2: .init(cpuNanos: 9_000, footprint: 2_000, path: "/bin/two", name: "two"),
        ])
        let sampler = ProcessSampler(source: table)
        #expect(Set(sampler.sample(top: 10).byCPU.map(\.pid)) == [1, 2])

        // A pid that stays in the list but cannot be named any more is dropped too.
        table.loseName(1)
        let snapshot = sampler.sample(top: 10)
        #expect(snapshot.byCPU.map(\.pid) == [2])
        #expect(snapshot.hiddenCount == 0, "a vanished pid is not a hidden one")
    }

    /// A pid that disappeared between two samples must not carry its baseline into the process the
    /// system hands that pid to next.
    @Test func aPidThatComesBackDoesNotReuseItsOldBaseline() {
        let table = FakeProcessTable([
            7: .init(cpuNanos: 1_000_000_000, footprint: 500, path: "/bin/seven", name: "seven"),
        ])
        let sampler = ProcessSampler(source: table)
        #expect(sampler.sample(top: 10).byCPU.first?.cpu == 0)
        table.setCPUNanos(7, to: 3_000_000_000)
        #expect(sampler.sample(top: 10).byCPU.first?.cpu == 2, "two seconds of CPU over one second")

        table.remove(7)
        #expect(sampler.sample(top: 10).byCPU.isEmpty)
        // The same pid belongs to a fresh process that has only just started.
        table.insert(7, .init(cpuNanos: 10_000, footprint: 500, path: "/bin/seven", name: "seven"))
        #expect(sampler.sample(top: 10).byCPU.first?.cpu == 0, "a new process with this pid has no baseline")
    }

    @Test func privilegedCountersFillInAnUnreadableProcess() {
        // launchd: another user's process, so its counters need the Helper. Its executable path is
        // readable without root, which is where its name comes from.
        let table = FakeProcessTable([
            1: .init(cpuNanos: 0, footprint: 0, path: "/sbin/launchd", name: "", readable: false),
        ])
        let sampler = ProcessSampler(source: table)
        #expect(sampler.sample(top: 10).hiddenCount == 1)
        #expect(sampler.sample(top: 10).byCPU.isEmpty)

        let merged = ProcessSampler(source: table)
            .sample(top: 10, privileged: [1: (cpuNanos: 5_000, footprint: 123_456)])
        #expect(merged.byCPU.contains { $0.pid == 1 && $0.memoryBytes == 123_456 })
        #expect(merged.byCPU.first?.name == "launchd")
        #expect(merged.hiddenCount == 0)
    }

    @Test func aProcessWithNoReadableNameResolvesToNothing() {
        #expect(ProcessSampler.name(Int32.max).isEmpty)
        #expect(ProcessSampler.path(Int32.max) == nil)
    }

    /// The kernel source really answers for this machine. Live only: needs the real process table.
    @Test(.enabled(if: MetricsLiveTests.enabled))
    func liveRepeatedSamplingKeepsCountsNamesAndOrder() {
        let sampler = ProcessSampler()
        var first: ProcessSnapshot?
        var second: ProcessSnapshot?
        for i in 0..<30 {
            let snapshot = sampler.sample(top: 20)
            let cpus = snapshot.byCPU.map(\.cpu)
            #expect(cpus == cpus.sorted(by: >), "byCPU is busiest first")
            #expect(snapshot.byCPU.count <= 20 && snapshot.byMemory.count <= 20)
            #expect(snapshot.byCPU.allSatisfy { $0.cpu >= 0 && !$0.name.isEmpty })
            #expect(snapshot.byMemory.allSatisfy { !$0.name.isEmpty })
            if i == 0 { first = snapshot }
            if i == 1 { second = snapshot }
        }
        #expect(first != nil && second != nil)
        #expect(first!.byCPU.count == second!.byCPU.count)
        #expect(first!.byMemory.count == second!.byMemory.count)
    }
}
