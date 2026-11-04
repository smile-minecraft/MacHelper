import Foundation
import Testing
@testable import Storage

@Suite struct StorageTests {
    @Test func accumulatorAveragesPerMinute() {
        var acc = MinuteAccumulator()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // a whole minute
        #expect(acc.add("cpu", 0.2, at: t0) == nil)
        #expect(acc.add("cpu", 0.4, at: t0.addingTimeInterval(30)) == nil)
        #expect(acc.add("memory", 0.5, at: t0.addingTimeInterval(59)) == nil)
        let done = acc.add("cpu", 0.9, at: t0.addingTimeInterval(61))
        #expect(done?.time == t0)
        #expect(abs((done?.cpu ?? 0) - 0.3) < 1e-9)
        #expect(done?.memory == 0.5)
        #expect(done?.gpu == nil)
    }

    @Test func bucketsAndRetention() throws {
        let h = try MetricsHistory(inMemory: (), retention: 3600)
        let now = Date()
        let base = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 600).rounded(.down) * 600 - 1800)
        for i in 0..<10 {
            try h.append(MetricSample(time: base.addingTimeInterval(Double(i) * 60), cpu: Double(i)))
        }
        try h.append(MetricSample(time: now.addingTimeInterval(-7200), cpu: 99))   // pruned right away
        #expect(try h.count() == 10)
        let buckets = try h.samples(since: base, bucket: 300)
        #expect(buckets.count == 2)
        #expect(buckets[0].cpu == 2)    // avg of 0...4
        #expect(buckets[1].cpu == 7)    // avg of 5...9
    }
}
