import Foundation
import IOKit

public struct GPUProcessUsage: Sendable, Hashable, Codable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let path: String?
    /// Share of GPU time since the previous sample (0…1; 1 = the GPU busy with this process the whole time).
    public let gpu: Double

    public init(pid: Int32, name: String, path: String?, gpu: Double) {
        self.pid = pid
        self.name = name
        self.path = path
        self.gpu = gpu
    }

    /// The .app bundle the executable lives in, if any.
    public var appPath: String? {
        guard let path, let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}

/// Per-process GPU time from the IORegistry: every GPU user client (children of `IOAccelerator`)
/// names its creator ("pid 176, WindowServer") and carries `AppUsage` entries with an
/// `accumulatedGPUTime` in nanoseconds. No root, no private API. Usage needs two samples, so the
/// first call reports nothing. GPUs that don't publish `AppUsage` yield an empty list.
public final class GPUProcessSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (at: UInt64, times: [Int32: UInt64])?
    private var names: [Int32: String] = [:]

    public init() {}

    public func sample(top: Int = 8) -> [GPUProcessUsage] {
        let (times, creatorNames) = Self.readRegistry()
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        defer { last = (now, times) }
        guard let last else { return [] }
        let usage = Self.usage(previous: last.times, current: times, elapsedNanos: now &- last.at)
        // Names are cached per pid; the registry's creator name is cut to 16 characters.
        names = names.filter { times[$0.key] != nil }
        return usage.prefix(top).map { pid, share in
            let name = names[pid] ?? {
                let n = ProcessSampler.path(pid).map { ($0 as NSString).lastPathComponent } ?? creatorNames[pid] ?? "pid \(pid)"
                names[pid] = n
                return n
            }()
            return GPUProcessUsage(pid: pid, name: name, path: ProcessSampler.path(pid), gpu: share)
        }
    }

    /// Busiest first; processes with no new GPU time are left out. Shares are capped at 1
    /// (several command queues can overlap).
    static func usage(previous: [Int32: UInt64], current: [Int32: UInt64], elapsedNanos: UInt64) -> [(pid: Int32, share: Double)] {
        guard elapsedNanos > 0 else { return [] }
        return current.compactMap { pid, time -> (Int32, Double)? in
            // A pid seen for the first time (or whose counter went backwards: pid reused) has no baseline.
            guard let before = previous[pid], time > before else { return nil }
            return (pid, min(Double(time - before) / Double(elapsedNanos), 1))
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        .map { (pid: $0.0, share: $0.1) }
    }

    /// "pid 176, WindowServer" → (176, "WindowServer").
    static func parseCreator(_ s: String) -> (pid: Int32, name: String)? {
        guard s.hasPrefix("pid ") else { return nil }
        let rest = s.dropFirst(4)
        let digits = rest.prefix { $0.isNumber }
        guard let pid = Int32(digits), pid > 0 else { return nil }
        var name = rest.dropFirst(digits.count)
        if name.hasPrefix(",") { name = name.dropFirst() }
        return (pid, name.trimmingCharacters(in: .whitespaces))
    }

    /// Sum of `accumulatedGPUTime` over a client's `AppUsage` entries.
    static func accumulatedTime(_ appUsage: Any?) -> UInt64 {
        guard let entries = appUsage as? [[String: Any]] else { return 0 }
        return entries.reduce(0) { $0 &+ ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
    }

    /// pid → total GPU nanoseconds, plus the registry's (short) creator names.
    static func readRegistry() -> ([Int32: UInt64], [Int32: String]) {
        var times: [Int32: UInt64] = [:]
        var names: [Int32: String] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS
        else { return (times, names) }
        defer { IOObjectRelease(accelerators) }
        while case let accel = IOIteratorNext(accelerators), accel != 0 {
            defer { IOObjectRelease(accel) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      let (pid, name) = parseCreator(creator) else { continue }
                let t = accumulatedTime(property(client, "AppUsage"))
                times[pid, default: 0] &+= t
                if names[pid] == nil, !name.isEmpty { names[pid] = name }
            }
        }
        return (times, names)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
