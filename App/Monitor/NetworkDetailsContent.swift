import Metrics
import SwiftUI

// MARK: - Display model

/// A presentation-only projection of one captured `NetworkDetailsSnapshot`.
///
/// The view and this model never read the system, start a timer or test reachability. Every value
/// here comes from the snapshot the caller already obtained, so previews and tests can render the
/// exact same content from synthetic data.
///
/// The page follows the user's compact choice: only the system primary interfaces and enabled,
/// running tunnels get a card, and each card shows just its name, state, one primary IPv4 address
/// and the link speed. IPv6 addresses, address scopes and MTU stay off the cards.
struct NetworkDetailsDisplay: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// The cards this page shows: the system primary interfaces and enabled, running tunnels.
        case interfaces([Interface])
        /// The compact page has nothing to show because the upstream list itself is empty. This is
        /// not a read failure, and it does not claim the system itself has no interfaces.
        case empty
        /// The upstream list has interfaces, but none is a system primary or an enabled, running
        /// tunnel under the compact rules.
        case noActiveInterfaces
        case unavailable(NetworkDetailUnavailableReason)
    }

    enum Status: Equatable, Sendable {
        /// `IFF_UP` and `IFF_RUNNING` are both set. This does not prove internet access.
        case upAndRunning
        /// `IFF_UP` is set but `IFF_RUNNING` is not: the interface is enabled without an active link.
        case upLinkInactive
        case down
    }

    enum FieldValue<Wrapped: Equatable & Sendable>: Equatable, Sendable {
        case available(Wrapped)
        case unavailable(NetworkDetailUnavailableReason)
    }

    /// The rows of the separate primary block. The block only exists to explain a primary fact a
    /// card cannot carry, so each row is chosen independently.
    enum PrimaryField: Equatable, Sendable {
        case ipv4
        case ipv6
    }

    struct Primary: Equatable, Sendable {
        enum State: Equatable, Sendable {
            case interface(String)
            case none
            case unknown
        }

        var state: State
        /// Friendly name from SystemConfiguration when the named interface is in this snapshot.
        var displayName: String?
        /// nil when the interface list is unavailable, so the view does not claim it is missing.
        var isListed: Bool?

        init(_ state: PrimaryInterfaceState, in interfaces: [NetworkInterfaceDetails]?) {
            switch state {
            case .interface(let name):
                self.state = .interface(name)
                if let interfaces {
                    let match = interfaces.first { $0.name == name }
                    displayName = match?.displayName
                    isListed = match != nil
                } else {
                    displayName = nil
                    isListed = nil
                }
            case .none:
                self.state = .none
                displayName = nil
                isListed = nil
            case .unknown:
                self.state = .unknown
                displayName = nil
                isListed = nil
            }
        }
    }

    struct Interface: Equatable, Sendable, Identifiable {
        var id: String { name }
        var name: String
        /// Friendly name when the system has one, otherwise the BSD name.
        var title: String
        var kind: NetworkInterfaceKind
        var status: Status
        /// The first IPv4 address the system reported for this interface. Upstream sorts the most
        /// usable scope first (global, private, shared, link-local, loopback), so this is the one
        /// address the compact card shows; the other addresses, their scopes and IPv6 are not
        /// rendered here.
        var ipv4Address: String?
        var linkSpeed: FieldValue<UInt64>
        var isPrimaryIPv4: Bool
        var isPrimaryIPv6: Bool

        init(_ details: NetworkInterfaceDetails, primaryIPv4: String?, primaryIPv6: String?) {
            name = details.name
            let friendly = details.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            title = friendly.isEmpty ? details.name : friendly
            kind = details.kind
            status = Status(isUp: details.isUp, isRunning: details.isRunning)
            ipv4Address = details.ipv4.first.map(Self.formatted)
            linkSpeed = details.linkSpeedBitsPerSecond.fieldValue
            isPrimaryIPv4 = details.name == primaryIPv4
            isPrimaryIPv6 = details.name == primaryIPv6
        }

        /// Lower ranks are shown first: the system primary IPv4 interface, then the system primary
        /// IPv6 interface, then every other active tunnel by BSD name.
        var sortRank: Int {
            if isPrimaryIPv4 { return 0 }
            if isPrimaryIPv6 { return 1 }
            return 2
        }

        private static func formatted(_ address: IPv4InterfaceAddress) -> String {
            if let prefixLength = address.prefixLength { return "\(address.address)/\(prefixLength)" }
            return address.address
        }
    }

    let source: Source
    let primaryIPv4: Primary
    let primaryIPv6: Primary
    /// A tunnel is listed separately; its addresses never merge with a physical interface.
    /// The kind alone does not prove the tunnel is a VPN.
    let hasTunnel: Bool

    init(snapshot: NetworkDetailsSnapshot) {
        let primaryIPv4Name = Self.interfaceName(snapshot.systemPrimaryIPv4)
        let primaryIPv6Name = Self.interfaceName(snapshot.systemPrimaryIPv6)
        let listed: [NetworkInterfaceDetails]?
        let cards: [Interface]
        switch snapshot.interfaces {
        case .available(let list):
            listed = list
            cards = list
                .filter { Self.isShown($0, primaryIPv4: primaryIPv4Name, primaryIPv6: primaryIPv6Name) }
                .map { Interface($0, primaryIPv4: primaryIPv4Name, primaryIPv6: primaryIPv6Name) }
                .sorted { ($0.sortRank, $0.name) < ($1.sortRank, $1.name) }
            if cards.isEmpty {
                source = list.isEmpty ? .empty : .noActiveInterfaces
            } else {
                source = .interfaces(cards)
            }
        case .unavailable(let reason):
            listed = nil
            cards = []
            source = .unavailable(reason)
        }
        primaryIPv4 = Primary(snapshot.systemPrimaryIPv4, in: listed)
        primaryIPv6 = Primary(snapshot.systemPrimaryIPv6, in: listed)
        hasTunnel = cards.contains { $0.kind == .tunnel }
    }

    /// The page keeps only what the user is connected through: the interfaces configd names as
    /// primary (even before they report an address) and tunnels that are both up and running.
    /// Bridges (`bridge*`), virtual VM interfaces (`vmenet*`), other physical interfaces and
    /// inactive tunnels stay out.
    ///
    /// A system primary is never hidden, even when it is a bridge or a disabled interface: if
    /// configd names one, it keeps its card and its honest `Down` state instead of disappearing.
    private static func isShown(_ details: NetworkInterfaceDetails,
                                primaryIPv4: String?,
                                primaryIPv6: String?) -> Bool {
        if details.name == primaryIPv4 || details.name == primaryIPv6 { return true }
        return details.kind == .tunnel && details.isUp && details.isRunning
    }

    /// The rows the separate primary block must show. A card already carries the primary badge, so
    /// a row is only added when its card cannot carry the fact: the primary read failed
    /// (`.unknown`) or the system named an interface that is not on this page (`isListed == false`).
    /// When there are no cards at all, a block with either primary named stays complete and shows
    /// both rows, which keeps "none", "not listed" and "could not read" readable.
    var primaryFields: [PrimaryField] {
        let hasCards: Bool
        switch source {
        case .interfaces:
            hasCards = true
        case .empty, .noActiveInterfaces, .unavailable:
            hasCards = false
        }
        if hasCards {
            var fields: [PrimaryField] = []
            if primaryIPv4.needsRow { fields.append(.ipv4) }
            if primaryIPv6.needsRow { fields.append(.ipv6) }
            return fields
        }
        guard primaryIPv4.hasInterface || primaryIPv6.hasInterface
                || primaryIPv4.needsRow || primaryIPv6.needsRow else { return [] }
        return [.ipv4, .ipv6]
    }

    /// The block would repeat what the primary badges already say, so it is only shown when at
    /// least one primary fact needs its own row.
    var showsPrimarySummary: Bool {
        !primaryFields.isEmpty
    }

    private static func interfaceName(_ state: PrimaryInterfaceState) -> String? {
        if case .interface(let name) = state { return name }
        return nil
    }
}

private extension NetworkDetailsDisplay.Primary {
    var hasInterface: Bool {
        if case .interface = state { return true }
        return false
    }

    /// True when no card can explain this primary: the read failed, or the named interface is not
    /// in the list the page received.
    var needsRow: Bool {
        if isListed == false { return true }
        if case .unknown = state { return true }
        return false
    }
}

private extension NetworkDetailAvailability {
    var fieldValue: NetworkDetailsDisplay.FieldValue<Value> {
        switch self {
        case .available(let value): .available(value)
        case .unavailable(let reason): .unavailable(reason)
        }
    }
}

private extension NetworkDetailsDisplay.Status {
    init(isUp: Bool, isRunning: Bool) {
        if isUp && isRunning {
            self = .upAndRunning
        } else if isUp {
            self = .upLinkInactive
        } else {
            self = .down
        }
    }
}

// MARK: - Text

/// Every string the view shows. Keeping the keys here lets the test check the dedicated catalog
/// covers all of them, instead of scraping SwiftUI literals from the source.
enum NetworkDetailsText: String, CaseIterable, Sendable {
    case networkDetails = "Network details"
    case systemPrimary = "System primary"
    case interfaces = "Interfaces"
    case primaryIPv4 = "Primary IPv4"
    case primaryIPv6 = "Primary IPv6"
    case ipv4 = "IPv4"
    case tunnel = "Tunnel"
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case bridge = "Bridge"
    case other = "Other"
    case unknown = "Unknown"
    case upAndRunning = "Up and running"
    case upLinkInactive = "Up, link inactive"
    case down = "Down"
    case linkSpeed = "Link speed"
    case notReportedBySystem = "Not reported by system"
    case couldNotRead = "Could not read"
    case noneReported = "None reported"
    case notListed = "Not listed"
    case noInterfaceToShow = "No interface to show"
    case noInterfaceToShowExplanation = "This page shows the system primary interface and active tunnel interfaces. None were reported in this snapshot. This is not a reachability test."
    case noActiveInterfaces = "No displayable interfaces"
    case noActiveInterfacesExplanation = "None of the reported interfaces are a listed system primary interface or an active tunnel. This is not a reachability test."
    case interfaceListUnavailable = "Interface list unavailable"
    case interfaceListNotReported = "Interface list not reported"
    case failedExplanation = "The system call that lists interfaces failed. This is not the same as having no interfaces."
    case notReportedExplanation = "The system did not report an interface list. This is not the same as having no interfaces."
    case primaryFootnote = "Primary interfaces and flags come from the system. They do not prove internet access."
    case tunnelFootnote = "Tunnel interfaces are listed separately; their addresses are not merged into other interfaces. A tunnel is not necessarily a VPN."

    func localized(in bundle: Bundle = .main, locale: Locale = .current) -> String {
        String(localized: String.LocalizationValue(rawValue),
               table: "NetworkDetails",
               bundle: bundle,
               locale: locale)
    }
}

/// The interface list can be unavailable for two different reasons. Keep the copy distinct:
/// a failed read is not the same fact as a source that did not report a list.
enum NetworkDetailsSourceMessage {
    static func copy(for reason: NetworkDetailUnavailableReason)
        -> (title: NetworkDetailsText, detail: NetworkDetailsText) {
        switch reason {
        case .readFailed:
            return (.interfaceListUnavailable, .failedExplanation)
        case .notReportedBySystem:
            return (.interfaceListNotReported, .notReportedExplanation)
        }
    }
}

enum NetworkDetailsFormat {
    /// Decimal link-speed units, e.g. "1 Gb/s", "2.5 Gb/s", "100 Mb/s".
    static func linkSpeed(_ bitsPerSecond: UInt64, locale: Locale = .current) -> String {
        let units: [(threshold: UInt64, divisor: Double, suffix: String)] = [
            (1_000_000_000, 1_000_000_000, "Gb/s"),
            (1_000_000, 1_000_000, "Mb/s"),
            (1_000, 1_000, "Kb/s"),
        ]
        for unit in units where bitsPerSecond >= unit.threshold {
            let value = Double(bitsPerSecond) / unit.divisor
            return "\(value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) \(unit.suffix)"
        }
        return "\(bitsPerSecond) b/s"
    }
}

private extension NetworkInterfaceKind {
    var label: NetworkDetailsText {
        switch self {
        case .wifi: .wifi
        case .ethernet: .ethernet
        // A tunnel can be a VPN, 6to4, IPsec, PPP or something else. The kind alone is not proof
        // of a VPN, so the neutral name is used for every tunnel.
        case .tunnel: .tunnel
        case .bridge: .bridge
        case .other: .other
        case .unknown: .unknown
        }
    }

    var tint: Color {
        switch self {
        case .wifi: Theme.blue
        case .ethernet: Theme.slate
        case .tunnel: Theme.slate
        case .bridge: Theme.cyan
        case .other, .unknown: Palette.textMuted
        }
    }
}

private extension NetworkDetailsDisplay.Status {
    var label: NetworkDetailsText {
        switch self {
        case .upAndRunning: .upAndRunning
        case .upLinkInactive: .upLinkInactive
        case .down: .down
        }
    }

    var tint: Color {
        switch self {
        case .upAndRunning: Theme.mint
        case .upLinkInactive: Theme.amber
        case .down: Palette.textMuted
        }
    }
}

private extension NetworkDetailUnavailableReason {
    var label: NetworkDetailsText {
        switch self {
        case .notReportedBySystem: .notReportedBySystem
        case .readFailed: .couldNotRead
        }
    }
}

// MARK: - View

/// Per-interface network details for the menu-bar network page.
///
/// The compact page keeps only the system primary interfaces and enabled, running tunnels. Each
/// card shows the name, state, one primary IPv4 address and the link speed; IPv6 address lists,
/// address scopes and MTU stay hidden by the user's choice. A primary IPv6 read failure is still
/// shown in the primary block, so it cannot be mistaken for "none reported".
///
/// This view only presents the `NetworkDetailsSnapshot` it is given. It does not sample, refresh,
/// start a timer or test reachability; the caller decides when to obtain a snapshot and when to
/// replace this view's value. Integration: obtain a snapshot off the main thread with
/// `NetworkDetailsSampler`, pass it to `NetworkDetailsContent(snapshot:)`, and keep the existing
/// page's scroll/refresh ownership. The dedicated `NetworkDetails` string table must be included
/// in the app target (XcodeGen picks up `App/Resources` automatically).
struct NetworkDetailsContent: View {
    let snapshot: NetworkDetailsSnapshot

    @ScaledMetric(relativeTo: .body) private var labelSize: CGFloat = 10.5
    @ScaledMetric(relativeTo: .body) private var valueSize: CGFloat = 12.5
    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 13

    init(snapshot: NetworkDetailsSnapshot) {
        self.snapshot = snapshot
    }

    var body: some View {
        let display = NetworkDetailsDisplay(snapshot: snapshot)
        VStack(alignment: .leading, spacing: 12) {
            if display.showsPrimarySummary {
                primaries(display)
            }
            interfaces(display)
            notes(display)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: NetworkDetailsText.networkDetails.localized()))
    }

    private func primaries(_ display: NetworkDetailsDisplay) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionHeader(.systemPrimary)
            if display.primaryFields.contains(.ipv4) {
                field(.primaryIPv4,
                      value: primaryValue(display.primaryIPv4),
                      note: primaryNote(display.primaryIPv4))
            }
            if display.primaryFields.contains(.ipv6) {
                field(.primaryIPv6,
                      value: primaryValue(display.primaryIPv6),
                      note: primaryNote(display.primaryIPv6))
            }
        }
    }

    @ViewBuilder
    private func interfaces(_ display: NetworkDetailsDisplay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(.interfaces)
            switch display.source {
            case .unavailable(let reason):
                let copy = NetworkDetailsSourceMessage.copy(for: reason)
                statusMessage(title: copy.title, detail: copy.detail)
            case .empty:
                statusMessage(title: .noInterfaceToShow, detail: .noInterfaceToShowExplanation)
            case .noActiveInterfaces:
                statusMessage(title: .noActiveInterfaces, detail: .noActiveInterfacesExplanation)
            case .interfaces(let interfaces):
                ForEach(interfaces) { interfaceCard($0) }
            }
        }
    }

    private func notes(_ display: NetworkDetailsDisplay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(NetworkDetailsText.primaryFootnote.localized())
                .font(.mh(size: labelSize))
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            if display.hasTunnel {
                Text(NetworkDetailsText.tunnelFootnote.localized())
                    .font(.mh(size: labelSize))
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private func interfaceCard(_ interface: NetworkDetailsDisplay.Interface) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    identity(interface)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) { badges(interface) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    identity(interface)
                    VStack(alignment: .leading, spacing: 4) { badges(interface) }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ipv4Field(interface.ipv4Address)
                linkSpeedField(interface.linkSpeed)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.inset, in: SurfaceShape(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func identity(_ interface: NetworkDetailsDisplay.Interface) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(interface.title)
                .font(.mh(size: titleSize, weight: .semibold))
                .foregroundStyle(Palette.text)
            if interface.title != interface.name {
                Text(interface.name)
                    .font(.mh(size: labelSize, design: .monospaced))
                    .foregroundStyle(Palette.textFaint)
            }
        }
    }

    @ViewBuilder
    private func badges(_ interface: NetworkDetailsDisplay.Interface) -> some View {
        Pill(text: interface.status.label.localized(), color: interface.status.tint)
        // A tunnel keeps the neutral kind name "Tunnel": the kind alone does not prove a VPN.
        Pill(text: interface.kind.label.localized(), color: interface.kind.tint)
        if interface.isPrimaryIPv4 {
            Pill(text: NetworkDetailsText.primaryIPv4.localized(), color: Theme.blue)
        }
        if interface.isPrimaryIPv6 {
            Pill(text: NetworkDetailsText.primaryIPv6.localized(), color: Theme.cyan)
        }
    }

    /// A flexible field instead of `KeyValueRow`: that shared row has a fixed 25 pt height and one
    /// line, which clips longer values and larger text.
    private func field(_ label: NetworkDetailsText,
                       value: String,
                       note: String? = nil,
                       valueColor: Color = Palette.text) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.localized())
                .font(.mh(size: labelSize, weight: .medium))
                .foregroundStyle(Palette.textFaint)
            Text(value)
                .font(.mh(size: valueSize, design: .monospaced))
                .foregroundStyle(valueColor)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note)
                    .font(.mh(size: labelSize))
                    .foregroundStyle(Theme.amber)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func ipv4Field(_ address: String?) -> some View {
        field(.ipv4,
              value: address ?? NetworkDetailsText.noneReported.localized(),
              valueColor: address == nil ? Palette.textMuted : Palette.text)
    }

    private func linkSpeedField(_ value: NetworkDetailsDisplay.FieldValue<UInt64>) -> some View {
        switch value {
        case .available(let bitsPerSecond):
            field(.linkSpeed, value: NetworkDetailsFormat.linkSpeed(bitsPerSecond))
        case .unavailable(let reason):
            field(.linkSpeed, value: reason.label.localized(), valueColor: Palette.textMuted)
        }
    }

    private func statusMessage(title: NetworkDetailsText, detail: NetworkDetailsText) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.localized())
                .font(.mh(size: valueSize, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text(detail.localized())
                .font(.mh(size: labelSize))
                .foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.inset, in: SurfaceShape(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Mirrors the shared `HairlineHeader`'s hairlines, spacing and muted caption. The shared
    /// component always resolves its key against the main string table, so this view keeps its own
    /// small header for the dedicated `NetworkDetails` table.
    private func sectionHeader(_ text: NetworkDetailsText) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Text(text.localized())
                .font(.mh(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
                .fixedSize()
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .padding(.top, 8)
        .accessibilityAddTraits(.isHeader)
    }

    private func primaryValue(_ primary: NetworkDetailsDisplay.Primary) -> String {
        switch primary.state {
        case .interface(let name):
            if let displayName = primary.displayName, !displayName.isEmpty, displayName != name {
                return "\(displayName) (\(name))"
            }
            return name
        case .none:
            return NetworkDetailsText.noneReported.localized()
        case .unknown:
            return NetworkDetailsText.couldNotRead.localized()
        }
    }

    private func primaryNote(_ primary: NetworkDetailsDisplay.Primary) -> String? {
        primary.isListed == false ? NetworkDetailsText.notListed.localized() : nil
    }
}
