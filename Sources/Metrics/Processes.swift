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
        guard let path, let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
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

/// Per-process CPU and memory, from proc_pid_rusage. Only processes this user may inspect are
/// included; CPU needs two samples, so the first call reports 0.
public final class ProcessSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [Int32: (cpuNanos: UInt64, at: UInt64)] = [:]
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    public init() {}

    public func sample(top: Int = 8) -> ProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return ProcessSnapshot(byCPU: [], byMemory: [], hiddenCount: 0) }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let now = mach_absolute_time()
        var usages: [ProcessUsage] = []
        var seen: [Int32: (UInt64, UInt64)] = [:]
        var hidden = 0
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { hidden += 1; continue }
            // ri_user_time / ri_system_time are mach ticks on Apple Silicon.
            let cpuNanos = (info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom
            let at = now * timebase.numer / timebase.denom
            seen[pid] = (cpuNanos, at)
            var cpu = 0.0
            if let prev = last[pid], at > prev.at, cpuNanos >= prev.cpuNanos {
                cpu = Double(cpuNanos - prev.cpuNanos) / Double(at - prev.at)
            }
            usages.append(ProcessUsage(pid: pid, name: Self.name(pid), path: Self.path(pid), cpu: cpu,
                                       memoryBytes: info.ri_phys_footprint))
        }
        last = seen.mapValues { (cpuNanos: $0.0, at: $0.1) }
        return ProcessSnapshot(byCPU: Array(usages.sorted { $0.cpu > $1.cpu }.prefix(top)),
                               byMemory: Array(usages.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(top)),
                               hiddenCount: hidden)
    }

    static func name(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        // proc_name is limited to 32 characters; the executable's file name is not.
        if let p = path(pid) { return (p as NSString).lastPathComponent }
        proc_name(pid, &buf, UInt32(buf.count))
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
