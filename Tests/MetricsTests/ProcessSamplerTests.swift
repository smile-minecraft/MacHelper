import Foundation
import Testing
@testable import Metrics

@Suite struct ProcessSamplerTests {
    @Test func repeatedSamplingKeepsCountsNamesAndOrder() {
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
        // The second sample on the same sampler sees deltas; counts must stay stable.
        #expect(first!.byCPU.count == second!.byCPU.count)
        #expect(first!.byMemory.count == second!.byMemory.count)
    }
}
