import AppKit
import Darwin
import Foundation
import SwiftUI
import SystemConfiguration
import Testing
@testable import Metrics
@testable import NetworkDetailsFeature

/// The view is tested from synthetic snapshots only. Nothing here calls `getifaddrs`, `sysctl`,
/// SystemConfiguration or any other system reader, and nothing starts the app or the helper.
@Suite(.serialized) struct NetworkDetailsContentTests {
    private let testDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Synthetic snapshots

    private func snapshot(_ interfaces: NetworkDetailAvailability<[NetworkInterfaceDetails]>,
                          primaryIPv4: PrimaryInterfaceState = .none,
                          primaryIPv6: PrimaryInterfaceState = .none) -> NetworkDetailsSnapshot {
        NetworkDetailsSnapshot(capturedAt: testDate,
                               interfaces: interfaces,
                               systemPrimaryIPv4: primaryIPv4,
                               systemPrimaryIPv6: primaryIPv6)
    }

    private func makeInterface(name: String = "en0",
                               displayName: String? = "Wi-Fi",
                               kind: NetworkInterfaceKind = .wifi,
                               isUp: Bool = true,
                               isRunning: Bool = true,
                               ipv4: [IPv4InterfaceAddress] = [],
                               ipv6: [IPv6InterfaceAddress] = [],
                               linkSpeed: NetworkDetailAvailability<UInt64> = .unavailable(.notReportedBySystem),
                               mtu: NetworkDetailAvailability<Int> = .unavailable(.notReportedBySystem)) -> NetworkInterfaceDetails {
        NetworkInterfaceDetails(name: name,
                                displayName: displayName,
                                kind: kind,
                                isUp: isUp,
                                isRunning: isRunning,
                                ipv4: ipv4,
                                ipv6: ipv6,
                                linkSpeedBitsPerSecond: linkSpeed,
                                mtu: mtu)
    }

    private func makeIPv4(_ address: String, prefix: Int? = 24, scope: IPv4Scope = .privateNetwork) -> IPv4InterfaceAddress {
        IPv4InterfaceAddress(address: address, prefixLength: prefix, scope: scope)
    }

    private func makeIPv6(_ address: String, prefix: Int? = 64, scope: IPv6Scope = .global) -> IPv6InterfaceAddress {
        IPv6InterfaceAddress(address: address, prefixLength: prefix, scope: scope)
    }

    // MARK: - The compact list

    @Test func onlyPrimariesAndActiveTunnelsAreListed() throws {
        let en0 = makeInterface(ipv4: [makeIPv4("192.168.1.50")])
        let en5 = makeInterface(name: "en5", displayName: "USB LAN", kind: .ethernet,
                                ipv4: [makeIPv4("192.168.2.10")])
        let bridge = makeInterface(name: "bridge100", displayName: nil, kind: .bridge,
                                   ipv4: [makeIPv4("192.168.64.1")])
        let vmenet = makeInterface(name: "vmenet0", displayName: nil, kind: .other,
                                   ipv4: [makeIPv4("192.168.105.2")])
        let primaryTunnel = makeInterface(name: "utun3", displayName: "Tunnel", kind: .tunnel,
                                          ipv4: [makeIPv4("10.8.0.2", prefix: 32)])
        let idleTunnel = makeInterface(name: "utun4", displayName: "Tunnel", kind: .tunnel,
                                       isRunning: false, ipv4: [makeIPv4("10.9.0.2", prefix: 32)])
        let downTunnel = makeInterface(name: "utun5", displayName: "Tunnel", kind: .tunnel,
                                       isUp: false, isRunning: false,
                                       ipv4: [makeIPv4("10.10.0.2", prefix: 32)])
        let otherTunnel = makeInterface(name: "stf0", displayName: nil, kind: .tunnel)

        let display = NetworkDetailsDisplay(snapshot: snapshot(.available([
            en0, en5, bridge, vmenet, primaryTunnel, idleTunnel, downTunnel, otherTunnel,
        ]),
        primaryIPv4: .interface("en0"),
        primaryIPv6: .interface("utun3")))

        // Primary IPv4 first, primary IPv6 second, then the remaining active tunnel by name.
        #expect(display.interfaceList?.map(\.name) == ["en0", "utun3", "stf0"])
        let names = Set(display.interfaceList?.map(\.name) ?? [])
        for hidden in ["en5", "bridge100", "vmenet0", "utun4", "utun5"] {
            #expect(!names.contains(hidden), "\(hidden) must stay off the compact page")
        }
        #expect(display.hasTunnel)
    }

    @Test func primariesStayListedWithoutAnAddress() throws {
        let en0 = makeInterface(displayName: "Wi-Fi", ipv4: [], ipv6: [])
        let display = NetworkDetailsDisplay(snapshot: snapshot(.available([en0]),
                                                               primaryIPv4: .interface("en0"),
                                                               primaryIPv6: .interface("en0")))
        let card = try #require(display.interfaceList?.first)
        #expect(card.name == "en0")
        #expect(card.ipv4Address == nil)
        #expect(card.isPrimaryIPv4)
        #expect(card.isPrimaryIPv6)
    }

    @Test func tunnelNamesSortAfterThePrimaries() throws {
        let en0 = makeInterface()
        let utun9 = makeInterface(name: "utun9", displayName: "Tunnel", kind: .tunnel)
        let utun2 = makeInterface(name: "utun2", displayName: "Tunnel", kind: .tunnel)
        let utun7 = makeInterface(name: "utun7", displayName: "Tunnel", kind: .tunnel)

        let display = NetworkDetailsDisplay(snapshot: snapshot(.available([utun7, utun2, en0, utun9]),
                                                               primaryIPv4: .interface("en0"),
                                                               primaryIPv6: .interface("utun9")))
        #expect(display.interfaceList?.map(\.name) == ["en0", "utun9", "utun2", "utun7"])
    }

    @Test func interfaceTitleFallsBackToBSDName() throws {
        for displayName in [nil, "", "   "] as [String?] {
            let display = NetworkDetailsDisplay(snapshot: snapshot(.available([makeInterface(displayName: displayName)]),
                                                                   primaryIPv4: .interface("en0")))
            let interface = try #require(display.interfaceList?.first)
            #expect(interface.title == "en0")
        }

        let friendly = NetworkDetailsDisplay(snapshot: snapshot(.available([makeInterface(displayName: "Wi-Fi")]),
                                                                primaryIPv4: .interface("en0")))
        #expect(friendly.interfaceList?.first?.title == "Wi-Fi")
    }

    @Test func statusUsesUpAndRunningSeparately() throws {
        let cases: [(Bool, Bool, NetworkDetailsDisplay.Status)] = [
            (true, true, .upAndRunning),
            (true, false, .upLinkInactive),
            (false, false, .down),
            // IFF_RUNNING without IFF_UP is not a usable state; it must not read as active.
            (false, true, .down),
        ]
        for (isUp, isRunning, expected) in cases {
            let display = NetworkDetailsDisplay(snapshot: snapshot(
                .available([makeInterface(isUp: isUp, isRunning: isRunning)]),
                primaryIPv4: .interface("en0")))
            let interface = try #require(display.interfaceList?.first)
            #expect(interface.status == expected)
        }
    }

    // MARK: - Source and primary states

    @Test func emptyListAndFilteredEmptyStayDistinct() {
        let empty = NetworkDetailsDisplay(snapshot: snapshot(.available([])))
        #expect(empty.source == .empty)
        #expect(!empty.hasTunnel)

        let bridge = makeInterface(name: "bridge100", displayName: nil, kind: .bridge)
        let idleTunnel = makeInterface(name: "utun4", displayName: "Tunnel", kind: .tunnel, isRunning: false)
        let filtered = NetworkDetailsDisplay(snapshot: snapshot(.available([bridge, idleTunnel])))
        #expect(filtered.source == .noActiveInterfaces)
        #expect(!filtered.hasTunnel)
    }

    @Test func emptyCopyDoesNotClaimTheSystemReturnedAnEmptyList() {
        // `Source.empty` only means the upstream list reached this page empty. The copy must not
        // turn that into a claim about the system's raw interface list.
        let title = NetworkDetailsText.noInterfaceToShow.rawValue
        let detail = NetworkDetailsText.noInterfaceToShowExplanation.rawValue
        #expect(!detail.localizedCaseInsensitiveContains("returned an empty"))
        #expect(!title.localizedCaseInsensitiveContains("no interfaces reported"))
        #expect(title != NetworkDetailsText.noActiveInterfaces.rawValue)
        #expect(detail != NetworkDetailsText.noActiveInterfacesExplanation.rawValue)
        #expect(detail.localizedCaseInsensitiveContains("not a reachability test"))
    }

    @Test func noInterfaceToShowExplanationMatchesTheCompactFilter() throws {
        // The page only keeps the system primary interfaces and enabled, running tunnels, so the
        // empty-state explanation must describe exactly that rule. Describing addressed interfaces
        // would promise cards this page never shows.
        let detail = NetworkDetailsText.noInterfaceToShowExplanation.rawValue
        #expect(!detail.localizedCaseInsensitiveContains("addressed"))
        #expect(detail.localizedCaseInsensitiveContains("primary interface"))
        #expect(detail.localizedCaseInsensitiveContains("tunnel"))

        let resources = try resourcesURL()
        let data = try Data(contentsOf: resources.appendingPathComponent("NetworkDetails.xcstrings"))
        let object = try JSONSerialization.jsonObject(with: data)
        let document = try #require(object as? [String: Any])
        let strings = try #require(document["strings"] as? [String: Any])
        let entry = try #require(strings[detail] as? [String: Any], "\(detail) is missing")
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let expectations: [String: (stale: String, tunnel: String)] = [
            "es": ("con dirección", "túnel"),
            "ja": ("アドレスを持つ", "トンネル"),
            "ko": ("주소가 있는", "터널"),
            "zh-Hans": ("带地址", "隧道"),
            "zh-Hant": ("具位址", "隧道"),
        ]
        for (language, expectation) in expectations {
            let unit = try #require((localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any],
                                    "\(language) has no string unit")
            let value = try #require(unit["value"] as? String)
            #expect(!value.contains(expectation.stale),
                    "\(language) still describes addressed interfaces")
            #expect(value.contains(expectation.tunnel),
                    "\(language) must name the active tunnel rule")
        }
    }

    @Test func filteredAddressedInterfaceKeepsThePrimarySummaryHonest() throws {
        // An addressed non-primary interface (en5) is filtered out, so the page shows the
        // filtered-empty state. The copy must not claim there is no primary interface while the
        // primary block above can say "Could not read" (.unknown) or "en9, Not listed" (the named
        // primary is not on this page).
        let en5 = makeInterface(name: "en5", displayName: "USB LAN", kind: .ethernet,
                                ipv4: [makeIPv4("192.168.2.10")])
        let title = NetworkDetailsText.noActiveInterfaces.rawValue
        let detail = NetworkDetailsText.noActiveInterfacesExplanation.rawValue
        #expect(!title.localizedCaseInsensitiveContains("no primary"))
        #expect(!detail.localizedCaseInsensitiveContains("no primary interface"))

        let unknown = NetworkDetailsDisplay(snapshot: snapshot(.available([en5]),
                                                                primaryIPv6: .unknown))
        #expect(unknown.source == .noActiveInterfaces)
        #expect(unknown.showsPrimarySummary)
        #expect(unknown.primaryFields == [.ipv4, .ipv6])
        #expect(unknown.primaryIPv6.state == .unknown)
        #expect(NetworkDetailsText.couldNotRead.rawValue == "Could not read")

        let notListed = NetworkDetailsDisplay(snapshot: snapshot(.available([en5]),
                                                                  primaryIPv6: .interface("en9")))
        #expect(notListed.source == .noActiveInterfaces)
        #expect(notListed.showsPrimarySummary)
        #expect(notListed.primaryFields == [.ipv4, .ipv6])
        #expect(notListed.primaryIPv6.state == .interface("en9"))
        #expect(notListed.primaryIPv6.isListed == false)
        #expect(NetworkDetailsText.notListed.rawValue == "Not listed")

        // The Traditional Chinese copy the app ships must not carry the same contradiction.
        let resources = try resourcesURL()
        let data = try Data(contentsOf: resources.appendingPathComponent("NetworkDetails.xcstrings"))
        let object = try JSONSerialization.jsonObject(with: data)
        let document = try #require(object as? [String: Any])
        let strings = try #require(document["strings"] as? [String: Any])
        for key in [title, detail] {
            let entry = try #require(strings[key] as? [String: Any], "\(key) is missing")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let zhHant = try #require((localizations["zh-Hant"] as? [String: Any])?["stringUnit"] as? [String: Any],
                                      "\(key) has no zh-Hant string unit")
            let value = try #require(zhHant["value"] as? String)
            #expect(!value.contains("沒有主要介面"),
                    "zh-Hant copy must not claim there is no primary interface")
        }
    }

    @Test func emptyListAndReadFailureStayDistinct() {
        // configd can still name a primary when the interface list is empty; that is a different
        // fact from a failed read and is marked as "not listed".
        let emptyWithPrimary = NetworkDetailsDisplay(snapshot: snapshot(.available([]),
                                                                       primaryIPv4: .interface("en0")))
        #expect(emptyWithPrimary.primaryIPv4.isListed == false)

        let failed = NetworkDetailsDisplay(snapshot: snapshot(.unavailable(.readFailed),
                                                              primaryIPv4: .interface("en0")))
        #expect(failed.source == .unavailable(.readFailed))
        #expect(failed.primaryIPv4.state == .interface("en0"))
        // The interface list is unavailable, so the view must not claim the primary is missing.
        #expect(failed.primaryIPv4.isListed == nil)
        #expect(!failed.hasTunnel)
    }

    @Test func unavailableSourceKeepsItsReason() {
        let readFailed = NetworkDetailsDisplay(snapshot: snapshot(.unavailable(.readFailed)))
        #expect(readFailed.source == .unavailable(.readFailed))

        let notReported = NetworkDetailsDisplay(snapshot: snapshot(.unavailable(.notReportedBySystem)))
        #expect(notReported.source == .unavailable(.notReportedBySystem))
    }

    @Test func unavailableSourcesUseDistinctText() {
        let readFailed = NetworkDetailsSourceMessage.copy(for: .readFailed)
        let notReported = NetworkDetailsSourceMessage.copy(for: .notReportedBySystem)
        #expect(readFailed.title == .interfaceListUnavailable)
        #expect(readFailed.detail == .failedExplanation)
        #expect(notReported.title == .interfaceListNotReported)
        #expect(notReported.detail == .notReportedExplanation)
        #expect(readFailed.title != notReported.title)
        #expect(readFailed.detail != notReported.detail)
    }

    @Test func primarySummaryOnlyAppearsWhenCardsCannotShowIt() {
        // The compact rule: the Wi-Fi card already carries the "Primary IPv4" badge, and the
        // system reported no primary IPv6, so no separate block adds information.
        let listed = NetworkDetailsDisplay(snapshot: snapshot(.available([makeInterface()]),
                                                              primaryIPv4: .interface("en0"),
                                                              primaryIPv6: .none))
        #expect(!listed.showsPrimarySummary)
        #expect(listed.primaryFields.isEmpty)

        let missing = NetworkDetailsDisplay(snapshot: snapshot(.available([]),
                                                               primaryIPv4: .interface("en0")))
        #expect(missing.showsPrimarySummary)
        #expect(missing.primaryFields == [.ipv4, .ipv6])

        let failedWithName = NetworkDetailsDisplay(snapshot: snapshot(.unavailable(.readFailed),
                                                                      primaryIPv4: .interface("en0")))
        #expect(failedWithName.showsPrimarySummary)

        // A primary read failure stays visible even when no interface name is known. The block
        // says "Could not read", not "none reported"; the source message only explains the list.
        let failedUnknown = NetworkDetailsDisplay(snapshot: snapshot(.unavailable(.readFailed),
                                                                     primaryIPv4: .unknown))
        #expect(failedUnknown.showsPrimarySummary)
        #expect(failedUnknown.primaryFields == [.ipv4, .ipv6])

        let offline = NetworkDetailsDisplay(snapshot: snapshot(.available([]),
                                                               primaryIPv4: .none,
                                                               primaryIPv6: .none))
        #expect(!offline.showsPrimarySummary)

        let onlyBridge = NetworkDetailsDisplay(snapshot: snapshot(.available([
            makeInterface(name: "bridge100", displayName: nil, kind: .bridge),
        ]), primaryIPv4: .none))
        #expect(onlyBridge.source == .noActiveInterfaces)
        #expect(!onlyBridge.showsPrimarySummary)
    }

    @Test func failedPrimaryIPv6KeepsThePrimaryBlockWhenIPv4HasACard() {
        // The card shows Wi-Fi as the primary IPv4 interface. A primary IPv6 read failure must not
        // disappear behind that card: the same page with `.none` stays compact, while `.unknown`
        // gets a "Primary IPv6: Could not read" row.
        let none = NetworkDetailsDisplay(snapshot: snapshot(.available([makeInterface()]),
                                                            primaryIPv4: .interface("en0"),
                                                            primaryIPv6: .none))
        #expect(!none.showsPrimarySummary)

        let unknown = NetworkDetailsDisplay(snapshot: snapshot(.available([makeInterface()]),
                                                               primaryIPv4: .interface("en0"),
                                                               primaryIPv6: .unknown))
        #expect(unknown.showsPrimarySummary)
        #expect(unknown.primaryFields == [.ipv6])

        // A named primary that is not on the page gets its own row instead of silently matching
        // the "not reported" state.
        let notListed = NetworkDetailsDisplay(snapshot: snapshot(.available([makeInterface()]),
                                                                 primaryIPv4: .interface("en0"),
                                                                 primaryIPv6: .interface("en9")))
        #expect(notListed.showsPrimarySummary)
        #expect(notListed.primaryFields == [.ipv6])
        #expect(notListed.primaryIPv6.isListed == false)
    }

    @Test func primaryStatesResolveNamesAndMissingInterfaces() {
        let display = NetworkDetailsDisplay(snapshot: snapshot(.available([makeInterface()]),
                                                               primaryIPv4: .interface("en0"),
                                                               primaryIPv6: .interface("en9")))
        #expect(display.primaryIPv4.state == .interface("en0"))
        #expect(display.primaryIPv4.displayName == "Wi-Fi")
        #expect(display.primaryIPv4.isListed == true)
        #expect(display.primaryIPv6.state == .interface("en9"))
        #expect(display.primaryIPv6.displayName == nil)
        #expect(display.primaryIPv6.isListed == false)

        let none = NetworkDetailsDisplay(snapshot: snapshot(.available([]),
                                                            primaryIPv4: .none,
                                                            primaryIPv6: .unknown))
        #expect(none.primaryIPv4.state == .none)
        #expect(none.primaryIPv4.isListed == nil)
        #expect(none.primaryIPv6.state == .unknown)
        #expect(none.primaryIPv6.isListed == nil)
    }

    // MARK: - Tunnel identity

    @Test func tunnelsUseTheNeutralNameAndNeverClaimVPN() throws {
        // The upstream classifier maps 6to4 to .tunnel. stf0 is the usual 6to4 name, and the
        // display must use the neutral tunnel name instead of claiming a VPN.
        let kind = NetworkDetailsBuilder.kind(
            for: "stf0",
            metadata: RawInterfaceMetadata(type: kSCNetworkInterfaceType6to4 as String, displayName: nil))
        #expect(kind == .tunnel)

        let stf0 = makeInterface(name: "stf0", displayName: nil, kind: kind)
        let display = NetworkDetailsDisplay(snapshot: snapshot(.available([stf0])))
        let interface = try #require(display.interfaceList?.first)
        #expect(interface.kind == .tunnel)
        #expect(display.hasTunnel)
        #expect(NetworkDetailsText.tunnel.rawValue == "Tunnel")
        #expect(!NetworkDetailsText.allCases.map(\.rawValue).contains("VPN"))
    }

    @Test func hiddenTunnelsDoNotAddTheTunnelFootnote() {
        let idleTunnel = makeInterface(name: "utun4", displayName: "Tunnel", kind: .tunnel, isRunning: false)
        let display = NetworkDetailsDisplay(snapshot: snapshot(.available([idleTunnel])))
        #expect(display.source == .noActiveInterfaces)
        #expect(!display.hasTunnel)
    }

    // MARK: - The two values on each card

    @Test func mainIPv4ComesFromTheMostUsableAddressTheBuilderReported() throws {
        // Build through the real upstream builder from synthetic raw data, so the ordering rule
        // (global, private, shared, link-local, loopback) is what selects the one shown address.
        func ipv4(_ bytes: [UInt8]) -> RawAddress {
            RawAddress(interfaceName: "en0", family: .ipv4, bytes: bytes, prefixLength: 24)
        }
        let table = RawInterfaceTable(
            interfaces: [RawInterface(name: "en0", flags: UInt32(IFF_UP | IFF_RUNNING))],
            addresses: [ipv4([169, 254, 1, 2]), ipv4([192, 168, 1, 50]), ipv4([192, 0, 2, 10])])
        let snapshot = NetworkDetailsBuilder.build(SystemNetworkState(
            interfaceTable: table,
            linkMetrics: ["en0": RawLinkMetrics(mtu: 1500, baudrate: 183_000_000)],
            metadata: ["en0": RawInterfaceMetadata(type: kSCNetworkInterfaceTypeIEEE80211 as String,
                                                   displayName: "Wi-Fi")],
            systemPrimaryIPv4: .interface("en0"),
            systemPrimaryIPv6: .none), at: testDate)

        let display = NetworkDetailsDisplay(snapshot: snapshot)
        let card = try #require(display.interfaceList?.first)
        #expect(card.title == "Wi-Fi")
        #expect(card.name == "en0")
        #expect(card.ipv4Address == "192.0.2.10/24")
        #expect(card.linkSpeed == .available(183_000_000))
    }

    @Test func noReportedIPv4IsShownAsNoneReported() throws {
        let display = NetworkDetailsDisplay(snapshot: snapshot(.available([makeInterface(ipv4: [])]),
                                                               primaryIPv4: .interface("en0")))
        let card = try #require(display.interfaceList?.first)
        #expect(card.ipv4Address == nil)
    }

    @Test func unavailableLinkSpeedKeepsItsReason() throws {
        let failed = NetworkDetailsDisplay(snapshot: snapshot(
            .available([makeInterface(linkSpeed: .unavailable(.readFailed))]),
            primaryIPv4: .interface("en0")))
        #expect(failed.interfaceList?.first?.linkSpeed == .unavailable(.readFailed))

        let tunnel = makeInterface(name: "utun3", displayName: "Tunnel", kind: .tunnel,
                                   linkSpeed: .unavailable(.notReportedBySystem))
        let tunnelDisplay = NetworkDetailsDisplay(snapshot: snapshot(.available([tunnel])))
        #expect(tunnelDisplay.interfaceList?.first?.linkSpeed == .unavailable(.notReportedBySystem))
    }

    @Test func compactPageHasNoMTUOrScopeCopy() {
        let keys = Set(NetworkDetailsText.allCases.map(\.rawValue))
        for removed in ["MTU", "Global", "Private", "Shared", "Link-local", "Loopback",
                        "Unique local", "%lld bytes"] {
            #expect(!keys.contains(removed), "\(removed) must no longer be shown")
        }
        #expect(keys.contains("IPv4"))
        #expect(keys.contains("Link speed"))
        #expect(keys.contains("Primary IPv4"))
        #expect(keys.contains("Primary IPv6"))
    }

    // MARK: - Formatting

    @Test func linkSpeedUsesReadableDecimalUnits() {
        let locale = Locale(identifier: "en_US_POSIX")
        #expect(NetworkDetailsFormat.linkSpeed(1_000_000_000, locale: locale) == "1 Gb/s")
        #expect(NetworkDetailsFormat.linkSpeed(2_500_000_000, locale: locale) == "2.5 Gb/s")
        #expect(NetworkDetailsFormat.linkSpeed(183_000_000, locale: locale) == "183 Mb/s")
        #expect(NetworkDetailsFormat.linkSpeed(100_000_000, locale: locale) == "100 Mb/s")
        #expect(NetworkDetailsFormat.linkSpeed(10_000_000, locale: locale) == "10 Mb/s")
        #expect(NetworkDetailsFormat.linkSpeed(1_500_000, locale: locale) == "1.5 Mb/s")
        #expect(NetworkDetailsFormat.linkSpeed(1_000, locale: locale) == "1 Kb/s")
        #expect(NetworkDetailsFormat.linkSpeed(10, locale: locale) == "10 b/s")
    }

    // MARK: - Dedicated catalog

    @Test func catalogCoversEveryTextInEveryLanguage() throws {
        let resources = try resourcesURL()
        let data = try Data(contentsOf: resources.appendingPathComponent("NetworkDetails.xcstrings"))
        let object = try JSONSerialization.jsonObject(with: data)
        let document = try #require(object as? [String: Any])
        #expect(document["sourceLanguage"] as? String == "en")
        let strings = try #require(document["strings"] as? [String: Any])

        let expectedKeys = Set(NetworkDetailsText.allCases.map(\.rawValue))
        #expect(Set(strings.keys) == expectedKeys)
        let languages = ["es", "ja", "ko", "zh-Hans", "zh-Hant"]
        for key in expectedKeys {
            let entry = try #require(strings[key] as? [String: Any], "\(key) is missing")
            let localizations = try #require(entry["localizations"] as? [String: Any], "\(key) has no localizations")
            #expect(Set(localizations.keys) == Set(languages), "\(key) has \(localizations.keys.sorted())")
            for language in languages {
                let unit = try #require((localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any],
                                        "\(key) [\(language)] has no string unit")
                #expect(unit["state"] as? String == "translated")
                let value = try #require(unit["value"] as? String)
                #expect(!value.isEmpty)
            }
        }
    }

    @Test func catalogSpotChecksUseTheRightLanguage() throws {
        let resources = try resourcesURL()
        func localized(_ text: NetworkDetailsText, _ language: String) throws -> String {
            let bundle = try #require(Bundle(url: resources.appendingPathComponent("Localizations/\(language).lproj")))
            return text.localized(in: bundle)
        }
        #expect(try localized(.linkSpeed, "ja") == "リンク速度")
        #expect(try localized(.linkSpeed, "zh-Hant") == "連結速度")
        #expect(try localized(.interfaces, "zh-Hans") == "网络接口")
        #expect(try localized(.upAndRunning, "es") == "Activa y en funcionamiento")
        #expect(try localized(.noInterfaceToShow, "ko") == "표시할 인터페이스가 없습니다")
        #expect(try localized(.tunnel, "zh-Hant") == "隧道")
        #expect(try localized(.interfaceListNotReported, "ja") == "インターフェイス一覧が報告されていません")
        #expect(try localized(.ipv4, "zh-Hant") == "IPv4")
        #expect(try localized(.noActiveInterfaces, "zh-Hant") == "沒有可顯示的連線介面")
    }

    @Test func compiledTablesResolveEveryTextForEveryLanguage() throws {
        let resources = try resourcesURL()
        let languages = ["es", "ja", "ko", "zh-Hans", "zh-Hant"]
        let keys = Set(NetworkDetailsText.allCases.map(\.rawValue))
        for language in languages {
            let lproj = resources.appendingPathComponent("Localizations/\(language).lproj")
            let bundle = try #require(Bundle(url: lproj), "\(language) bundle is missing")
            let table = try #require(NSDictionary(contentsOf: lproj.appendingPathComponent("NetworkDetails.strings")) as? [String: String],
                                     "\(language) table is missing")
            #expect(Set(table.keys) == keys, "\(language) table keys differ")
            for text in NetworkDetailsText.allCases {
                #expect(table[text.rawValue] != nil, "\(language) is missing \(text.rawValue)")
                #expect(text.localized(in: bundle) == table[text.rawValue],
                        "\(language) lookup differs for \(text.rawValue)")
            }
        }
    }

    // MARK: - Layout at the menu width

    @Test @MainActor func compactCardsRenderAtMenuWidth() throws {
        let wifi = makeInterface(ipv4: [makeIPv4("192.168.1.50")],
                                 linkSpeed: .available(183_000_000))
        let tunnel = makeInterface(name: "utun3", displayName: "Tunnel", kind: .tunnel,
                                   ipv4: [makeIPv4("10.8.0.2", prefix: 32)],
                                   linkSpeed: .unavailable(.notReportedBySystem))
        let view = NetworkDetailsContent(snapshot: snapshot(.available([tunnel, wifi]),
                                                            primaryIPv4: .interface("en0")))
        let image = try #require(render(view, dynamicTypeSize: .large))
        #expect(image.size.width == 460)
        #expect(image.size.height > 0)
    }

    @Test @MainActor func primaryIPv6FailureRendersDifferentlyFromNoneOnTheSameCard() throws {
        // A real ImageRenderer comparison: both pages show the same Wi-Fi primary IPv4 card, but
        // one has no primary IPv6 and the other could not read it. ImageRenderer antialiases text
        // with one-bit differences between two renders of the same view (measured: maximum channel
        // difference 1, never 2), so the comparison below ignores that noise and still expects the
        // read-failure page to draw more than the compact page.
        let wifi = makeInterface(ipv4: [makeIPv4("192.168.1.50")],
                                 linkSpeed: .available(183_000_000))
        let noneView = NetworkDetailsContent(snapshot: snapshot(.available([wifi]),
                                                                primaryIPv4: .interface("en0"),
                                                                primaryIPv6: .none))
        let unknownView = NetworkDetailsContent(snapshot: snapshot(.available([wifi]),
                                                                   primaryIPv4: .interface("en0"),
                                                                   primaryIPv6: .unknown))

        let none = try #require(renderPixels(noneView, dynamicTypeSize: .large))
        let noneAgain = try #require(renderPixels(noneView, dynamicTypeSize: .large))
        let unknown = try #require(renderPixels(unknownView, dynamicTypeSize: .large))
        #expect(none.width == noneAgain.width)
        #expect(none.height == noneAgain.height)
        #expect(none.contentApproximatelyEquals(noneAgain),
                "the same view should rasterize the same image, apart from one-bit antialiasing noise")
        // The read-failure page adds the "Primary IPv6: Could not read" row, so its image is taller
        // and cannot rasterize to the same pixels.
        #expect(unknown.height > none.height)
        #expect(!none.contentApproximatelyEquals(unknown))
    }

    @Test @MainActor func ipv6AndMTUDoNotChangeTheCardHeight() throws {
        // The compact card must not print IPv6 addresses, their scopes or the MTU. If it did, a
        // card with both would be taller than one without them.
        let withExtras = makeInterface(
            ipv4: [makeIPv4("192.0.2.10")],
            ipv6: [makeIPv6("2001:db8::1"), makeIPv6("fe80::1", scope: .linkLocal)],
            linkSpeed: .available(1_000_000_000),
            mtu: .available(1500))
        let withoutExtras = makeInterface(
            ipv4: [makeIPv4("192.0.2.10")],
            ipv6: [],
            linkSpeed: .available(1_000_000_000),
            mtu: .unavailable(.readFailed))

        let withImage = try #require(render(NetworkDetailsContent(snapshot: snapshot(
            .available([withExtras]), primaryIPv4: .interface("en0"))), dynamicTypeSize: .large))
        let withoutImage = try #require(render(NetworkDetailsContent(snapshot: snapshot(
            .available([withoutExtras]), primaryIPv4: .interface("en0"))), dynamicTypeSize: .large))
        #expect(withImage.size == withoutImage.size)
    }

    @Test @MainActor func emptyFailedNotReportedAndFilteredStatesRender() throws {
        let empty = NetworkDetailsContent(snapshot: snapshot(.available([])))
        let failed = NetworkDetailsContent(snapshot: snapshot(.unavailable(.readFailed),
                                                               primaryIPv4: .interface("en0"),
                                                               primaryIPv6: .unknown))
        let notReported = NetworkDetailsContent(snapshot: snapshot(.unavailable(.notReportedBySystem),
                                                                    primaryIPv4: .interface("en0"),
                                                                    primaryIPv6: .unknown))
        let bridgeOnly = NetworkDetailsContent(snapshot: snapshot(.available([
            makeInterface(name: "bridge100", displayName: nil, kind: .bridge),
        ]), primaryIPv4: .none, primaryIPv6: .none))

        for view in [AnyView(empty), AnyView(failed), AnyView(notReported), AnyView(bridgeOnly)] {
            let image = try #require(render(view, dynamicTypeSize: .large))
            #expect(image.size.width == 460)
            #expect(image.size.height > 0)
        }
    }

    @Test @MainActor func viewRendersAtDefaultAndLargeTextSizes() throws {
        let details = makeInterface(ipv4: [makeIPv4("192.0.2.10")],
                                    linkSpeed: .available(1_000_000_000))
        let view = NetworkDetailsContent(snapshot: snapshot(.available([details]),
                                                            primaryIPv4: .interface("en0"),
                                                            primaryIPv6: .interface("en0")))
        #expect(render(view, dynamicTypeSize: .large) != nil)
        #expect(render(view, dynamicTypeSize: .accessibility3) != nil)
    }

    @MainActor
    private func render(_ view: some View, dynamicTypeSize: DynamicTypeSize) -> NSImage? {
        let renderer = ImageRenderer(content: view
            .frame(width: 460)
            .environment(\.dynamicTypeSize, dynamicTypeSize))
        renderer.scale = 1
        return renderer.nsImage
    }

    /// The pixels `ImageRenderer` actually drew, normalized into one RGBA buffer. PNG encoding can
    /// change between two renders even when the drawing is identical, so tests compare these bytes.
    /// Two renders of the same view can still differ by one bit per text pixel, so comparisons
    /// allow that antialiasing noise.
    private struct RenderedPixels: Equatable {
        var width: Int
        var height: Int
        var pixels: [UInt8]

        func contentApproximatelyEquals(_ other: RenderedPixels, allowingDelta delta: Int = 1) -> Bool {
            guard width == other.width, height == other.height else { return false }
            for index in pixels.indices {
                if abs(Int(pixels[index]) - Int(other.pixels[index])) > delta { return false }
            }
            return true
        }
    }

    @MainActor
    private func renderPixels(_ view: some View, dynamicTypeSize: DynamicTypeSize) -> RenderedPixels? {
        let renderer = ImageRenderer(content: view
            .frame(width: 460)
            .environment(\.dynamicTypeSize, dynamicTypeSize))
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return RenderedPixels(width: width, height: height, pixels: pixels)
    }

    // MARK: - Resources

    private func resourcesURL() throws -> URL {
        let bundle = Bundle.module
        let url = try #require(bundle.resourceURL?.appendingPathComponent("Resources"),
                               "test resources are missing")
        return url
    }
}

private extension NetworkDetailsDisplay {
    var interfaceList: [Interface]? {
        if case .interfaces(let interfaces) = source { return interfaces }
        return nil
    }
}
