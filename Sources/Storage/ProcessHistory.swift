import Foundation

/// One process as the sampler read it. `pid` only recognises the same process in the CPU
/// and memory rankings of one sample; it is never written to the database. Of the fields
/// here, only `name` is kept for history — no executable path and no command-line arguments.
public struct ProcessUsageReading: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    /// CPU use since the previous sample, in cores (1.0 = one core fully busy).
    public var cpu: Double
    /// Physical footprint in bytes.
    public var memoryBytes: UInt64

    public init(pid: Int32, name: String, cpu: Double, memoryBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memoryBytes = memoryBytes
    }
}

/// The two rankings a process sampler produced for one moment. The same process may appear
/// in both; the minute accumulator counts it once. `hiddenCount` is how many processes the
/// sampler could not read, so a reader never mistakes them for idle processes.
public struct ProcessUsageReadings: Sendable, Equatable {
    public var byCPU: [ProcessUsageReading]
    public var byMemory: [ProcessUsageReading]
    public var hiddenCount: Int

    public init(byCPU: [ProcessUsageReading], byMemory: [ProcessUsageReading], hiddenCount: Int) {
        self.byCPU = byCPU
        self.byMemory = byMemory
        self.hiddenCount = hiddenCount
    }
}

/// Sum and observation count for one process name in one minute. Processes that share a
/// name are added together first, so the average is the name's total CPU or memory.
public struct ProcessUsageTotals: Sendable, Equatable {
    public var cpu: ColumnTotals
    public var memoryBytes: ColumnTotals

    public init(cpu: ColumnTotals, memoryBytes: ColumnTotals) {
        self.cpu = cpu
        self.memoryBytes = memoryBytes
    }
}

/// One finished minute ready to store. `processes` keeps only the union of the minute's top
/// ten names by average CPU and by average memory, which bounds a minute to about twenty
/// rows regardless of how many processes the machine ran. It can be empty when every
/// process was unreadable; `hiddenCount` still records how many were missed.
public struct FinishedProcessMinute: Sendable, Equatable {
    public var time: Date
    public var processes: [String: ProcessUsageTotals]
    /// Largest number of unreadable processes seen while the minute was open.
    public var hiddenCount: Int

    public init(time: Date, processes: [String: ProcessUsageTotals], hiddenCount: Int = 0) {
        self.time = time
        self.processes = processes
        self.hiddenCount = hiddenCount
    }
}

/// Accumulates process samples into whole minutes. Each sample contributes one observation
/// per name after processes that share a name are added together. When the minute closes,
/// only the top ten names by average CPU and by average memory survive.
public struct ProcessMinuteAccumulator: Sendable {
    private var minute: Date?
    private var aggregates: [String: (cpuSum: Double, cpuCount: Int, memorySum: Double, memoryCount: Int)] = [:]
    private var hiddenCount: Int = 0

    public init() {}

    public mutating func add(_ readings: ProcessUsageReadings, at date: Date = Date()) -> FinishedProcessMinute? {
        let m = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var finished: FinishedProcessMinute?
        if let current = minute, current != m {
            finished = flush(current)
        }
        if minute == nil || minute != m {
            minute = m
            aggregates = [:]
            hiddenCount = 0
        }

        // Deduplicate by pid within this snapshot: the same process may be listed in both
        // rankings, but it is one observation.
        var byPid: [Int32: ProcessUsageReading] = [:]
        for reading in readings.byCPU where byPid[reading.pid] == nil {
            byPid[reading.pid] = reading
        }
        for reading in readings.byMemory where byPid[reading.pid] == nil {
            byPid[reading.pid] = reading
        }

        // Group by name; one observation per name per snapshot, even when several pids
        // share the name.
        var cpuByName: [String: Double] = [:]
        var memoryByName: [String: Double] = [:]
        for reading in byPid.values {
            cpuByName[reading.name, default: 0] += reading.cpu
            memoryByName[reading.name, default: 0] += Double(reading.memoryBytes)
        }
        for (name, cpuSum) in cpuByName {
            let memorySum = memoryByName[name] ?? 0
            let existing = aggregates[name] ?? (cpuSum: 0, cpuCount: 0, memorySum: 0, memoryCount: 0)
            aggregates[name] = (cpuSum: existing.cpuSum + cpuSum,
                                cpuCount: existing.cpuCount + 1,
                                memorySum: existing.memorySum + memorySum,
                                memoryCount: existing.memoryCount + 1)
        }
        hiddenCount = max(hiddenCount, readings.hiddenCount)
        return finished
    }

    private mutating func flush(_ time: Date) -> FinishedProcessMinute? {
        let names = Array(aggregates.keys)
        func cpuAverage(_ name: String) -> Double {
            let a = aggregates[name]!
            return a.cpuCount > 0 ? a.cpuSum / Double(a.cpuCount) : 0
        }
        func memoryAverage(_ name: String) -> Double {
            let a = aggregates[name]!
            return a.memoryCount > 0 ? a.memorySum / Double(a.memoryCount) : 0
        }
        let topCPU = Set(names.sorted { a, b in
            let left = cpuAverage(a), right = cpuAverage(b)
            if left != right { return left > right }
            return a < b
        }.prefix(10))
        let topMemory = Set(names.sorted { a, b in
            let left = memoryAverage(a), right = memoryAverage(b)
            if left != right { return left > right }
            return a < b
        }.prefix(10))

        var processes: [String: ProcessUsageTotals] = [:]
        for name in topCPU.union(topMemory) {
            let a = aggregates[name]!
            processes[name] = ProcessUsageTotals(
                cpu: ColumnTotals(sum: a.cpuSum, count: a.cpuCount),
                memoryBytes: ColumnTotals(sum: a.memorySum, count: a.memoryCount))
        }
        if processes.isEmpty && hiddenCount == 0 {
            return nil
        }
        return FinishedProcessMinute(time: time, processes: processes, hiddenCount: hiddenCount)
    }
}

/// One process in a history ranking. Averages cover only the minutes the process appeared
/// in; a minute it was not recorded in is not a zero.
public struct ProcessUsageRank: Sendable, Equatable {
    public var name: String
    public var averageCPU: Double
    public var averageMemoryBytes: Double
    /// Number of minutes the process appeared in within the requested range.
    public var minuteCount: Int

    public init(name: String, averageCPU: Double, averageMemoryBytes: Double, minuteCount: Int) {
        self.name = name
        self.averageCPU = averageCPU
        self.averageMemoryBytes = averageMemoryBytes
        self.minuteCount = minuteCount
    }
}

/// Process rankings for a time range. Only each minute's top ten by CPU and by memory are
/// stored, so a name absent from a minute may still have been running. Compare a rank's
/// `minuteCount` with `totalMinuteCount` to see how much of the range it covers.
public struct ProcessUsageHistory: Sendable, Equatable {
    public var byCPU: [ProcessUsageRank]
    public var byMemory: [ProcessUsageRank]
    /// Whole minutes in the requested range.
    public var totalMinuteCount: Int
    /// Largest number of unreadable processes seen in one minute of the range.
    public var hiddenCount: Int

    public init(byCPU: [ProcessUsageRank], byMemory: [ProcessUsageRank],
                totalMinuteCount: Int, hiddenCount: Int) {
        self.byCPU = byCPU
        self.byMemory = byMemory
        self.totalMinuteCount = totalMinuteCount
        self.hiddenCount = hiddenCount
    }
}
