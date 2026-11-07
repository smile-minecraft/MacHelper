import Foundation
import Testing
@testable import Diagnostics

@Suite struct HealthScoreTests {
    func report(_ findings: [HealthReport.Finding], free: Double? = 100e9) -> HealthReport {
        HealthReport(generatedAt: Date(), windowHours: 24, coverage: 1, cpu: .init(average: nil, maximum: nil),
                     memory: .init(average: nil, maximum: nil), temperature: .init(average: nil, maximum: nil),
                     power: .init(average: nil, maximum: nil), topByCPU: [], topByMemory: [],
                     system: SystemSnapshot(diskFreeBytes: free, diskTotalBytes: 1e12), diskForecast: nil, findings: findings)
    }
    func finding(_ id: String, _ s: HealthReport.Severity) -> HealthReport.Finding { .init(id: id, severity: s, title: id, detail: "") }

    @Test func healthyMacScoresFull() {
        let s = HealthScore.compute(report: report([]), freeBytes: 200e9, memory: .normal)
        #expect(s.value == 100)
        #expect(s.deductions.isEmpty)
        #expect(s.level == .good)
    }

    @Test func eachProblemIsDeductedAndListed() {
        let r = report([finding("memory.swap", .info), finding("background.many", .info), finding("cpu.busy", .warning)])
        let s = HealthScore.compute(report: r, freeBytes: 20e9, memory: .warning)
        // disk low 10 + memory 10 + warning 8 + 2 info × 2
        #expect(s.value == 100 - 10 - 10 - 8 - 2 - 2)
        #expect(s.deductions.first?.points == 10)
        #expect(s.level == .attention)
    }

    @Test func liveDiskWinsOverTheReportAndCoverageIsIgnored() {
        let r = report([finding("disk.low", .critical), finding("coverage", .info)], free: 5e9)
        #expect(HealthScore.compute(report: r, freeBytes: 80e9, memory: nil).value == 100)
        #expect(HealthScore.compute(report: r, freeBytes: nil, memory: nil).value == 70, "falls back to the report's snapshot")
    }

    @Test func scoreNeverGoesBelowZero() {
        let r = report((0..<10).map { finding("f\($0)", .critical) })
        let s = HealthScore.compute(report: r, freeBytes: 1e9, memory: .critical)
        #expect(s.value == 0)
        #expect(s.level == .critical)
    }
}
