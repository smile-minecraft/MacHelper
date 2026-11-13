import Darwin
import Foundation
import SystemConfiguration

/// Local-only network details for the monitor UI.
///
/// Sources: `getifaddrs` (interfaces, addresses, link state), `NET_RT_IFLIST2` (MTU and
/// reported link speed), and SystemConfiguration (interface type and the system's primary
/// interface). None of these touch the network, and none of them prove internet
/// reachability: `systemPrimaryIPv4`/`systemPrimaryIPv6` report what configd says, not a
/// reachability test.
///
/// Every value stays attached to the interface that reported it. A VPN tunnel (`utun*`)
/// never contributes its addresses, MTU or link speed to a physical interface. A
/// link-local IPv6 address can carry IP on the local link; it is not proof of internet
/// reachability, and it is not the same as a globally routable address.
///
/// The sources are read one after another, so a network change during a refresh can make
/// the system primary name refer to an interface that is no longer listed; the next refresh
/// converges. The snapshot is a report, not an atomic cross-source transaction.

// MARK: - Values shown per interface

public struct NetworkInterfaceDetails: Sendable, Hashable, Identifiable {
    public var id: String { name }
    /// BSD interface name, e.g. "en0" or "utun3".
    public var name: String
    /// System-provided display name (e.g. "Wi-Fi"); nil when the system has no friendly name.
    public var displayName: String?
    public var kind: NetworkInterfaceKind
    /// Kernel `IFF_UP` flag at capture time. A listed interface is not necessarily active;
    /// the UI must check `isUp` and `isRunning` before presenting it as connected.
    public var isUp: Bool
    /// Kernel `IFF_RUNNING` flag at capture time.
    public var isRunning: Bool
    /// Addresses reported for this interface. Empty means the system reported none; a failed
    /// `getifaddrs` is represented by the snapshot's `interfaces` being unavailable.
    public var ipv4: [IPv4InterfaceAddress]
    public var ipv6: [IPv6InterfaceAddress]
    /// Reported link speed in bits per second. The kernel reports 0 when it has no value
    /// (tunnels, unconnected adapters), which is surfaced as unavailable, not as 0 bps.
    public var linkSpeedBitsPerSecond: NetworkDetailAvailability<UInt64>
    public var mtu: NetworkDetailAvailability<Int>

    public init(name: String,
                displayName: String?,
                kind: NetworkInterfaceKind,
                isUp: Bool,
                isRunning: Bool,
                ipv4: [IPv4InterfaceAddress],
                ipv6: [IPv6InterfaceAddress],
                linkSpeedBitsPerSecond: NetworkDetailAvailability<UInt64>,
                mtu: NetworkDetailAvailability<Int>) {
        self.name = name
        self.displayName = displayName
        self.kind = kind
        self.isUp = isUp
        self.isRunning = isRunning
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.linkSpeedBitsPerSecond = linkSpeedBitsPerSecond
        self.mtu = mtu
    }
}

public enum NetworkInterfaceKind: String, Sendable, Hashable {
    case wifi
    case ethernet
    case tunnel
    case bridge
    /// The system knows the interface but its type is not one this reader names.
    case other
    /// No system metadata and the BSD name does not identify the kind.
    case unknown
}

public struct IPv4InterfaceAddress: Sendable, Hashable {
    /// Numeric address, e.g. "192.0.2.10".
    public var address: String
    /// Prefix length 0...32; nil when the system did not report a netmask.
    public var prefixLength: Int?
    public var scope: IPv4Scope

    public init(address: String, prefixLength: Int?, scope: IPv4Scope) {
        self.address = address
        self.prefixLength = prefixLength
        self.scope = scope
    }
}

public enum IPv4Scope: String, Sendable, Hashable {
    case loopback
    case linkLocal
    /// 100.64.0.0/10 shared address space (carrier-grade NAT, some VPNs).
    case shared
    case privateNetwork
    case global
}

public struct IPv6InterfaceAddress: Sendable, Hashable {
    /// Numeric, compressed address, e.g. "2001:db8::10".
    public var address: String
    /// Prefix length 0...128; nil when the system did not report a netmask.
    public var prefixLength: Int?
    public var scope: IPv6Scope

    public init(address: String, prefixLength: Int?, scope: IPv6Scope) {
        self.address = address
        self.prefixLength = prefixLength
        self.scope = scope
    }
}

public enum IPv6Scope: String, Sendable, Hashable {
    case loopback
    /// Link-local (fe80::/10): usable for IP on the local link, not routable beyond it.
    case linkLocal
    case uniqueLocal
    case global
    /// A valid address that is not in the ranges above (e.g. IPv4-mapped).
    case other
}

public enum NetworkDetailUnavailableReason: String, Sendable, Hashable {
    /// The system returned no value for this field (e.g. link speed 0 on a tunnel).
    case notReportedBySystem
    /// The system call or configuration source could not be read.
    case readFailed
}

public enum NetworkDetailAvailability<Value: Sendable & Hashable>: Sendable, Hashable {
    case available(Value)
    case unavailable(NetworkDetailUnavailableReason)
}

/// What the system says is the primary interface for an address family.
///
/// This is configuration data, not a reachability test: `.interface` does not prove that
/// the interface can reach the internet. `.none` means the system has no primary interface
/// for that family (offline); `.unknown` means the source could not be read.
public enum PrimaryInterfaceState: Sendable, Hashable {
    case interface(String)
    case none
    case unknown
}

extension PrimaryInterfaceState {
    var interfaceName: String? {
        if case .interface(let name) = self { return name }
        return nil
    }
}

// MARK: - Snapshot

public struct NetworkDetailsSnapshot: Sendable, Hashable {
    public var capturedAt: Date
    /// Interfaces with addresses, plus the system primary.
    ///
    /// A non-primary interface with only link-local IPv6 is included when it is both up and
    /// running and is a physical or tunnel interface; a link-local address can carry local
    /// IP. Interfaces with IPv4 or global/ULA IPv6 may be listed even when they are down, so
    /// the UI must check `isUp`/`isRunning` before calling them active. Apple-internal
    /// interfaces such as `awdl*`, `llw*`, `anpi*`, `ap*` and `nan*` are omitted unless the
    /// system names one primary. `.unavailable(.readFailed)` means `getifaddrs` failed; it
    /// does not mean "no interfaces".
    public var interfaces: NetworkDetailAvailability<[NetworkInterfaceDetails]>
    /// configd's primary IPv4 interface. A tunnel may still carry traffic while configd
    /// names a physical interface; both stay in `interfaces` as separate entries.
    public var systemPrimaryIPv4: PrimaryInterfaceState
    /// configd's primary IPv6 interface, with the same caveat as IPv4.
    public var systemPrimaryIPv6: PrimaryInterfaceState

    public init(capturedAt: Date,
                interfaces: NetworkDetailAvailability<[NetworkInterfaceDetails]>,
                systemPrimaryIPv4: PrimaryInterfaceState,
                systemPrimaryIPv6: PrimaryInterfaceState) {
        self.capturedAt = capturedAt
        self.interfaces = interfaces
        self.systemPrimaryIPv4 = systemPrimaryIPv4
        self.systemPrimaryIPv6 = systemPrimaryIPv6
    }

    /// Details for one interface, if it passed the inclusion rules.
    public func interface(named name: String) -> NetworkInterfaceDetails? {
        guard case .available(let list) = interfaces else { return nil }
        return list.first { $0.name == name }
    }
}

// MARK: - Sampling

public protocol NetworkDetailsProviding: Sendable {
    func read(at date: Date) -> NetworkDetailsSnapshot
}

/// Reads the local system once per call. It performs no network I/O and starts no timer.
public struct SystemNetworkDetailsProvider: NetworkDetailsProviding {
    public init() {}

    public func read(at date: Date) -> NetworkDetailsSnapshot {
        NetworkDetailsBuilder.build(SystemNetworkStateReader.read(), at: date)
    }
}

/// Caches one snapshot so a view can ask for details on every render without repeating
/// `getifaddrs`, `sysctl` and SystemConfiguration queries. The caller decides when to
/// sample; `refresh()` is for network-change events. No background timer is created.
///
/// The sampler is thread-safe. Call `snapshot()` from a background task: the first call
/// performs the local reads, later calls inside `minimumRefreshInterval` return the cache.
/// Example: create one sampler, call `snapshot()` from `Task.detached(priority: .utility)`,
/// and call `refresh()` after a network-change event. No timer is started here.
public final class NetworkDetailsSampler: @unchecked Sendable {
    /// Repeated `snapshot()` calls inside this interval return the cache. The default is
    /// 15 seconds: fast enough for a menu-bar refresh, slow enough to keep the local
    /// `getifaddrs`/`sysctl`/SystemConfiguration reads off a per-second path.
    public static let minimumRefreshInterval: TimeInterval = 15

    private let provider: any NetworkDetailsProviding
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cached: NetworkDetailsSnapshot?

    public init(provider: any NetworkDetailsProviding = SystemNetworkDetailsProvider(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    /// Returns the cached snapshot while it is younger than `minimumRefreshInterval`;
    /// otherwise reads the system. A clock that moved backwards also triggers a read.
    public func snapshot() -> NetworkDetailsSnapshot {
        lock.withLock {
            let date = now()
            if let cached, date >= cached.capturedAt,
               date.timeIntervalSince(cached.capturedAt) < Self.minimumRefreshInterval {
                return cached
            }
            return readLocked(at: date)
        }
    }

    /// Reads the system regardless of the cache, e.g. after a network-change notification.
    public func refresh() -> NetworkDetailsSnapshot {
        lock.withLock { readLocked(at: now()) }
    }

    private func readLocked(at date: Date) -> NetworkDetailsSnapshot {
        let fresh = provider.read(at: date)
        cached = fresh
        return fresh
    }
}

// MARK: - Raw system data (the injectable boundary)

enum RawAddressFamily: Sendable, Hashable {
    case ipv4
    case ipv6
}

struct RawAddress: Sendable, Hashable {
    var interfaceName: String
    var family: RawAddressFamily
    var bytes: [UInt8]
    var prefixLength: Int?
}

struct RawInterface: Sendable, Hashable {
    var name: String
    var flags: UInt32
}

struct RawInterfaceTable: Sendable, Hashable {
    var interfaces: [RawInterface]
    var addresses: [RawAddress]
}

struct RawLinkMetrics: Sendable, Hashable {
    var mtu: UInt32
    var baudrate: UInt64
}

struct RawInterfaceMetadata: Sendable, Hashable {
    var type: String?
    var displayName: String?
}

/// Everything one refresh needs, split by source so a failed source stays distinguishable
/// from an empty one. Tests inject this structure instead of touching the real system.
struct SystemNetworkState: Sendable {
    /// nil when `getifaddrs` failed.
    var interfaceTable: RawInterfaceTable?
    /// nil when `NET_RT_IFLIST2` failed; a missing key means the kernel did not report
    /// metrics for that interface.
    var linkMetrics: [String: RawLinkMetrics]?
    var metadata: [String: RawInterfaceMetadata]
    var systemPrimaryIPv4: PrimaryInterfaceState
    var systemPrimaryIPv6: PrimaryInterfaceState
}

// MARK: - Pure parsing and classification

enum NetworkDetailsParsing {
    /// Counts leading one bits. Returns nil for a non-contiguous mask.
    static func prefixLength(netmaskBytes: [UInt8]) -> Int? {
        guard !netmaskBytes.isEmpty else { return nil }
        var sawZero = false
        var count = 0
        for byte in netmaskBytes {
            for bit in stride(from: 7, through: 0, by: -1) {
                if (byte >> bit) & 1 == 1 {
                    if sawZero { return nil }
                    count += 1
                } else {
                    sawZero = true
                }
            }
        }
        return count
    }

    /// nil for unspecified and multicast IPv4 ranges that are not host addresses.
    static func ipv4Scope(_ bytes: [UInt8]) -> IPv4Scope? {
        guard bytes.count == 4 else { return nil }
        let first = bytes[0]
        if first == 0 || first >= 224 { return nil }
        if first == 127 { return .loopback }
        if first == 169 && bytes[1] == 254 { return .linkLocal }
        if first == 100 && (64...127).contains(bytes[1]) { return .shared }
        if first == 10 { return .privateNetwork }
        if first == 172 && (16...31).contains(bytes[1]) { return .privateNetwork }
        if first == 192 && bytes[1] == 168 { return .privateNetwork }
        return .global
    }

    /// nil for unspecified and multicast IPv6 addresses.
    static func ipv6Scope(_ bytes: [UInt8]) -> IPv6Scope? {
        guard bytes.count == 16 else { return nil }
        if bytes.allSatisfy({ $0 == 0 }) { return nil }
        if bytes[0...14].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .loopback }
        if bytes[0] == 0xff { return nil }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return .linkLocal }
        if (bytes[0] & 0xfe) == 0xfc { return .uniqueLocal }
        if (bytes[0] & 0xe0) == 0x20 { return .global }
        return .other
    }

    static func addressString(_ family: RawAddressFamily, _ bytes: [UInt8]) -> String? {
        switch family {
        case .ipv4:
            guard bytes.count == 4 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let result = bytes.withUnsafeBytes {
                inet_ntop(AF_INET, $0.baseAddress, &buffer, socklen_t(buffer.count))
            }
            guard result != nil else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                          as: UTF8.self)
        case .ipv6:
            guard bytes.count == 16 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let result = bytes.withUnsafeBytes {
                inet_ntop(AF_INET6, $0.baseAddress, &buffer, socklen_t(buffer.count))
            }
            guard result != nil else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                          as: UTF8.self)
        }
    }
}

// MARK: - Build a snapshot from raw data

enum NetworkDetailsBuilder {
    static func build(_ state: SystemNetworkState, at date: Date) -> NetworkDetailsSnapshot {
        let primaryNames = Set(
            [state.systemPrimaryIPv4.interfaceName, state.systemPrimaryIPv6.interfaceName]
                .compactMap { $0 }
        )
        guard let table = state.interfaceTable else {
            return NetworkDetailsSnapshot(
                capturedAt: date,
                interfaces: .unavailable(.readFailed),
                systemPrimaryIPv4: state.systemPrimaryIPv4,
                systemPrimaryIPv6: state.systemPrimaryIPv6
            )
        }

        let addressesByInterface = Dictionary(grouping: table.addresses, by: \.interfaceName)
        let details = table.interfaces.compactMap { interface -> NetworkInterfaceDetails? in
            let rawAddresses = addressesByInterface[interface.name] ?? []
            let ipv4 = sortedIPv4(rawAddresses.compactMap(makeIPv4))
            let ipv6 = sortedIPv6(rawAddresses.compactMap(makeIPv6))
            let isPrimary = primaryNames.contains(interface.name)
            let metadata = state.metadata[interface.name]
            let interfaceKind = kind(for: interface.name, metadata: metadata)
            guard shouldInclude(interface, kind: interfaceKind, ipv4: ipv4, ipv6: ipv6, isPrimary: isPrimary) else {
                return nil
            }
            return NetworkInterfaceDetails(
                name: interface.name,
                displayName: metadata?.displayName,
                kind: interfaceKind,
                isUp: interface.flags & UInt32(IFF_UP) != 0,
                isRunning: interface.flags & UInt32(IFF_RUNNING) != 0,
                ipv4: ipv4,
                ipv6: ipv6,
                linkSpeedBitsPerSecond: linkSpeed(for: interface.name, metrics: state.linkMetrics),
                mtu: mtu(for: interface.name, metrics: state.linkMetrics)
            )
        }.sorted { $0.name < $1.name }

        return NetworkDetailsSnapshot(
            capturedAt: date,
            interfaces: .available(details),
            systemPrimaryIPv4: state.systemPrimaryIPv4,
            systemPrimaryIPv6: state.systemPrimaryIPv6
        )
    }

    /// Apple-internal interfaces that do not represent a user connection. `utun` and
    /// `bridge` are deliberately absent: they can be VPNs or user-visible bridges.
    private static let internalInterfacePrefixes = ["awdl", "llw", "anpi", "ap", "nan"]

    /// Keeps interfaces that carry addresses or are the system primary. A link-local-only
    /// interface is included only when it is up, running and physical/tunnel; link-local
    /// IPv6 can carry IP on the local link. Interfaces with IPv4 or global/ULA IPv6 may be
    /// down, but their `isUp`/`isRunning` flags stay honest for the UI.
    private static func shouldInclude(_ interface: RawInterface,
                                      kind: NetworkInterfaceKind,
                                      ipv4: [IPv4InterfaceAddress],
                                      ipv6: [IPv6InterfaceAddress],
                                      isPrimary: Bool) -> Bool {
        if interface.flags & UInt32(IFF_LOOPBACK) != 0 { return false }
        if isPrimary { return true }
        if internalInterfacePrefixes.contains(where: interface.name.hasPrefix) { return false }
        if !ipv4.isEmpty { return true }
        if ipv6.contains(where: { $0.scope == .global || $0.scope == .uniqueLocal }) { return true }

        let hasLinkLocalIPv6 = ipv6.contains { $0.scope == .linkLocal }
        let isUp = interface.flags & UInt32(IFF_UP) != 0
        let isRunning = interface.flags & UInt32(IFF_RUNNING) != 0
        guard hasLinkLocalIPv6, isUp, isRunning else { return false }
        return kind == .wifi || kind == .ethernet || kind == .tunnel
            || interface.name.hasPrefix("en")
            || interface.name.hasPrefix("utun")
            || interface.name.hasPrefix("tun")
            || interface.name.hasPrefix("tap")
            || interface.name.hasPrefix("ppp")
            || interface.name.hasPrefix("ipsec")
    }

    private static func makeIPv4(_ raw: RawAddress) -> IPv4InterfaceAddress? {
        guard raw.family == .ipv4,
              let address = NetworkDetailsParsing.addressString(.ipv4, raw.bytes),
              let scope = NetworkDetailsParsing.ipv4Scope(raw.bytes)
        else { return nil }
        return IPv4InterfaceAddress(
            address: address,
            prefixLength: raw.prefixLength.map { min(max($0, 0), 32) },
            scope: scope
        )
    }

    private static func makeIPv6(_ raw: RawAddress) -> IPv6InterfaceAddress? {
        guard raw.family == .ipv6,
              let address = NetworkDetailsParsing.addressString(.ipv6, raw.bytes),
              let scope = NetworkDetailsParsing.ipv6Scope(raw.bytes)
        else { return nil }
        return IPv6InterfaceAddress(
            address: address,
            prefixLength: raw.prefixLength.map { min(max($0, 0), 128) },
            scope: scope
        )
    }

    private static func sortedIPv4(_ addresses: [IPv4InterfaceAddress]) -> [IPv4InterfaceAddress] {
        Set(addresses).sorted { a, b in
            if a.scope.sortRank != b.scope.sortRank { return a.scope.sortRank < b.scope.sortRank }
            return a.address < b.address
        }
    }

    private static func sortedIPv6(_ addresses: [IPv6InterfaceAddress]) -> [IPv6InterfaceAddress] {
        Set(addresses).sorted { a, b in
            if a.scope.sortRank != b.scope.sortRank { return a.scope.sortRank < b.scope.sortRank }
            return a.address < b.address
        }
    }

    static func kind(for name: String, metadata: RawInterfaceMetadata?) -> NetworkInterfaceKind {
        if let type = metadata?.type {
            // Compare the SystemConfiguration constants, not hand-written spellings: the
            // IPSec constant is "IPSec", not "IPSEC".
            if type == kSCNetworkInterfaceTypeIEEE80211 as String { return .wifi }
            if type == kSCNetworkInterfaceTypeEthernet as String { return .ethernet }
            // SystemConfiguration has no public Bridge constant; the reported type is "Bridge".
            if type == "Bridge" { return .bridge }
            // PPTP's SystemConfiguration constant is deprecated; keep the reported string.
            if type == kSCNetworkInterfaceTypePPP as String
                || type == kSCNetworkInterfaceTypeIPSec as String
                || type == kSCNetworkInterfaceTypeL2TP as String
                || type == kSCNetworkInterfaceType6to4 as String
                || type == "PPTP" {
                return .tunnel
            }
            return .other
        }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
            || name.hasPrefix("tun") || name.hasPrefix("tap") {
            return .tunnel
        }
        if name.hasPrefix("bridge") { return .bridge }
        return .unknown
    }

    private static func linkSpeed(for name: String,
                                  metrics: [String: RawLinkMetrics]?) -> NetworkDetailAvailability<UInt64> {
        guard let metrics else { return .unavailable(.readFailed) }
        guard let metric = metrics[name] else { return .unavailable(.notReportedBySystem) }
        return metric.baudrate > 0 ? .available(metric.baudrate) : .unavailable(.notReportedBySystem)
    }

    private static func mtu(for name: String,
                            metrics: [String: RawLinkMetrics]?) -> NetworkDetailAvailability<Int> {
        guard let metrics else { return .unavailable(.readFailed) }
        guard let metric = metrics[name] else { return .unavailable(.notReportedBySystem) }
        return metric.mtu > 0 ? .available(Int(metric.mtu)) : .unavailable(.notReportedBySystem)
    }
}

private extension IPv4Scope {
    var sortRank: Int {
        switch self {
        case .global: 0
        case .privateNetwork: 1
        case .shared: 2
        case .linkLocal: 3
        case .loopback: 4
        }
    }
}

private extension IPv6Scope {
    var sortRank: Int {
        switch self {
        case .global: 0
        case .uniqueLocal: 1
        case .linkLocal: 2
        case .other: 3
        case .loopback: 4
        }
    }
}

// MARK: - Real system sources

enum SystemNetworkStateReader {
    static func read() -> SystemNetworkState {
        let table = readInterfaceTable()
        let metrics = readLinkMetrics()
        let metadata = readMetadata()
        let store = SCDynamicStoreCreate(nil, "MacHelper.NetworkDetails" as CFString, nil, nil)
        return SystemNetworkState(
            interfaceTable: table,
            linkMetrics: metrics,
            metadata: metadata,
            systemPrimaryIPv4: readPrimaryInterface(store: store, key: "State:/Network/Global/IPv4"),
            systemPrimaryIPv6: readPrimaryInterface(store: store, key: "State:/Network/Global/IPv6")
        )
    }

    /// Pure part of the primary-interface read, so tests can cover malformed values.
    static func primaryState(from value: Any) -> PrimaryInterfaceState {
        guard let dictionary = value as? [String: Any] else { return .unknown }
        guard let name = dictionary["PrimaryInterface"] as? String, !name.isEmpty else {
            return .unknown
        }
        return .interface(name)
    }

    /// `SCDynamicStoreCopyValue` returns nil for a missing key and for a failed query.
    /// `SCError` tells them apart: a missing key means the system has no primary interface.
    static func missingPrimaryState(error: Int) -> PrimaryInterfaceState {
        error == kSCStatusNoKey ? .none : .unknown
    }

    private static func readPrimaryInterface(store: SCDynamicStore?,
                                             key: String) -> PrimaryInterfaceState {
        guard let store else { return .unknown }
        guard let value = SCDynamicStoreCopyValue(store, key as CFString) else {
            return missingPrimaryState(error: Int(SCError()))
        }
        return primaryState(from: value)
    }

    private static func readInterfaceTable() -> RawInterfaceTable? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }

        var interfaces: [String: UInt32] = [:]
        var addresses: [RawAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let ifa = current.pointee
            cursor = ifa.ifa_next
            let name = String(cString: ifa.ifa_name)
            interfaces[name] = UInt32(ifa.ifa_flags)
            guard let address = ifa.ifa_addr else { continue }
            if let raw = rawAddress(interfaceName: name, address: address, netmask: ifa.ifa_netmask) {
                addresses.append(raw)
            }
        }

        return RawInterfaceTable(
            interfaces: interfaces.map { RawInterface(name: $0.key, flags: $0.value) },
            addresses: addresses
        )
    }

    /// Pure sockaddr-to-raw-address conversion, separated so tests can feed synthetic
    /// `sockaddr_in`/`sockaddr_in6` values without calling `getifaddrs`.
    static func rawAddress(interfaceName: String,
                           address: UnsafePointer<sockaddr>,
                           netmask: UnsafePointer<sockaddr>?) -> RawAddress? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            let sin = UnsafeRawPointer(address).loadUnaligned(as: sockaddr_in.self)
            return RawAddress(
                interfaceName: interfaceName,
                family: .ipv4,
                bytes: withUnsafeBytes(of: sin.sin_addr) { Array($0) },
                prefixLength: netmask.flatMap { netmaskPrefix($0, family: .ipv4) }
            )
        case AF_INET6:
            let sin6 = UnsafeRawPointer(address).loadUnaligned(as: sockaddr_in6.self)
            return RawAddress(
                interfaceName: interfaceName,
                family: .ipv6,
                bytes: withUnsafeBytes(of: sin6.sin6_addr) { Array($0) },
                prefixLength: netmask.flatMap { netmaskPrefix($0, family: .ipv6) }
            )
        default:
            return nil
        }
    }

    private static func netmaskPrefix(_ netmask: UnsafePointer<sockaddr>,
                                      family: RawAddressFamily) -> Int? {
        switch family {
        case .ipv4:
            let sin = UnsafeRawPointer(netmask).loadUnaligned(as: sockaddr_in.self)
            guard Int32(sin.sin_family) == AF_INET else { return nil }
            return NetworkDetailsParsing.prefixLength(
                netmaskBytes: withUnsafeBytes(of: sin.sin_addr) { Array($0) }
            )
        case .ipv6:
            let sin6 = UnsafeRawPointer(netmask).loadUnaligned(as: sockaddr_in6.self)
            guard Int32(sin6.sin6_family) == AF_INET6 else { return nil }
            return NetworkDetailsParsing.prefixLength(
                netmaskBytes: withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
            )
        }
    }

    /// Injectable loader and name resolver so tests can use synthetic `NET_RT_IFLIST2`
    /// buffers without calling `sysctl` or `if_indextoname`.
    static func readLinkMetrics(load: () -> (buffer: [UInt8], length: Int)? = InterfaceListReader.read,
                                resolveName: (UInt16) -> String? = InterfaceListParser.systemInterfaceName) -> [String: RawLinkMetrics]? {
        guard let (buffer, length) = load() else { return nil }
        return linkMetrics(from: buffer, length: length, resolveName: resolveName)
    }

    static func linkMetrics(from buffer: [UInt8],
                            length: Int,
                            resolveName: (UInt16) -> String? = InterfaceListParser.systemInterfaceName) -> [String: RawLinkMetrics] {
        var metrics: [String: RawLinkMetrics] = [:]
        for entry in InterfaceListParser.parse(buffer, length: length, resolveName: resolveName) {
            metrics[entry.name] = RawLinkMetrics(mtu: entry.mtu, baudrate: entry.baudrate)
        }
        return metrics
    }

    private static func readMetadata() -> [String: RawInterfaceMetadata] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return [:]
        }
        var metadata: [String: RawInterfaceMetadata] = [:]
        for interface in interfaces {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            metadata[name] = RawInterfaceMetadata(
                type: SCNetworkInterfaceGetInterfaceType(interface) as String?,
                displayName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            )
        }
        return metadata
    }
}
