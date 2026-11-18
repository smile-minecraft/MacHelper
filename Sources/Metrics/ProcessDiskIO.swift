import Darwin
import Foundation

/// Disk I/O the kernel attributes to one app (all of its processes) or one standalone process.
public struct ProcessDiskIOUsage: Sendable, Hashable, Identifiable {
    /// The enclosing app bundle path, or `name.pid` for a process outside any app.
    public let id: String
    public let name: String
    /// Executable path of the busiest process in the group, when readable.
    public let path: String?
    /// The outermost `.app` bundle the processes belong to.
    public let appPath: String?
    public let processCount: Int
    /// nil on the first snapshot: a rate needs two snapshots of the same process.
    ///
    /// These are process I/O counters, not physical disk throughput. The kernel counts a read
    /// only when it misses the page cache and counts a write when it is submitted to the device;
    /// both are attributed to the process that submitted them.
    public let readBytesPerSecond: Double?
    public let writeBytesPerSecond: Double?
    /// Bytes read and written since each process started.
    public let totalReadBytes: UInt64
    public let totalWriteBytes: UInt64

    public var totalBytesPerSecond: Double? {
        guard let r = readBytesPerSecond, let w = writeBytesPerSecond else { return nil }
        return r + w
    }

    public var totalBytes: UInt64 { totalReadBytes &+ totalWriteBytes }
}

public struct ProcessDiskIOSnapshot: Sendable, Hashable {
    public let capturedAt: Date
    /// Every group with I/O since its processes started, busiest first (by rate when known,
    /// otherwise by total bytes).
    public let items: [ProcessDiskIOUsage]
    /// false until the sampler has two snapshots to compare.
    public let hasRates: Bool
    /// Processes whose counters this user may not read (other users and system processes
    /// need root). They are excluded instead of being reported as zero.
    public let hiddenCount: Int
}

/// Cumulative disk counters for one process.
struct ProcessDiskReading: Sendable, Hashable {
    var name: String
    /// Identifies the process instance, so a reused pid never produces a spike.
    var startAbstime: UInt64
    var readBytes: UInt64
    var writeBytes: UInt64
}

/// Per-process disk I/O without root, read from `proc_pid_rusage(RUSAGE_INFO_V4)`.
///
/// `ri_diskio_bytesread` counts bytes the process read that were not in the page cache;
/// `ri_diskio_byteswritten` counts bytes it wrote. Both come from the kernel's `task_io_stats`,
/// so they measure the process's file I/O rather than the physical device's throughput (which
/// also includes other users, paging and filesystem metadata outside any process).
///
/// The call is cheap and does not block on I/O, but it walks every pid: run it off the main
/// actor, and only while someone is looking at the numbers.
public final class ProcessDiskIOSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: (readings: [Int32: ProcessDiskReading], time: Date)?
    private let listPIDs: @Sendable () -> [Int32]?
    private let read: @Sendable (Int32) -> (read: UInt64, write: UInt64, start: UInt64, name: String)?
    private let resolvePath: @Sendable (Int32) -> String?
    private let now: @Sendable () -> Date

    public init() {
        listPIDs = Self.allPIDs
        read = Self.read
        resolvePath = { ProcessSampler.path($0) }
        now = { Date() }
    }

    /// Test seam: canned pid list, counters, path lookup and clock.
    init(listPIDs: @escaping @Sendable () -> [Int32]?,
         read: @escaping @Sendable (Int32) -> (read: UInt64, write: UInt64, start: UInt64, name: String)?,
         resolvePath: @escaping @Sendable (Int32) -> String?,
         now: @escaping @Sendable () -> Date) {
        self.listPIDs = listPIDs
        self.read = read
        self.resolvePath = resolvePath
        self.now = now
    }

    /// Forgets the previous snapshot, so the next rates are not computed across a long pause.
    public func reset() {
        lock.withLock { previous = nil }
    }

    public func sample() -> ProcessDiskIOSnapshot? {
        guard let pids = listPIDs() else { return nil }
        var current: [Int32: ProcessDiskReading] = [:]
        var hidden = 0
        for pid in pids where pid > 0 {
            guard let r = read(pid) else {
                hidden += 1
                continue
            }
            current[pid] = ProcessDiskReading(name: r.name, startAbstime: r.start,
                                              readBytes: r.read, writeBytes: r.write)
        }
        guard !current.isEmpty else { return nil }
        let time = now()
        let prev: (readings: [Int32: ProcessDiskReading], time: Date)? = lock.withLock {
            defer { previous = (current, time) }
            return previous
        }
        return Self.snapshot(current: current, previous: prev, now: time,
                             hiddenCount: hidden, resolvePath: resolvePath)
    }

    /// Groups processes by app and computes rates against the previous snapshot. A process that
    /// is new, or whose pid was reused (different start time), counts as zero for this interval
    /// instead of a spike.
    static func snapshot(current: [Int32: ProcessDiskReading],
                         previous: (readings: [Int32: ProcessDiskReading], time: Date)?,
                         now: Date,
                         hiddenCount: Int,
                         resolvePath: (Int32) -> String?) -> ProcessDiskIOSnapshot {
        let dt = previous.map { now.timeIntervalSince($0.time) } ?? 0
        let hasRates = previous != nil && dt > 0

        struct Group {
            var name: String
            var path: String?
            var appPath: String?
            var count = 0
            var readRate = 0.0, writeRate = 0.0
            var totalRead: UInt64 = 0, totalWrite: UInt64 = 0
            var busiest = -1.0
        }
        var groups: [String: Group] = [:]
        for (pid, reading) in current {
            guard reading.readBytes > 0 || reading.writeBytes > 0 else { continue }
            var readRate = 0.0, writeRate = 0.0
            if hasRates, let old = previous?.readings[pid], old.startAbstime == reading.startAbstime {
                readRate = reading.readBytes >= old.readBytes ? Double(reading.readBytes - old.readBytes) / dt : 0
                writeRate = reading.writeBytes >= old.writeBytes ? Double(reading.writeBytes - old.writeBytes) / dt : 0
            }
            let path = resolvePath(pid)
            let appPath = path.flatMap(ProcessGrouping.outermostApp)
            let key = appPath ?? "\(reading.name).\(pid)"
            var g = groups[key] ?? Group(name: appPath.map(ProcessGrouping.appName)
                                            ?? path.map { ($0 as NSString).lastPathComponent } ?? reading.name,
                                         path: path, appPath: appPath)
            g.count += 1
            g.readRate += readRate
            g.writeRate += writeRate
            g.totalRead &+= reading.readBytes
            g.totalWrite &+= reading.writeBytes
            if readRate + writeRate > g.busiest { g.busiest = readRate + writeRate; g.path = path }
            groups[key] = g
        }
        let items = groups.map { key, g in
            ProcessDiskIOUsage(id: key, name: g.name, path: g.path, appPath: g.appPath, processCount: g.count,
                               readBytesPerSecond: hasRates ? g.readRate : nil,
                               writeBytesPerSecond: hasRates ? g.writeRate : nil,
                               totalReadBytes: g.totalRead, totalWriteBytes: g.totalWrite)
        }
        .sorted { a, b in
            let ra = a.totalBytesPerSecond ?? 0, rb = b.totalBytesPerSecond ?? 0
            if ra != rb { return ra > rb }
            if a.totalBytes != b.totalBytes { return a.totalBytes > b.totalBytes }
            return a.id < b.id
        }
        return ProcessDiskIOSnapshot(capturedAt: now, items: items, hasRates: hasRates,
                                     hiddenCount: hiddenCount)
    }

    private static func allPIDs() -> [Int32]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard n > 0 else { return nil }
        return Array(pids.prefix(Int(n)))
    }

    private static func read(_ pid: Int32) -> (read: UInt64, write: UInt64, start: UInt64, name: String)? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        return (info.ri_diskio_bytesread, info.ri_diskio_byteswritten,
                info.ri_proc_start_abstime, ProcessSampler.name(pid))
    }
}
