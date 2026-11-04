import CSystemBridge
import Darwin
import Foundation
import IOKit
import SMCKit

public struct MemoryReading: Sendable, Hashable, Codable {
    public enum Pressure: Int, Sendable, Codable { case normal = 1, warning = 2, critical = 4 }
    public var totalBytes: UInt64
    public var usedBytes: UInt64
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var swapUsedBytes: UInt64
    public var pressure: Pressure
}

public enum MemorySampler {
    public static func sample() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(sysctlInt("hw.pagesize") ?? 16384)
        let total = UInt64(sysctlInt("hw.memsize") ?? 0)
        // Same formula Activity Monitor uses: app = internal - purgeable; used = app + wired + compressed.
        let app = (UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let level = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        return MemoryReading(
            totalBytes: total,
            usedBytes: app + wired + compressed,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            swapUsedBytes: swap.xsu_used,
            pressure: MemoryReading.Pressure(rawValue: level) ?? .normal
        )
    }
}

public struct GPUReading: Sendable, Hashable, Codable {
    public var name: String
    /// 0...1
    public var utilization: Double
}

/// GPU utilisation from IOAccelerator `PerformanceStatistics` (no private API, no root).
public enum GPUSampler {
    public static func sample() -> [GPUReading] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [GPUReading] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            else { continue }
            let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
                ?? (stats["GPU Activity(%)"] as? NSNumber)?.doubleValue ?? 0
            let name = (IORegistryEntryCreateCFProperty(entry, "model" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String) ?? "GPU"
            result.append(GPUReading(name: name, utilization: util / 100))
        }
        return result
    }
}
