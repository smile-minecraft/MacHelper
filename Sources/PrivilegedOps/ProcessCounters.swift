import Darwin
import Foundation

/// Raw per-process counters (cumulative CPU time and memory footprint) read by the root Helper for
/// processes the app can't inspect itself (other users' and system processes). Only numbers leave
/// the Helper; names and paths the app reads itself (`proc_pidpath` works for any process).
public struct ProcessCounter: Codable, Sendable, Equatable {
    public let pid: Int32
    /// User + system CPU time in nanoseconds since the process started.
    public let cpuNanos: UInt64
    /// Physical footprint in bytes (Activity Monitor's "Memory").
    public let footprint: UInt64

    public init(pid: Int32, cpuNanos: UInt64, footprint: UInt64) {
        self.pid = pid
        self.cpuNanos = cpuNanos
        self.footprint = footprint
    }
}

public enum ProcessCounters {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Counters for every process this caller may read (all of them, when run as root).
    public static func readAll() -> [ProcessCounter] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return pids.prefix(Int(max(n, 0))).compactMap { pid in pid > 0 ? read(pid) : nil }
    }

    public static func read(_ pid: Int32) -> ProcessCounter? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        // ri_user_time / ri_system_time are mach ticks on Apple silicon.
        let ticks = info.ri_user_time &+ info.ri_system_time
        return ProcessCounter(pid: pid, cpuNanos: ticks &* timebase.numer / timebase.denom, footprint: info.ri_phys_footprint)
    }
}
