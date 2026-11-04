import Foundation
import IOKit

public struct DiskReading: Sendable, Hashable, Codable {
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    /// Free space on the boot volume including purgeable space (what Finder shows).
    public var availableBytes: Int64
    public var totalBytes: Int64
}

/// Disk throughput from IOBlockStorageDriver statistics plus boot-volume capacity.
public final class DiskSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: (read: UInt64, write: UInt64, time: Date)?
    private let volume: URL

    public init(volume: URL = URL(fileURLWithPath: "/")) { self.volume = volume }

    public func sample() -> DiskReading? {
        let (r, w) = Self.ioTotals()
        let now = Date()
        let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        return lock.withLock {
            defer { previous = (r, w, now) }
            guard let prev = previous else { return nil }
            let dt = now.timeIntervalSince(prev.time)
            guard dt > 0 else { return nil }
            return DiskReading(
                readBytesPerSecond: r >= prev.read ? Double(r - prev.read) / dt : 0,
                writeBytesPerSecond: w >= prev.write ? Double(w - prev.write) / dt : 0,
                availableBytes: available,
                totalBytes: total
            )
        }
    }

    static func ioTotals() -> (UInt64, UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            else { continue }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
}
