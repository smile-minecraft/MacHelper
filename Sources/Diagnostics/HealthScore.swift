import Foundation

/// One number for how the Mac is doing: 100 minus a deduction for each problem, with every
/// deduction listed so the number can always be explained. It covers the state right now (free
/// space, memory pressure) and the last health check (CPU load, heat, swap, trends). Security
/// settings are deliberately left out: they are shown on their own, so a Mac with FileVault off
/// on purpose doesn't look unhealthy forever.
public struct HealthScore: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable {
        case good, attention, critical
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Memory: Sendable { case normal, warning, critical }

    public struct Deduction: Sendable, Equatable, Identifiable {
        public let id: String
        public let points: Int
        public let title: String
    }

    public let value: Int
    public let deductions: [Deduction]

    /// 85 or more is good, 60 or more needs a look, below that something is wrong.
    public var level: Level { value >= 85 ? .good : value >= 60 ? .attention : .critical }

    // Points per problem. A critical finding alone drops the score out of "good".
    static let points: [HealthReport.Severity: Int] = [.critical: 20, .warning: 8, .info: 2]
    static let diskLow = 10, diskCritical = 30, memoryWarning = 10, memoryCritical = 25

    /// `report` is the latest health check (nil before the first one has run); `freeBytes` and
    /// `memory` are live readings, which win over the report's snapshot of the same thing.
    public static func compute(report: HealthReport?, freeBytes: Double?, memory: Memory?) -> HealthScore {
        var out: [Deduction] = []
        let free = freeBytes ?? report?.system.diskFreeBytes
        if let free {
            switch DiskSpaceLevels.level(freeBytes: free) {
            case .critical: out.append(.init(id: "disk.low", points: diskCritical, title: String(localized: "Startup disk almost full", bundle: .module)))
            case .low: out.append(.init(id: "disk.low", points: diskLow, title: String(localized: "Startup disk getting full", bundle: .module)))
            case .healthy: break
            }
        }
        switch memory {
        case .critical: out.append(.init(id: "memory.now", points: memoryCritical, title: String(localized: "Memory is running out right now", bundle: .module)))
        case .warning: out.append(.init(id: "memory.now", points: memoryWarning, title: String(localized: "Memory is tight right now", bundle: .module)))
        case .normal, nil: break
        }
        // Free space is already scored from the live reading; "limited history" says nothing about the Mac.
        for f in report?.findings ?? [] where f.id != "disk.low" && f.id != "coverage" {
            if let p = points[f.severity] { out.append(.init(id: f.id, points: p, title: f.title)) }
        }
        out.sort { $0.points > $1.points }
        return HealthScore(value: max(0, 100 - out.reduce(0) { $0 + $1.points }), deductions: out)
    }
}
