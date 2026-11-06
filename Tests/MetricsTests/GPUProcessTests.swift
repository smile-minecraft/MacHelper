import Foundation
import Testing
@testable import Metrics

@Suite struct GPUProcessTests {
    @Test func parsesCreator() {
        #expect(GPUProcessSampler.parseCreator("pid 176, WindowServer")! == (176, "WindowServer"))
        #expect(GPUProcessSampler.parseCreator("pid 620, com.apple.dock.e")! == (620, "com.apple.dock.e"))
        #expect(GPUProcessSampler.parseCreator("pid 9")! == (9, ""))
        #expect(GPUProcessSampler.parseCreator("kernel") == nil)
        #expect(GPUProcessSampler.parseCreator("pid 0, kernel_task") == nil)
        #expect(GPUProcessSampler.parseCreator("pid x, y") == nil)
    }

    @Test func sumsAppUsageEntries() {
        let usage: [[String: Any]] = [["API": "Metal", "accumulatedGPUTime": NSNumber(value: 1_000)],
                                      ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 234)],
                                      ["API": "Metal"]]
        #expect(GPUProcessSampler.accumulatedTime(usage) == 1_234)
        #expect(GPUProcessSampler.accumulatedTime(nil) == 0)
        #expect(GPUProcessSampler.accumulatedTime("garbage") == 0)
    }

    @Test func usageIsDeltaOverElapsedBusiestFirst() {
        let previous: [Int32: UInt64] = [1: 1_000, 2: 5_000, 3: 7_000, 5: 9_000]
        let current: [Int32: UInt64] = [1: 501_000, 2: 5_000, 3: 107_000, 4: 999_999, 5: 1_000]
        let u = GPUProcessSampler.usage(previous: previous, current: current, elapsedNanos: 1_000_000)
        #expect(u.map(\.pid) == [1, 3], "idle (2), new (4) and reused-pid (5) processes are left out")
        #expect(abs(u[0].share - 0.5) < 1e-9)
        #expect(abs(u[1].share - 0.1) < 1e-9)
    }

    @Test func usageIsCappedAndNeedsTime() {
        let u = GPUProcessSampler.usage(previous: [1: 0], current: [1: 3_000], elapsedNanos: 1_000)
        #expect(u.first?.share == 1)
        #expect(GPUProcessSampler.usage(previous: [1: 0], current: [1: 5], elapsedNanos: 0).isEmpty)
    }

    @Test func firstSampleIsEmptyThenReadsThisMac() throws {
        let sampler = GPUProcessSampler()
        #expect(sampler.sample().isEmpty, "needs a baseline")
        let after = sampler.sample(top: 5)
        #expect(after.count <= 5)
        #expect(after.allSatisfy { $0.gpu > 0 && $0.gpu <= 1 && $0.pid > 0 && !$0.name.isEmpty })
        // Read-only sanity on Apple silicon: the registry has GPU clients with creators.
        let (times, names) = GPUProcessSampler.readRegistry()
        if !times.isEmpty { #expect(!names.isEmpty) }
    }
}

@Suite struct PrivilegedProcessMergeTests {
    @Test func helperCountersFillInUnreadableProcesses() {
        // launchd (pid 1) belongs to root: a normal user can't read it.
        let plain = ProcessSampler().sample(top: 10_000)
        guard !plain.byCPU.contains(where: { $0.pid == 1 }) else { return }  // running as root
        let merged = ProcessSampler().sample(top: 10_000, privileged: [1: (cpuNanos: 5_000, footprint: 123_456)])
        #expect(merged.byMemory.contains { $0.pid == 1 && $0.memoryBytes == 123_456 })
        #expect(merged.hiddenCount == plain.hiddenCount - 1 || merged.hiddenCount < plain.hiddenCount)
    }
}
