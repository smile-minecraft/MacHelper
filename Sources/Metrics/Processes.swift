import Darwin
import Foundation

public struct ProcessUsage: Sendable, Hashable, Codable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    /// Path of the executable, when readable.
    public let path: String?
    /// CPU use since the previous sample, in cores (1.0 = one core fully busy).
    public let cpu: Double
    /// Physical footprint, the number Activity Monitor shows as "Memory".
    public let memoryBytes: UInt64

    /// The .app bundle the executable lives in, if any.
    public var appPath: String? {
        path.flatMap(ProcessGrouping.outermostApp)
    }
}

public struct ProcessSnapshot: Sendable, Hashable {
    public let byCPU: [ProcessUsage]
    public let byMemory: [ProcessUsage]
    /// Processes that could not be read (other users' and system processes need root).
    public let hiddenCount: Int

    public init(byCPU: [ProcessUsage], byMemory: [ProcessUsage], hiddenCount: Int) {
        self.byCPU = byCPU
        self.byMemory = byMemory
        self.hiddenCount = hiddenCount
    }
}

/// Where one process sample comes from: which pids to consider, their cumulative counters, and how
/// a pid is named. Production reads the kernel; a test supplies its own values, so a sample never
/// depends on which processes happen to run on the machine or how long they live.
public protocol ProcessDataSource: Sendable {
    /// Pids the sample may include. A process can end at any point after this returns.
    func pids() -> [Int32]
    /// Cumulative CPU nanoseconds and physical footprint for `pid`, or nil when it cannot be read
    /// (another user's process, or one that just ended).
    func counters(pid: Int32) -> (cpuNanos: UInt64, footprint: UInt64)?
    /// The executable's path, when readable.
    func executablePath(pid: Int32) -> String?
    /// The kernel's name for the process, used when the path cannot be read.
    func name(pid: Int32) -> String
    /// A monotonic clock in nanoseconds, the unit `counters` reports cumulative CPU in.
    func uptime() -> UInt64
}

/// The kernel: proc_listallpids, proc_pid_rusage and proc_pidpath.
struct SystemProcessDataSource: ProcessDataSource {
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    func pids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(n, 0))))
    }

    func counters(pid: Int32) -> (cpuNanos: UInt64, footprint: UInt64)? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        // ri_user_time / ri_system_time are mach ticks on Apple Silicon.
        return ((info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom,
                info.ri_phys_footprint)
    }

    func executablePath(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func name(pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        proc_name(pid, &buf, UInt32(buf.count))
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func uptime() -> UInt64 {
        mach_absolute_time() * timebase.numer / timebase.denom
    }
}

/// Per-process CPU and memory, from proc_pid_rusage. Only processes this user may inspect are
/// included; CPU needs two samples, so the first call reports 0.
public final class ProcessSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [Int32: (cpuNanos: UInt64, at: UInt64)] = [:]
    private let source: any ProcessDataSource

    public init() {
        source = SystemProcessDataSource()
    }

    /// Samples supplied values instead of the kernel's. Used by tests to prove the delta, ordering
    /// and drop rules without depending on the processes running on this machine.
    init(source: any ProcessDataSource) {
        self.source = source
    }

    /// - Parameter privileged: counters read by the root Helper (pid → cumulative CPU nanoseconds and
    ///   footprint), used for processes this user can't inspect. Without them those processes are
    ///   counted in `hiddenCount`.
    public func sample(top: Int = 8, privileged: [Int32: (cpuNanos: UInt64, footprint: UInt64)]? = nil) -> ProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = source.uptime()
        var usages: [ProcessUsage] = []
        var seen: [Int32: (UInt64, UInt64)] = [:]
        var hidden = 0
        for pid in source.pids() where pid > 0 {
            let cpuNanos: UInt64, footprint: UInt64
            if let counter = source.counters(pid: pid) {
                (cpuNanos, footprint) = counter
            } else if let counter = privileged?[pid] {
                cpuNanos = counter.cpuNanos
                footprint = counter.footprint
            } else {
                hidden += 1
                continue
            }
            seen[pid] = (cpuNanos, now)
            var cpu = 0.0
            if let prev = last[pid], now > prev.at, cpuNanos >= prev.cpuNanos {
                cpu = Double(cpuNanos - prev.cpuNanos) / Double(now - prev.at)
            }
            // One path lookup per process: the name comes from the same lookup,
            // so a sample does not resolve every path twice.
            let executablePath = source.executablePath(pid: pid)
            let name = Self.name(pid, path: executablePath, source: source)
            // A process that ended between its counters and its path lookup has no name left to
            // show, and no next sample either. Dropping it keeps a blank row out of the list
            // instead of counting it as a process this user cannot inspect.
            guard !name.isEmpty else { continue }
            usages.append(ProcessUsage(pid: pid, name: name, path: executablePath, cpu: cpu,
                                       memoryBytes: footprint))
        }
        last = seen.mapValues { (cpuNanos: $0.0, at: $0.1) }
        return ProcessSnapshot(byCPU: Array(usages.sorted { $0.cpu > $1.cpu }.prefix(top)),
                               byMemory: Array(usages.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(top)),
                               hiddenCount: hidden)
    }

    static func name(_ pid: Int32) -> String {
        let source = SystemProcessDataSource()
        return name(pid, path: source.executablePath(pid: pid), source: source)
    }

    /// Display name for a process whose executable path is already known. Falls back
    /// to proc_name (limited to 32 characters) only when the path is unreadable.
    static func name(_ pid: Int32, path: String?, source: any ProcessDataSource = SystemProcessDataSource()) -> String {
        if let path { return (path as NSString).lastPathComponent }
        return source.name(pid: pid)
    }

    static func path(_ pid: Int32) -> String? {
        SystemProcessDataSource().executablePath(pid: pid)
    }
}
