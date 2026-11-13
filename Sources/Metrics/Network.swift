import Darwin
import Foundation

public struct NetworkReading: Sendable, Hashable, Codable {
    public var inBytesPerSecond: Double
    public var outBytesPerSecond: Double
}

/// One interface record from a `NET_RT_IFLIST2` dump.
struct InterfaceListEntry: Sendable, Hashable {
    var name: String
    var mtu: UInt32
    var baudrate: UInt64
    var inBytes: UInt64
    var outBytes: UInt64
}

/// The only sysctl boundary for the interface list. Both throughput and link details read
/// the same buffer, so there is one parser instead of two copies.
enum InterfaceListReader {
    static func read() -> (buffer: [UInt8], length: Int)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        return (buffer, length)
    }
}

/// Pure parser for the `NET_RT_IFLIST2` buffer. Tests inject synthetic bytes and a name
/// resolver, so they never call `sysctl` or `if_indextoname`.
enum InterfaceListParser {
    /// Every routing message starts with the same 4-byte prelude (`rt_msghdr`,
    /// `if_msghdr`, `ifa_msghdr` and `ifma_msghdr2` all begin with length, version and
    /// type). Derive the offsets from the SDK type instead of hard-coding byte positions.
    private static let messageLengthOffset = MemoryLayout<if_msghdr>.offset(of: \if_msghdr.ifm_msglen)!
    private static let messageTypeOffset = MemoryLayout<if_msghdr>.offset(of: \if_msghdr.ifm_type)!
    private static let preludeSize = messageTypeOffset + MemoryLayout<UInt8>.size

    static func parse(_ buffer: [UInt8],
                      length: Int,
                      resolveName: (UInt16) -> String? = systemInterfaceName) -> [InterfaceListEntry] {
        var entries: [InterfaceListEntry] = []
        let count = min(length, buffer.count)
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + preludeSize <= count {
                let messageLength = Int(raw.loadUnaligned(
                    fromByteOffset: offset + messageLengthOffset, as: UInt16.self
                ))
                let messageType = raw.loadUnaligned(
                    fromByteOffset: offset + messageTypeOffset, as: UInt8.self
                )
                // A message shorter than the shared prelude cannot be advanced safely;
                // stop instead of reading the next message's bytes as a header.
                guard messageLength >= preludeSize else { break }
                // A truncated tail cannot be advanced either; stop before reading past
                // the buffer.
                guard offset + messageLength <= count else { break }
                // The dump interleaves RTM_NEWADDR and RTM_NEWMADDR2 records, which are
                // shorter than if_msghdr. Skip anything that is not a complete interface
                // record, then advance by the message's own length.
                if Int32(messageType) == RTM_IFINFO2,
                   messageLength >= MemoryLayout<if_msghdr2>.size,
                   offset + MemoryLayout<if_msghdr2>.size <= count {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if let name = resolveName(message.ifm_index) {
                        entries.append(InterfaceListEntry(
                            name: name,
                            mtu: message.ifm_data.ifi_mtu,
                            baudrate: message.ifm_data.ifi_baudrate,
                            inBytes: message.ifm_data.ifi_ibytes,
                            outBytes: message.ifm_data.ifi_obytes
                        ))
                    }
                }
                offset += messageLength
            }
        }
        return entries
    }

    static func systemInterfaceName(index: UInt16) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &buffer) != nil else { return nil }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

/// Throughput from 64-bit interface counters (`NET_RT_IFLIST2`; `getifaddrs` counters are 32-bit and wrap at 4 GB).
public final class NetworkSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: (inBytes: UInt64, outBytes: UInt64, time: Date)?
    private let readTotals: @Sendable () -> (UInt64, UInt64)?
    private let now: @Sendable () -> Date

    /// Virtual interfaces whose traffic is already counted on a physical interface.
    private static let excludedPrefixes = ["lo", "utun", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap"]

    public init() {
        readTotals = Self.totals
        now = { Date() }
    }

    /// Test seam for the first-sample, counter-reset and totals-failure paths.
    init(readTotals: @escaping @Sendable () -> (UInt64, UInt64)?,
         now: @escaping @Sendable () -> Date) {
        self.readTotals = readTotals
        self.now = now
    }

    public func sample() -> NetworkReading? {
        guard let (i, o) = readTotals() else { return nil }
        let now = now()
        return lock.withLock {
            defer { previous = (i, o, now) }
            return Self.reading(previous: previous, current: (i, o), now: now)
        }
    }

    /// Pure delta calculation. `previous == nil` is the first sample; counters that went
    /// backwards (an interface disappeared) count as zero instead of a huge spike.
    static func reading(previous: (inBytes: UInt64, outBytes: UInt64, time: Date)?,
                        current: (inBytes: UInt64, outBytes: UInt64),
                        now: Date) -> NetworkReading? {
        guard let prev = previous else { return nil }
        let dt = now.timeIntervalSince(prev.time)
        guard dt > 0 else { return nil }
        let di = current.inBytes >= prev.inBytes ? Double(current.inBytes - prev.inBytes) : 0
        let dout = current.outBytes >= prev.outBytes ? Double(current.outBytes - prev.outBytes) : 0
        return NetworkReading(inBytesPerSecond: di / dt, outBytesPerSecond: dout / dt)
    }

    static func totals() -> (UInt64, UInt64)? {
        totals(load: InterfaceListReader.read)
    }

    /// Injectable buffer source so tests can cover the nil/valid buffer boundaries without sysctl.
    static func totals(load: () -> (buffer: [UInt8], length: Int)?,
                       resolveName: (UInt16) -> String? = InterfaceListParser.systemInterfaceName) -> (UInt64, UInt64)? {
        guard let (buffer, length) = load() else { return nil }
        return totals(from: buffer, length: length, resolveName: resolveName)
    }

    /// Keeps the original exclusion prefixes and 64-bit wrapping adds.
    static func totals(from buffer: [UInt8],
                       length: Int,
                       resolveName: (UInt16) -> String? = InterfaceListParser.systemInterfaceName) -> (UInt64, UInt64) {
        let entries = InterfaceListParser.parse(buffer, length: length, resolveName: resolveName)
        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        for entry in entries where !excludedPrefixes.contains(where: entry.name.hasPrefix) {
            totalIn &+= entry.inBytes
            totalOut &+= entry.outBytes
        }
        return (totalIn, totalOut)
    }
}
