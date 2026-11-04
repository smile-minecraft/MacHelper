import Darwin
import Foundation

public struct NetworkReading: Sendable, Hashable, Codable {
    public var inBytesPerSecond: Double
    public var outBytesPerSecond: Double
}

/// Throughput from 64-bit interface counters (`NET_RT_IFLIST2`; `getifaddrs` counters are 32-bit and wrap at 4 GB).
public final class NetworkSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: (inBytes: UInt64, outBytes: UInt64, time: Date)?

    /// Virtual interfaces whose traffic is already counted on a physical interface.
    private static let excludedPrefixes = ["lo", "utun", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap"]

    public init() {}

    public func sample() -> NetworkReading? {
        guard let (i, o) = Self.totals() else { return nil }
        let now = Date()
        return lock.withLock {
            defer { previous = (i, o, now) }
            guard let prev = previous else { return nil }
            let dt = now.timeIntervalSince(prev.time)
            guard dt > 0 else { return nil }
            // Counters can reset when an interface goes away; treat that as zero instead of a huge spike.
            let di = i >= prev.inBytes ? Double(i - prev.inBytes) : 0
            let dout = o >= prev.outBytes ? Double(o - prev.outBytes) : 0
            return NetworkReading(inBytesPerSecond: di / dt, outBytesPerSecond: dout / dt)
        }
    }

    static func totals() -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }

        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                defer { offset += Int(header.ifm_msglen) }
                guard header.ifm_msglen > 0 else { offset = length; return }
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      offset + MemoryLayout<if_msghdr2>.size <= length
                else { continue }
                let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                guard if_indextoname(UInt32(msg.ifm_index), &nameBuf) != nil else { continue }
                let name = String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                guard !excludedPrefixes.contains(where: name.hasPrefix) else { continue }
                totalIn &+= msg.ifm_data.ifi_ibytes
                totalOut &+= msg.ifm_data.ifi_obytes
            }
        }
        return (totalIn, totalOut)
    }
}
