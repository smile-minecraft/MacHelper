import Darwin
import Foundation
import SystemConfiguration
import Testing
@testable import Metrics

private let testDate = Date(timeIntervalSince1970: 1_000)

private let wifiMetadata = RawInterfaceMetadata(type: "IEEE80211", displayName: "Wi-Fi")
private let ethernetMetadata = RawInterfaceMetadata(type: "Ethernet", displayName: "Ethernet")

private let globalIPv6: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10]
private let linkLocalIPv6: [UInt8] = [0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
private let uniqueLocalIPv6: [UInt8] = [0xfd, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
private let loopbackIPv6: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
private let multicastIPv6: [UInt8] = [0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]

private func rawInterface(_ name: String,
                          flags: UInt32 = UInt32(IFF_UP | IFF_RUNNING)) -> RawInterface {
    RawInterface(name: name, flags: flags)
}

private func rawIPv4(_ name: String, _ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8,
                     prefix: Int? = 24) -> RawAddress {
    RawAddress(interfaceName: name, family: .ipv4, bytes: [a, b, c, d], prefixLength: prefix)
}

private func rawIPv6(_ name: String, _ bytes: [UInt8], prefix: Int? = 64) -> RawAddress {
    RawAddress(interfaceName: name, family: .ipv6, bytes: bytes, prefixLength: prefix)
}

private func makeState(
    interfaces: [RawInterface],
    addresses: [RawAddress],
    metadata: [String: RawInterfaceMetadata] = [:],
    linkMetrics: [String: RawLinkMetrics]? = [:],
    primary4: PrimaryInterfaceState = .none,
    primary6: PrimaryInterfaceState = .none
) -> SystemNetworkState {
    SystemNetworkState(
        interfaceTable: RawInterfaceTable(interfaces: interfaces, addresses: addresses),
        linkMetrics: linkMetrics,
        metadata: metadata,
        systemPrimaryIPv4: primary4,
        systemPrimaryIPv6: primary6
    )
}

private func makeSnapshot(primary4: PrimaryInterfaceState,
                          primary6: PrimaryInterfaceState = .none) -> NetworkDetailsSnapshot {
    let state = makeState(
        interfaces: [rawInterface("en0"), rawInterface("en5")],
        addresses: [
            rawIPv4("en0", 192, 0, 2, 10),
            rawIPv4("en5", 198, 51, 100, 20),
        ],
        metadata: ["en0": wifiMetadata, "en5": ethernetMetadata],
        linkMetrics: [
            "en0": RawLinkMetrics(mtu: 1500, baudrate: 1_000_000_000),
            "en5": RawLinkMetrics(mtu: 1500, baudrate: 2_500_000_000),
        ],
        primary4: primary4,
        primary6: primary6
    )
    return NetworkDetailsBuilder.build(state, at: Date(timeIntervalSince1970: 0))
}

/// Synthetic `NET_RT_IFLIST2` message. The name resolver is injected by each test, so no
/// test calls `sysctl` or `if_indextoname`.
private func interfaceMessage(index: UInt16,
                              mtu: UInt32 = 1500,
                              baudrate: UInt64 = 0,
                              inBytes: UInt64 = 0,
                              outBytes: UInt64 = 0,
                              type: UInt8 = UInt8(RTM_IFINFO2),
                              declaredLength: UInt16? = nil) -> [UInt8] {
    var message = if_msghdr2()
    message.ifm_msglen = declaredLength ?? UInt16(MemoryLayout<if_msghdr2>.size)
    message.ifm_version = UInt8(RTM_VERSION)
    message.ifm_type = type
    message.ifm_index = index
    message.ifm_data.ifi_mtu = mtu
    message.ifm_data.ifi_baudrate = baudrate
    message.ifm_data.ifi_ibytes = inBytes
    message.ifm_data.ifi_obytes = outBytes
    return withUnsafeBytes(of: message) { Array($0) }
}

/// A routing message that is not an interface record (`RTM_NEWADDR`, `RTM_NEWMADDR2`).
/// Only the 4-byte prelude matters to the interface parser; the rest is address payload.
private func routingMessage(type: UInt8, byteCount: Int) -> [UInt8] {
    precondition(byteCount >= 4)
    var message = [UInt8](repeating: 0, count: byteCount)
    message.withUnsafeMutableBytes { raw in
        raw.storeBytes(
            of: UInt16(byteCount),
            toByteOffset: MemoryLayout<if_msghdr>.offset(of: \if_msghdr.ifm_msglen)!,
            as: UInt16.self
        )
        raw.storeBytes(
            of: UInt8(RTM_VERSION),
            toByteOffset: MemoryLayout<if_msghdr>.offset(of: \if_msghdr.ifm_version)!,
            as: UInt8.self
        )
        raw.storeBytes(
            of: type,
            toByteOffset: MemoryLayout<if_msghdr>.offset(of: \if_msghdr.ifm_type)!,
            as: UInt8.self
        )
    }
    return message
}

/// A real `RTM_NEWADDR` header padded to the message length macOS reports, which is
/// shorter than `if_msghdr` (112 bytes).
private func ipv4AddressMessage(byteCount: Int = 60, index: UInt16 = 1) -> [UInt8] {
    var message = ifa_msghdr()
    message.ifam_msglen = UInt16(byteCount)
    message.ifam_version = UInt8(RTM_VERSION)
    message.ifam_type = UInt8(RTM_NEWADDR)
    message.ifam_index = index
    var bytes = withUnsafeBytes(of: message) { Array($0) }
    precondition(bytes.count <= byteCount)
    bytes += [UInt8](repeating: 0, count: byteCount - bytes.count)
    return bytes
}

/// A real `RTM_NEWMADDR2` header padded to its reported message length.
private func multicastAddressMessage(byteCount: Int = 56, index: UInt16 = 1) -> [UInt8] {
    var message = ifma_msghdr2()
    message.ifmam_msglen = UInt16(byteCount)
    message.ifmam_version = UInt8(RTM_VERSION)
    message.ifmam_type = UInt8(RTM_NEWMADDR2)
    message.ifmam_index = index
    var bytes = withUnsafeBytes(of: message) { Array($0) }
    precondition(bytes.count <= byteCount)
    bytes += [UInt8](repeating: 0, count: byteCount - bytes.count)
    return bytes
}

private func ipv4Sockaddr(_ bytes: [UInt8]) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: bytes) }
    return address
}

private func ipv6Sockaddr(_ bytes: [UInt8]) -> sockaddr_in6 {
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: bytes) }
    return address
}

private func withSockaddr<T>(_ value: T, _ body: (UnsafePointer<sockaddr>) -> Void) {
    var value = value
    withUnsafePointer(to: &value) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1, body)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) { self.current = current }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private final class TotalsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var totals: (inBytes: UInt64, outBytes: UInt64)

    init(_ totals: (UInt64, UInt64)) { self.totals = totals }

    var value: (UInt64, UInt64) { lock.withLock { totals } }

    func set(_ totals: (UInt64, UInt64)) {
        lock.withLock { self.totals = totals }
    }
}

private final class SequenceProvider: NetworkDetailsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [NetworkDetailsSnapshot]
    private var index = 0
    private var reads = 0

    init(_ snapshots: [NetworkDetailsSnapshot]) {
        self.snapshots = snapshots
    }

    var readCount: Int { lock.withLock { reads } }

    func read(at date: Date) -> NetworkDetailsSnapshot {
        lock.withLock {
            reads += 1
            var snapshot = snapshots[min(index, snapshots.count - 1)]
            index += 1
            snapshot.capturedAt = date
            return snapshot
        }
    }
}

@Suite struct NetworkDetailsTests {
    @Test func buildsPerInterfaceDetailsForIPv4AndIPv6() throws {
        let state = makeState(
            interfaces: [rawInterface("en0")],
            addresses: [
                rawIPv4("en0", 192, 0, 2, 10, prefix: 24),
                rawIPv6("en0", globalIPv6, prefix: 64),
                rawIPv6("en0", linkLocalIPv6, prefix: 64),
            ],
            metadata: ["en0": wifiMetadata],
            linkMetrics: ["en0": RawLinkMetrics(mtu: 1500, baudrate: 1_200_000_000)],
            primary4: .interface("en0"),
            primary6: .interface("en0")
        )

        let snapshot = NetworkDetailsBuilder.build(state, at: testDate)
        guard case .available(let interfaces) = snapshot.interfaces else {
            Issue.record("interface table should be available")
            return
        }
        let en0 = try #require(interfaces.first)

        #expect(interfaces.count == 1)
        #expect(en0.name == "en0")
        #expect(en0.displayName == "Wi-Fi")
        #expect(en0.kind == .wifi)
        #expect(en0.isUp)
        #expect(en0.isRunning)
        #expect(en0.ipv4 == [IPv4InterfaceAddress(address: "192.0.2.10", prefixLength: 24, scope: .global)])
        #expect(en0.ipv6.map(\.address) == ["2001:db8::10", "fe80::1"])
        #expect(en0.ipv6.map(\.scope) == [.global, .linkLocal])
        #expect(en0.linkSpeedBitsPerSecond == .available(1_200_000_000))
        #expect(en0.mtu == .available(1500))
        #expect(snapshot.systemPrimaryIPv4 == .interface("en0"))
        #expect(snapshot.systemPrimaryIPv6 == .interface("en0"))
    }

    @Test func reportsOfflineWithoutInventingInterfaces() {
        let state = makeState(
            interfaces: [rawInterface("en0"), rawInterface("awdl0")],
            addresses: [rawIPv6("awdl0", linkLocalIPv6)],
            metadata: ["en0": wifiMetadata],
            linkMetrics: ["en0": RawLinkMetrics(mtu: 1500, baudrate: 0)]
        )

        let snapshot = NetworkDetailsBuilder.build(state, at: testDate)

        #expect(snapshot.interfaces == .available([]))
        #expect(snapshot.systemPrimaryIPv4 == .none)
        #expect(snapshot.systemPrimaryIPv6 == .none)
    }

    @Test func reportsIPv6OnlyNetworkWithoutInventingIPv4() throws {
        let state = makeState(
            interfaces: [rawInterface("en0")],
            addresses: [rawIPv6("en0", globalIPv6)],
            metadata: ["en0": wifiMetadata],
            linkMetrics: ["en0": RawLinkMetrics(mtu: 1500, baudrate: 1_000_000_000)],
            primary6: .interface("en0")
        )

        let snapshot = NetworkDetailsBuilder.build(state, at: testDate)
        let en0 = try #require(snapshot.interface(named: "en0"))

        #expect(snapshot.systemPrimaryIPv4 == .none)
        #expect(snapshot.systemPrimaryIPv6 == .interface("en0"))
        #expect(en0.ipv4.isEmpty)
        #expect(en0.ipv6.map(\.scope) == [.global])
    }

    @Test func keepsInterfacesSeparateWhenTheSystemSwitchesPrimary() throws {
        let state = makeState(
            interfaces: [rawInterface("en0"), rawInterface("en5"), rawInterface("utun3")],
            addresses: [
                rawIPv4("en0", 192, 0, 2, 10),
                rawIPv6("en0", globalIPv6),
                rawIPv4("en5", 198, 51, 100, 20),
                rawIPv4("utun3", 10, 8, 0, 2, prefix: 32),
            ],
            metadata: ["en0": wifiMetadata, "en5": ethernetMetadata],
            linkMetrics: [
                "en0": RawLinkMetrics(mtu: 1500, baudrate: 1_200_000_000),
                "en5": RawLinkMetrics(mtu: 1500, baudrate: 2_500_000_000),
                "utun3": RawLinkMetrics(mtu: 1420, baudrate: 0),
            ],
            primary4: .interface("en5"),
            primary6: .interface("en0")
        )

        let snapshot = NetworkDetailsBuilder.build(state, at: testDate)
        guard case .available(let interfaces) = snapshot.interfaces else {
            Issue.record("interface table should be available")
            return
        }
        #expect(interfaces.map(\.name) == ["en0", "en5", "utun3"])

        let en0 = try #require(snapshot.interface(named: "en0"))
        #expect(en0.ipv4.map(\.address) == ["192.0.2.10"])
        #expect(en0.linkSpeedBitsPerSecond == .available(1_200_000_000))

        let en5 = try #require(snapshot.interface(named: "en5"))
        #expect(en5.ipv4.map(\.address) == ["198.51.100.20"])
        #expect(en5.linkSpeedBitsPerSecond == .available(2_500_000_000))

        let vpn = try #require(snapshot.interface(named: "utun3"))
        #expect(vpn.kind == .tunnel)
        #expect(vpn.linkSpeedBitsPerSecond == .unavailable(.notReportedBySystem))
        #expect(vpn.mtu == .available(1420))

        #expect(snapshot.systemPrimaryIPv4 == .interface("en5"))
        #expect(snapshot.systemPrimaryIPv6 == .interface("en0"))
    }

    @Test func vpnTunnelKeepsItsOwnAttributes() throws {
        let state = makeState(
            interfaces: [rawInterface("en0"), rawInterface("utun3")],
            addresses: [
                rawIPv4("en0", 192, 0, 2, 10),
                rawIPv6("en0", globalIPv6),
                rawIPv4("utun3", 10, 8, 0, 2, prefix: 32),
            ],
            metadata: ["en0": wifiMetadata],
            linkMetrics: [
                "en0": RawLinkMetrics(mtu: 1500, baudrate: 1_000_000_000),
                "utun3": RawLinkMetrics(mtu: 1420, baudrate: 0),
            ],
            primary4: .interface("utun3"),
            primary6: .interface("en0")
        )

        let snapshot = NetworkDetailsBuilder.build(state, at: testDate)
        let vpn = try #require(snapshot.interface(named: "utun3"))
        let wifi = try #require(snapshot.interface(named: "en0"))

        #expect(vpn.kind == .tunnel)
        #expect(vpn.displayName == nil)
        #expect(vpn.ipv4.map(\.address) == ["10.8.0.2"])
        #expect(vpn.ipv6.isEmpty)
        #expect(vpn.linkSpeedBitsPerSecond == .unavailable(.notReportedBySystem))
        #expect(vpn.mtu == .available(1420))

        #expect(wifi.kind == .wifi)
        #expect(wifi.ipv4.map(\.address) == ["192.0.2.10"])
        #expect(wifi.ipv6.map(\.address) == ["2001:db8::10"])
        #expect(wifi.linkSpeedBitsPerSecond == .available(1_000_000_000))
        #expect(snapshot.systemPrimaryIPv4 == .interface("utun3"))
    }

    @Test func distinguishesMissingSourcesFromMissingValues() throws {
        let noTable = SystemNetworkState(
            interfaceTable: nil,
            linkMetrics: nil,
            metadata: [:],
            systemPrimaryIPv4: .interface("en0"),
            systemPrimaryIPv6: .unknown
        )
        let failed = NetworkDetailsBuilder.build(noTable, at: testDate)
        #expect(failed.interfaces == .unavailable(.readFailed))
        #expect(failed.interface(named: "en0") == nil)
        #expect(failed.systemPrimaryIPv4 == .interface("en0"))
        #expect(failed.systemPrimaryIPv6 == .unknown)

        let noMetrics = makeState(
            interfaces: [rawInterface("en0")],
            addresses: [rawIPv4("en0", 192, 0, 2, 10)],
            metadata: ["en0": wifiMetadata],
            linkMetrics: nil
        )
        let missing = try #require(
            NetworkDetailsBuilder.build(noMetrics, at: testDate).interface(named: "en0")
        )
        #expect(missing.linkSpeedBitsPerSecond == .unavailable(.readFailed))
        #expect(missing.mtu == .unavailable(.readFailed))

        let zeroMetrics = makeState(
            interfaces: [rawInterface("en0")],
            addresses: [rawIPv4("en0", 192, 0, 2, 10)],
            metadata: ["en0": wifiMetadata],
            linkMetrics: ["en0": RawLinkMetrics(mtu: 0, baudrate: 0)]
        )
        let zero = try #require(
            NetworkDetailsBuilder.build(zeroMetrics, at: testDate).interface(named: "en0")
        )
        #expect(zero.linkSpeedBitsPerSecond == .unavailable(.notReportedBySystem))
        #expect(zero.mtu == .unavailable(.notReportedBySystem))
    }

    @Test func classifiesPrimaryInterfaceStates() {
        #expect(SystemNetworkStateReader.primaryState(from: ["PrimaryInterface": "en0"] as [String: Any])
                == .interface("en0"))
        #expect(SystemNetworkStateReader.primaryState(from: ["PrimaryInterface": ""] as [String: Any])
                == .unknown)
        #expect(SystemNetworkStateReader.primaryState(from: [String: Any]()) == .unknown)
        #expect(SystemNetworkStateReader.primaryState(from: "not a dictionary") == .unknown)

        #expect(SystemNetworkStateReader.missingPrimaryState(error: kSCStatusNoKey) == .none)
        #expect(SystemNetworkStateReader.missingPrimaryState(error: kSCStatusOK) == .unknown)
        #expect(SystemNetworkStateReader.missingPrimaryState(error: 1) == .unknown)
    }

    @Test func parsesPrefixLengths() {
        #expect(NetworkDetailsParsing.prefixLength(netmaskBytes: [255, 255, 255, 0]) == 24)
        #expect(NetworkDetailsParsing.prefixLength(netmaskBytes: [255, 255, 255, 255]) == 32)
        #expect(NetworkDetailsParsing.prefixLength(netmaskBytes: [0, 0, 0, 0]) == 0)
        #expect(NetworkDetailsParsing.prefixLength(netmaskBytes: [255, 0, 255, 0]) == nil)
        #expect(NetworkDetailsParsing.prefixLength(
            netmaskBytes: Array(repeating: UInt8(0xff), count: 8) + Array(repeating: UInt8(0), count: 8)
        ) == 64)
        #expect(NetworkDetailsParsing.prefixLength(
            netmaskBytes: Array(repeating: UInt8(0xff), count: 16)
        ) == 128)
        #expect(NetworkDetailsParsing.prefixLength(netmaskBytes: []) == nil)
    }

    @Test func classifiesAddressScopesAndFormatsAddresses() {
        #expect(NetworkDetailsParsing.ipv4Scope([127, 0, 0, 1]) == .loopback)
        #expect(NetworkDetailsParsing.ipv4Scope([169, 254, 10, 20]) == .linkLocal)
        #expect(NetworkDetailsParsing.ipv4Scope([100, 64, 0, 1]) == .shared)
        #expect(NetworkDetailsParsing.ipv4Scope([100, 128, 0, 1]) == .global)
        #expect(NetworkDetailsParsing.ipv4Scope([10, 1, 2, 3]) == .privateNetwork)
        #expect(NetworkDetailsParsing.ipv4Scope([172, 16, 0, 1]) == .privateNetwork)
        #expect(NetworkDetailsParsing.ipv4Scope([172, 32, 0, 1]) == .global)
        #expect(NetworkDetailsParsing.ipv4Scope([192, 168, 1, 1]) == .privateNetwork)
        #expect(NetworkDetailsParsing.ipv4Scope([203, 0, 113, 1]) == .global)
        #expect(NetworkDetailsParsing.ipv4Scope([224, 0, 0, 1]) == nil)
        #expect(NetworkDetailsParsing.ipv4Scope([0, 0, 0, 0]) == nil)

        #expect(NetworkDetailsParsing.ipv6Scope(loopbackIPv6) == .loopback)
        #expect(NetworkDetailsParsing.ipv6Scope(linkLocalIPv6) == .linkLocal)
        #expect(NetworkDetailsParsing.ipv6Scope(uniqueLocalIPv6) == .uniqueLocal)
        #expect(NetworkDetailsParsing.ipv6Scope(globalIPv6) == .global)
        #expect(NetworkDetailsParsing.ipv6Scope(multicastIPv6) == nil)
        #expect(NetworkDetailsParsing.ipv6Scope(Array(repeating: UInt8(0), count: 16)) == nil)

        #expect(NetworkDetailsParsing.addressString(.ipv4, [192, 0, 2, 10]) == "192.0.2.10")
        #expect(NetworkDetailsParsing.addressString(.ipv6, globalIPv6) == "2001:db8::10")
        #expect(NetworkDetailsParsing.addressString(.ipv4, [1, 2, 3]) == nil)
    }

    @Test func keepsMultipleAddressesOnOneInterface() throws {
        let state = makeState(
            interfaces: [rawInterface("en0")],
            addresses: [
                rawIPv4("en0", 192, 0, 2, 10),
                rawIPv4("en0", 192, 0, 2, 11),
                rawIPv6("en0", globalIPv6),
            ],
            metadata: ["en0": wifiMetadata],
            linkMetrics: ["en0": RawLinkMetrics(mtu: 1500, baudrate: 1_000_000_000)]
        )

        let en0 = try #require(
            NetworkDetailsBuilder.build(state, at: testDate).interface(named: "en0")
        )
        #expect(en0.ipv4.map(\.address) == ["192.0.2.10", "192.0.2.11"])
    }

    @Test func doesNotFabricateAnInterfaceForAMissingPrimary() {
        let state = makeState(
            interfaces: [rawInterface("en0")],
            addresses: [rawIPv4("en0", 192, 0, 2, 10)],
            metadata: ["en0": wifiMetadata],
            linkMetrics: ["en0": RawLinkMetrics(mtu: 1500, baudrate: 1_000_000_000)],
            primary4: .interface("en9")
        )

        let snapshot = NetworkDetailsBuilder.build(state, at: testDate)
        #expect(snapshot.interface(named: "en9") == nil)
        #expect(snapshot.systemPrimaryIPv4 == .interface("en9"))
    }

    @Test func includesSelfAssignedIPv4ButExcludesLoopbackAndInternalLinkLocal() throws {
        let state = makeState(
            interfaces: [
                rawInterface("lo0", flags: UInt32(IFF_UP | IFF_RUNNING | IFF_LOOPBACK)),
                rawInterface("awdl0"),
                rawInterface("en0"),
            ],
            addresses: [
                rawIPv4("lo0", 127, 0, 0, 1, prefix: 8),
                rawIPv6("lo0", loopbackIPv6, prefix: 128),
                rawIPv6("awdl0", linkLocalIPv6),
                rawIPv4("en0", 169, 254, 10, 20, prefix: 16),
            ],
            metadata: ["en0": wifiMetadata],
            linkMetrics: ["en0": RawLinkMetrics(mtu: 1500, baudrate: 0)]
        )

        let snapshot = NetworkDetailsBuilder.build(state, at: testDate)
        guard case .available(let interfaces) = snapshot.interfaces else {
            Issue.record("interface table should be available")
            return
        }
        #expect(interfaces.map(\.name) == ["en0"])
        #expect(interfaces.first?.ipv4.first?.scope == .linkLocal)
    }

    @Test func includesLinkLocalOnlyInterfaceWhenPrimary() {
        let state = makeState(
            interfaces: [rawInterface("awdl0")],
            addresses: [rawIPv6("awdl0", linkLocalIPv6)],
            linkMetrics: ["awdl0": RawLinkMetrics(mtu: 1500, baudrate: 0)],
            primary6: .interface("awdl0")
        )

        let snapshot = NetworkDetailsBuilder.build(state, at: testDate)
        #expect(snapshot.interface(named: "awdl0") != nil)
        #expect(snapshot.systemPrimaryIPv6 == .interface("awdl0"))
    }

    @Test func keepsNonPrimaryLinkLocalPhysicalAndTunnelInterfaces() throws {
        let state = makeState(
            interfaces: [rawInterface("en7"), rawInterface("utun5"), rawInterface("awdl0")],
            addresses: [
                rawIPv6("en7", linkLocalIPv6),
                rawIPv6("utun5", linkLocalIPv6),
                rawIPv6("awdl0", linkLocalIPv6),
            ],
            metadata: [:],
            linkMetrics: [:]
        )

        let snapshot = NetworkDetailsBuilder.build(state, at: testDate)
        let en7 = try #require(snapshot.interface(named: "en7"))
        let utun5 = try #require(snapshot.interface(named: "utun5"))

        #expect(snapshot.interface(named: "awdl0") == nil)
        #expect(en7.isUp && en7.isRunning)
        #expect(en7.ipv6.map(\.scope) == [.linkLocal])
        #expect(utun5.kind == .tunnel)
        #expect(utun5.ipv6.map(\.scope) == [.linkLocal])
    }

    @Test func excludesLinkLocalOnlyInterfaceWhenNotUpAndRunning() {
        let runningOnly = makeState(
            interfaces: [rawInterface("en7", flags: UInt32(IFF_RUNNING))],
            addresses: [rawIPv6("en7", linkLocalIPv6)]
        )
        #expect(NetworkDetailsBuilder.build(runningOnly, at: testDate).interface(named: "en7") == nil)

        let upOnly = makeState(
            interfaces: [rawInterface("en7", flags: UInt32(IFF_UP))],
            addresses: [rawIPv6("en7", linkLocalIPv6)]
        )
        #expect(NetworkDetailsBuilder.build(upOnly, at: testDate).interface(named: "en7") == nil)

        let primary = makeState(
            interfaces: [rawInterface("en7", flags: 0)],
            addresses: [rawIPv6("en7", linkLocalIPv6)],
            primary6: .interface("en7")
        )
        let primarySnapshot = NetworkDetailsBuilder.build(primary, at: testDate)
        #expect(primarySnapshot.interface(named: "en7") != nil)
        #expect(primarySnapshot.interface(named: "en7")?.isUp == false)
        #expect(primarySnapshot.interface(named: "en7")?.isRunning == false)
    }

    @Test func includesDownInterfaceWithStaleAddressAndKeepsFlagsHonest() throws {
        let state = makeState(
            interfaces: [rawInterface("en0", flags: 0)],
            addresses: [rawIPv4("en0", 192, 0, 2, 10)],
            metadata: ["en0": wifiMetadata],
            linkMetrics: ["en0": RawLinkMetrics(mtu: 1500, baudrate: 1_000_000_000)]
        )

        let en0 = try #require(
            NetworkDetailsBuilder.build(state, at: testDate).interface(named: "en0")
        )
        #expect(en0.isUp == false)
        #expect(en0.isRunning == false)
        #expect(en0.ipv4.map(\.address) == ["192.0.2.10"])
    }

    @Test func excludesInternalInterfaceEvenWithAddress() {
        let state = makeState(
            interfaces: [rawInterface("awdl0")],
            addresses: [rawIPv4("awdl0", 169, 254, 1, 1)],
            metadata: [:]
        )
        #expect(NetworkDetailsBuilder.build(state, at: testDate).interface(named: "awdl0") == nil)
    }

    @Test func classifiesInterfaceKinds() {
        // Use the actual SystemConfiguration constants so a wrong spelling (e.g. "IPSEC"
        // instead of "IPSec") fails this test. This is the value the system reports.
        #expect(kSCNetworkInterfaceTypeIPSec as String == "IPSec")
        #expect(NetworkDetailsBuilder.kind(
            for: "en0",
            metadata: RawInterfaceMetadata(type: kSCNetworkInterfaceTypeIEEE80211 as String, displayName: "Wi-Fi")
        ) == .wifi)
        #expect(NetworkDetailsBuilder.kind(
            for: "en5",
            metadata: RawInterfaceMetadata(type: kSCNetworkInterfaceTypeEthernet as String, displayName: "Ethernet")
        ) == .ethernet)
        #expect(NetworkDetailsBuilder.kind(
            for: "bridge0", metadata: RawInterfaceMetadata(type: "Bridge", displayName: nil)
        ) == .bridge)
        #expect(NetworkDetailsBuilder.kind(
            for: "ppp0",
            metadata: RawInterfaceMetadata(type: kSCNetworkInterfaceTypePPP as String, displayName: nil)
        ) == .tunnel)
        #expect(NetworkDetailsBuilder.kind(
            for: "ipsec0",
            metadata: RawInterfaceMetadata(type: kSCNetworkInterfaceTypeIPSec as String, displayName: nil)
        ) == .tunnel)
        #expect(NetworkDetailsBuilder.kind(
            for: "ppp0",
            metadata: RawInterfaceMetadata(type: kSCNetworkInterfaceTypeL2TP as String, displayName: nil)
        ) == .tunnel)
        #expect(NetworkDetailsBuilder.kind(
            for: "stf0",
            metadata: RawInterfaceMetadata(type: kSCNetworkInterfaceType6to4 as String, displayName: nil)
        ) == .tunnel)
        #expect(NetworkDetailsBuilder.kind(
            for: "pptp0", metadata: RawInterfaceMetadata(type: "PPTP", displayName: nil)
        ) == .tunnel)
        #expect(NetworkDetailsBuilder.kind(
            for: "en9", metadata: RawInterfaceMetadata(type: "FireWire", displayName: nil)
        ) == .other)
        #expect(NetworkDetailsBuilder.kind(for: "en9", metadata: nil) == .unknown)
        #expect(NetworkDetailsBuilder.kind(for: "utun9", metadata: nil) == .tunnel)
        #expect(NetworkDetailsBuilder.kind(for: "tun0", metadata: nil) == .tunnel)
        #expect(NetworkDetailsBuilder.kind(for: "tap0", metadata: nil) == .tunnel)
        #expect(NetworkDetailsBuilder.kind(for: "bridge9", metadata: nil) == .bridge)
    }

    @Test func samplerCachesWithinIntervalAndRefreshesOnSwitch() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let secondState = makeState(
            interfaces: [rawInterface("en5")],
            addresses: [rawIPv4("en5", 198, 51, 100, 20)],
            metadata: ["en5": ethernetMetadata],
            linkMetrics: ["en5": RawLinkMetrics(mtu: 1500, baudrate: 2_500_000_000)],
            primary4: .interface("en5")
        )
        let provider = SequenceProvider([
            makeSnapshot(primary4: .interface("en0")),
            NetworkDetailsBuilder.build(secondState, at: Date(timeIntervalSince1970: 0)),
        ])
        let sampler = NetworkDetailsSampler(provider: provider, now: { clock.now })

        #expect(sampler.snapshot().systemPrimaryIPv4 == .interface("en0"))
        #expect(sampler.snapshot().systemPrimaryIPv4 == .interface("en0"))
        #expect(provider.readCount == 1)

        clock.advance(NetworkDetailsSampler.minimumRefreshInterval + 1)
        let switched = sampler.snapshot()
        #expect(switched.systemPrimaryIPv4 == .interface("en5"))
        #expect(switched.interface(named: "en0") == nil)
        #expect(switched.interface(named: "en5") != nil)
        #expect(provider.readCount == 2)

        #expect(sampler.refresh().systemPrimaryIPv4 == .interface("en5"))
        #expect(provider.readCount == 3)
    }

    @Test func concurrentSnapshotCallsShareOneRead() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let provider = SequenceProvider([makeSnapshot(primary4: .interface("en0"))])
        let sampler = NetworkDetailsSampler(provider: provider, now: { clock.now })

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = sampler.snapshot() }
            }
        }

        #expect(provider.readCount == 1)
    }
}

@Suite struct InterfaceListParserTests {
    @Test func parsesValidMessagesWithNamesAnd64BitValues() {
        let buffer = interfaceMessage(
            index: 1, mtu: 1500, baudrate: 1_000_000_000,
            inBytes: 4_294_967_296, outBytes: 7
        ) + interfaceMessage(
            index: 2, mtu: 9000, baudrate: 2_500_000_000,
            inBytes: 10, outBytes: 20
        )
        let names: [UInt16: String] = [1: "en0", 2: "en5"]

        let entries = InterfaceListParser.parse(buffer, length: buffer.count) { names[$0] }

        #expect(entries.map(\.name) == ["en0", "en5"])
        #expect(entries[0].mtu == 1500)
        #expect(entries[0].baudrate == 1_000_000_000)
        #expect(entries[0].inBytes == 4_294_967_296)
        #expect(entries[0].outBytes == 7)
        #expect(entries[1].mtu == 9000)
        #expect(entries[1].baudrate == 2_500_000_000)
    }

    @Test func parsesInterfaceRecordsInterleavedWithShorterRoutingMessages() throws {
        // A real NET_RT_IFLIST2 dump lists RTM_NEWADDR and RTM_NEWMADDR2 records
        // between interface records. Their declared lengths (56-104 bytes) are shorter
        // than if_msghdr (112), so advancing must use the shared 4-byte prelude.
        let buffer = interfaceMessage(index: 1, mtu: 65_536, inBytes: 1_000, outBytes: 2_000)
            + ipv4AddressMessage(byteCount: 60, index: 1)
            + multicastAddressMessage(byteCount: 56, index: 1)
            + interfaceMessage(
                index: 2, mtu: 1500, baudrate: 1_200_000_000,
                inBytes: 4_294_967_296 + 123, outBytes: 7_654_321_098
            )
        let names: [UInt16: String] = [1: "lo0", 2: "en1"]

        let entries = InterfaceListParser.parse(buffer, length: buffer.count) { names[$0] }

        let en1 = try #require(entries.last)
        #expect(entries.map(\.name) == ["lo0", "en1"])
        #expect(en1.mtu == 1500)
        #expect(en1.baudrate == 1_200_000_000)
        #expect(en1.inBytes == 4_294_967_296 + 123)
        #expect(en1.outBytes == 7_654_321_098)

        let totals = NetworkSampler.totals(
            from: buffer, length: buffer.count, resolveName: { names[$0] }
        )
        #expect(totals.0 == 4_294_967_296 + 123)
        #expect(totals.1 == 7_654_321_098)
    }

    @Test func skipsShortNonInterfaceMessagesAndKeepsFollowingRecords() {
        let buffer = interfaceMessage(index: 1)
            + routingMessage(type: UInt8(RTM_NEWADDR), byteCount: 15)
            + routingMessage(type: UInt8(RTM_NEWMADDR2), byteCount: 4)
            + interfaceMessage(index: 2)
        let names: [UInt16: String] = [1: "en0", 2: "en5"]

        let entries = InterfaceListParser.parse(buffer, length: buffer.count) { names[$0] }

        #expect(entries.map(\.name) == ["en0", "en5"])
    }

    @Test func stopsAtMessageShorterThanTheSharedPrelude() {
        let unadvanceable: [UInt8] = [3, 0, UInt8(RTM_VERSION), UInt8(RTM_NEWADDR)]
        let buffer = interfaceMessage(index: 1) + unadvanceable + interfaceMessage(index: 2)
        let names: [UInt16: String] = [1: "en0", 2: "en5"]

        let entries = InterfaceListParser.parse(buffer, length: buffer.count) { names[$0] }

        #expect(entries.map(\.name) == ["en0"])
    }

    @Test func clampsDeclaredLengthToBufferSize() {
        let buffer = interfaceMessage(index: 1, inBytes: 10, outBytes: 20)
        let names: [UInt16: String] = [1: "en0"]

        let entries = InterfaceListParser.parse(buffer, length: buffer.count + 1_000) { names[$0] }

        #expect(entries.map(\.name) == ["en0"])
        #expect(entries.first?.inBytes == 10)
    }

    @Test func skipsShortMessageAndKeepsFollowingMessage() {
        let shortLength = MemoryLayout<if_msghdr>.size
        let short = Array(
            interfaceMessage(index: 1, declaredLength: UInt16(shortLength)).prefix(shortLength)
        )
        let buffer = short + interfaceMessage(index: 2)
        let names: [UInt16: String] = [1: "en0", 2: "en5"]

        let entries = InterfaceListParser.parse(buffer, length: buffer.count) { names[$0] }

        #expect(entries.map(\.name) == ["en5"])
    }

    @Test func stopsAtZeroLengthMessage() {
        let buffer = interfaceMessage(index: 1)
            + interfaceMessage(index: 2, declaredLength: 0)
            + interfaceMessage(index: 3)
        let names: [UInt16: String] = [1: "en0", 2: "en5", 3: "utun3"]

        let entries = InterfaceListParser.parse(buffer, length: buffer.count) { names[$0] }

        #expect(entries.map(\.name) == ["en0"])
    }

    @Test func skipsNonInterfaceMessageAndTruncatedTail() {
        let buffer = interfaceMessage(index: 1, type: UInt8(RTM_IFINFO))
            + interfaceMessage(index: 2)
            + Array(interfaceMessage(index: 3).prefix(50))
        let names: [UInt16: String] = [1: "en0", 2: "en5", 3: "utun3"]

        let entries = InterfaceListParser.parse(buffer, length: buffer.count) { names[$0] }

        #expect(entries.map(\.name) == ["en5"])
    }

    @Test func skipsUnresolvedInterfaceName() {
        let buffer = interfaceMessage(index: 9)

        let entries = InterfaceListParser.parse(buffer, length: buffer.count) { _ in nil }

        #expect(entries.isEmpty)
    }

    @Test func totalsKeepExclusionsAnd64BitCounters() {
        let buffer = interfaceMessage(index: 1, inBytes: 4_294_967_296, outBytes: 4_294_967_297)
            + interfaceMessage(index: 2, inBytes: 9_000_000_000, outBytes: 9_000_000_001)
            + interfaceMessage(index: 3, inBytes: 1, outBytes: 1)
            + interfaceMessage(index: 4, inBytes: 2, outBytes: 2)
            + interfaceMessage(index: 5, inBytes: 3, outBytes: 4)
        let names: [UInt16: String] = [
            1: "en0", 2: "utun3", 3: "lo0", 4: "bridge0", 5: "en5",
        ]

        let totals = NetworkSampler.totals(
            from: buffer, length: buffer.count, resolveName: { names[$0] }
        )

        #expect(totals.0 == 4_294_967_296 + 3)
        #expect(totals.1 == 4_294_967_297 + 4)
    }

    @Test func totalsLoaderBoundary() {
        let buffer = interfaceMessage(index: 1, inBytes: 5, outBytes: 6)
        let names: [UInt16: String] = [1: "en0"]

        let loaded = NetworkSampler.totals(
            load: { (buffer, buffer.count) },
            resolveName: { names[$0] }
        )
        #expect(loaded?.0 == 5)
        #expect(loaded?.1 == 6)
        #expect(NetworkSampler.totals(load: { nil }) == nil)
    }

    @Test func readingHandlesFirstSampleResetAndNonPositiveTime() {
        let t0 = Date(timeIntervalSince1970: 100)

        #expect(NetworkSampler.reading(previous: nil, current: (100, 200), now: t0) == nil)

        let normal = NetworkSampler.reading(
            previous: (100, 200, t0),
            current: (300, 600),
            now: t0.addingTimeInterval(2)
        )
        #expect(normal?.inBytesPerSecond == 100)
        #expect(normal?.outBytesPerSecond == 200)

        let reset = NetworkSampler.reading(
            previous: (300, 600, t0),
            current: (100, 900),
            now: t0.addingTimeInterval(2)
        )
        #expect(reset?.inBytesPerSecond == 0)
        #expect(reset?.outBytesPerSecond == 150)

        #expect(NetworkSampler.reading(
            previous: (100, 200, t0),
            current: (300, 400),
            now: t0
        ) == nil)
        #expect(NetworkSampler.reading(
            previous: (100, 200, t0),
            current: (300, 400),
            now: t0.addingTimeInterval(-1)
        ) == nil)
    }

    @Test func samplePreservesFailureFirstSampleAndResetBehavior() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let failing = NetworkSampler(readTotals: { nil }, now: { clock.now })
        #expect(failing.sample() == nil)

        let totals = TotalsBox((100, 200))
        let sampler = NetworkSampler(readTotals: { totals.value }, now: { clock.now })
        #expect(sampler.sample() == nil) // first sample sets the baseline

        clock.advance(2)
        let steady = sampler.sample()
        #expect(steady?.inBytesPerSecond == 0)
        #expect(steady?.outBytesPerSecond == 0)

        totals.set((50, 300))
        clock.advance(1)
        let reset = sampler.sample()
        #expect(reset?.inBytesPerSecond == 0)
        #expect(reset?.outBytesPerSecond == 100)
    }

    @Test func linkMetricsUseSharedParser() {
        let buffer = interfaceMessage(index: 1, mtu: 1500, baudrate: 1_000_000_000)
            + interfaceMessage(index: 2, mtu: 9000, baudrate: 0)
        let names: [UInt16: String] = [1: "en0", 2: "en5"]

        let metrics = SystemNetworkStateReader.linkMetrics(
            from: buffer, length: buffer.count, resolveName: { names[$0] }
        )
        #expect(metrics["en0"] == RawLinkMetrics(mtu: 1500, baudrate: 1_000_000_000))
        #expect(metrics["en5"] == RawLinkMetrics(mtu: 9000, baudrate: 0))

        let loaded = SystemNetworkStateReader.readLinkMetrics(
            load: { (buffer, buffer.count) },
            resolveName: { names[$0] }
        )
        #expect(loaded?["en0"]?.mtu == 1500)
        #expect(SystemNetworkStateReader.readLinkMetrics(load: { nil }) == nil)
    }

    @Test func rawAddressParsesSyntheticSockaddrs() {
        withSockaddr(ipv4Sockaddr([192, 0, 2, 10])) { address in
            withSockaddr(ipv4Sockaddr([255, 255, 255, 0])) { netmask in
                let raw = SystemNetworkStateReader.rawAddress(
                    interfaceName: "en0", address: address, netmask: netmask
                )
                #expect(raw?.interfaceName == "en0")
                #expect(raw?.family == .ipv4)
                #expect(raw?.bytes == [192, 0, 2, 10])
                #expect(raw?.prefixLength == 24)
            }

            let withoutMask = SystemNetworkStateReader.rawAddress(
                interfaceName: "en0", address: address, netmask: nil
            )
            #expect(withoutMask?.prefixLength == nil)

            withSockaddr(ipv4Sockaddr([255, 0, 255, 0])) { netmask in
                let raw = SystemNetworkStateReader.rawAddress(
                    interfaceName: "en0", address: address, netmask: netmask
                )
                #expect(raw?.prefixLength == nil)
            }
        }

        withSockaddr(ipv6Sockaddr(globalIPv6)) { address in
            withSockaddr(ipv6Sockaddr([
                0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                0, 0, 0, 0, 0, 0, 0, 0,
            ])) { netmask in
                let raw = SystemNetworkStateReader.rawAddress(
                    interfaceName: "en0", address: address, netmask: netmask
                )
                #expect(raw?.family == .ipv6)
                #expect(raw?.bytes == globalIPv6)
                #expect(raw?.prefixLength == 64)
            }
        }

        var link = sockaddr()
        link.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        link.sa_family = sa_family_t(AF_LINK)
        withUnsafePointer(to: &link) { address in
            #expect(SystemNetworkStateReader.rawAddress(
                interfaceName: "en0", address: address, netmask: nil
            ) == nil)
        }
    }
}
