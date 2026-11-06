import CleanEngine
import Darwin
import Foundation
import Storage

/// A one-off health check built from the stored monitoring history plus a few live readings.
/// Read-only: it never changes settings or removes anything.
public struct HealthReport: Codable, Sendable {
    public enum Severity: String, Codable, Sendable, Comparable {
        case ok, info, warning, critical
        private var rank: Int { [.ok: 0, .info: 1, .warning: 2, .critical: 3][self]! }
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    public struct Finding: Codable, Sendable, Identifiable, Equatable {
        public let id: String
        public let severity: Severity
        public let title: String
        public let detail: String
    }

    public struct Stat: Codable, Sendable, Equatable {
        public let average: Double?
        public let maximum: Double?
    }

    public struct ProcessLine: Codable, Sendable, Equatable {
        public let name: String
        /// Share of one core (1.0 = one core fully busy) while the process was in the top ten.
        public let averageCPU: Double
        public let averageMemoryBytes: Double
        /// Share of the window's minutes the process was in the top ten.
        public let presence: Double
    }

    public let generatedAt: Date
    public let windowHours: Double
    /// Minutes with data divided by minutes in the window.
    public let coverage: Double
    public let cpu: Stat
    public let memory: Stat
    public let temperature: Stat
    public let power: Stat
    public let topByCPU: [ProcessLine]
    public let topByMemory: [ProcessLine]
    public let system: SystemSnapshot
    public let diskForecast: DiskSpaceForecast?
    public let findings: [Finding]

    public var overall: Severity { findings.map(\.severity).max() ?? .ok }
}

/// Live readings that don't come from the history database (injectable for tests).
public struct SystemSnapshot: Codable, Sendable, Equatable {
    public var swapUsedBytes: Double?
    public var uptimeSeconds: Double?
    public var diskFreeBytes: Double?
    public var diskTotalBytes: Double?
    /// Login and background items that are enabled and allowed; nil when the list couldn't be read.
    public var activeBackgroundItems: Int?

    public init(swapUsedBytes: Double? = nil, uptimeSeconds: Double? = nil, diskFreeBytes: Double? = nil,
                diskTotalBytes: Double? = nil, activeBackgroundItems: Int? = nil) {
        self.swapUsedBytes = swapUsedBytes
        self.uptimeSeconds = uptimeSeconds
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
        self.activeBackgroundItems = activeBackgroundItems
    }

    /// Reads swap, uptime and disk space. `activeBackgroundItems` is filled by the caller: reading
    /// it locally (`sfltool`) asks for an administrator password, so the app gets it from the Helper
    /// and the CLI only reads it when asked to (`includeBackgroundItems`).
    public static func current(includeBackgroundItems: Bool = false) -> SystemSnapshot {
        var s = SystemSnapshot()
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { s.swapUsedBytes = Double(swap.xsu_used) }
        var boot = timeval()
        size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 {
            s.uptimeSeconds = Date().timeIntervalSince1970 - Double(boot.tv_sec)
        }
        if let disk = DiskSpaceReader.current() {
            s.diskFreeBytes = disk.free
            s.diskTotalBytes = disk.total
        }
        if includeBackgroundItems, case .success(let items) = BackgroundItems.read() {
            s.activeBackgroundItems = BackgroundItems.activeCount(items)
        }
        return s
    }
}

public enum HealthCheck {
    /// Builds the report for the last `hours` of history.
    public static func run(history: MetricsHistory, hours: Double = 24, system: SystemSnapshot, now: Date = Date()) throws -> HealthReport {
        let since = now.addingTimeInterval(-hours * 3600)
        let samples = try history.samples(since: since)
        let processes = try? history.processUsage(since: since, until: now, top: 25)
        let disk = try history.diskSpace(since: now.addingTimeInterval(-14 * 86_400))
        return evaluate(samples: samples, processes: processes, diskPoints: disk, hours: hours, system: system, now: now)
    }

    /// Pure part of `run`, separated for tests.
    public static func evaluate(samples: [MetricSample], processes: ProcessUsageHistory?, diskPoints: [DiskSpacePoint],
                                hours: Double, system: SystemSnapshot, now: Date) -> HealthReport {
        func stat(_ values: [Double]) -> HealthReport.Stat {
            HealthReport.Stat(average: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count), maximum: values.max())
        }
        let cpuValues = samples.compactMap(\.cpu), memValues = samples.compactMap(\.memory)
        let tempValues = samples.compactMap(\.temperature), powerValues = samples.compactMap(\.power)
        let expectedMinutes = max(hours * 60, 1)
        let coverage = min(Double(samples.count) / expectedMinutes, 1)
        let totalMinutes = Double(max(processes?.totalMinuteCount ?? 0, 1))
        func lines(_ ranks: [ProcessUsageRank]) -> [HealthReport.ProcessLine] {
            ranks.map { .init(name: $0.name, averageCPU: $0.averageCPU, averageMemoryBytes: $0.averageMemoryBytes,
                              presence: min(Double($0.minuteCount) / totalMinutes, 1)) }
        }
        // Rank by load over the whole window, so a short spike doesn't outrank a steady consumer.
        let byCPU = Array(lines(processes?.byCPU ?? []).sorted { $0.averageCPU * $0.presence > $1.averageCPU * $1.presence }.prefix(5))
        let byMemory = Array(lines(processes?.byMemory ?? []).sorted { $0.averageMemoryBytes * $0.presence > $1.averageMemoryBytes * $1.presence }.prefix(5))
        let forecast = DiskSpaceForecast.compute(diskPoints)

        var findings: [HealthReport.Finding] = []
        func add(_ id: String, _ severity: HealthReport.Severity, _ title: String, _ detail: String) {
            findings.append(.init(id: id, severity: severity, title: title, detail: detail))
        }
        let pct = { (v: Double) in v.formatted(.percent.precision(.fractionLength(0))) }
        let bytes = { (v: Double) in ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file) }

        if coverage < 0.5 {
            add("coverage", .info, String(localized: "Limited history", bundle: .module),
                String(localized: "Only \(pct(coverage)) of this period has data. Turn on background recording so the report also covers time when MacHelper isn’t open.", bundle: .module))
        }
        if !cpuValues.isEmpty {
            let busy = Double(cpuValues.filter { $0 >= 0.8 }.count) / Double(cpuValues.count)
            if busy >= 0.2 {
                add("cpu.busy", .warning, String(localized: "CPU often fully loaded", bundle: .module),
                    String(localized: "CPU use was 80% or higher in \(pct(busy)) of the recorded minutes.", bundle: .module))
            }
        }
        if let top = byCPU.first, top.averageCPU >= 0.5, top.presence >= 0.5 {
            add("cpu.process", .warning, String(localized: "\(top.name) keeps the CPU busy", bundle: .module),
                String(localized: "It used \(pct(top.averageCPU)) of a core on average and was among the busiest processes in \(pct(top.presence)) of the minutes.", bundle: .module))
        }
        if let avg = stat(memValues).average, avg >= 0.85 {
            add("memory.high", .warning, String(localized: "Memory nearly full", bundle: .module),
                String(localized: "Memory use averaged \(pct(avg)). Quitting apps you don’t need, or the ones at the top of the memory list, helps.", bundle: .module))
        }
        if let swap = system.swapUsedBytes, swap >= 1e9 {
            add("memory.swap", swap >= 4e9 ? .warning : .info, String(localized: "Swap in use", bundle: .module),
                String(localized: "\(bytes(swap)) of memory has been moved to disk. A restart clears it; if it keeps growing, the Mac needs more memory than it has for this workload.", bundle: .module))
        }
        if !tempValues.isEmpty {
            let hot = Double(tempValues.filter { $0 >= 95 }.count) / Double(tempValues.count)
            if hot >= 0.1 {
                add("thermal.hot", .warning, String(localized: "Running hot", bundle: .module),
                    String(localized: "The CPU was at 95 °C or more in \(pct(hot)) of the recorded minutes; the system may slow it down to cool off. Check airflow and the busiest processes.", bundle: .module))
            }
        }
        if let free = system.diskFreeBytes, let total = system.diskTotalBytes, total > 0 {
            let share = free / total
            if share < 0.1 {
                add("disk.low", .critical, String(localized: "Startup disk almost full", bundle: .module),
                    String(localized: "Only \(bytes(free)) (\(pct(share))) is free. macOS needs free space for updates, swap and caches; run Optimize or Disk Analysis.", bundle: .module))
            } else if share < 0.2 {
                add("disk.low", .warning, String(localized: "Startup disk getting full", bundle: .module),
                    String(localized: "\(bytes(free)) (\(pct(share))) is free.", bundle: .module))
            }
        }
        if let forecast, let days = forecast.daysUntilFull, days < 30 {
            let daysText = days.formatted(.number.precision(.fractionLength(0)))
            add("disk.trend", days < 7 ? .critical : .warning, String(localized: "Free space is shrinking", bundle: .module),
                String(localized: "At the current rate of \(bytes(-forecast.bytesPerDay)) a day, the startup disk is full in about \(daysText) days.", bundle: .module))
        }
        if let uptime = system.uptimeSeconds, uptime >= 14 * 86_400 {
            let days = Int(uptime / 86_400)
            add("uptime", .info, String(localized: "Not restarted for \(days) days", bundle: .module),
                String(localized: "A restart clears swap and finishes pending updates.", bundle: .module))
        }
        if let n = system.activeBackgroundItems, n >= 30 {
            add("background.many", .info, String(localized: "Many background items", bundle: .module),
                String(localized: "\(n) login and background items are active. Review them under Startup Items → Login & Background Items.", bundle: .module))
        }
        findings.sort { $0.severity > $1.severity }

        return HealthReport(generatedAt: now, windowHours: hours, coverage: coverage, cpu: stat(cpuValues), memory: stat(memValues),
                            temperature: stat(tempValues), power: stat(powerValues), topByCPU: byCPU, topByMemory: byMemory,
                            system: system, diskForecast: forecast, findings: findings)
    }
}
