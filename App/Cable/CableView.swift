import Cable
import SwiftUI

struct CableView: View {
    let app: AppModel
    @Bindable var model: CableModel
    @State private var isOnScreen = false
    /// Half a screen: the four summary cards read as a two-by-two grid.
    @Environment(\.isCompactPage) private var compact

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ThemeStore.shared.isSoft ? 22 : 20) {
                header
                if let content = model.content {
                    summaryStrip(content)
                    portsSection(content)
                    ChargingDiagnosticsSection(power: content.power, findings: content.findings)
                    DevicesSection(usbDevices: content.usbDevices, thunderboltDevices: content.thunderboltDevices)
                    DisplaysSection(displays: content.displays)
                } else {
                    loadingPlaceholder
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animatesStates(model.content == nil)
        }
        .onAppear {
            isOnScreen = true
            model.setVisible(app.hasVisibleMainWindow)
        }
        .onDisappear {
            isOnScreen = false
            model.setVisible(false)
        }
        .onChange(of: app.hasVisibleMainWindow) { _, visible in
            model.setVisible(isOnScreen && visible)
        }
        // Re-reading the ports sits in the window toolbar and the Actions menu (⌘R).
        .focusedSceneValue(\.pageCommands, PageCommands(refresh: PageCommand(id: "refresh", title: "Refresh",
                                                                           systemImage: "arrow.clockwise",
                                                                           isEnabled: !model.refreshing) {
            model.refreshNow()
        }))
    }

    // MARK: - Header

    private var header: some View {
        PageHeader(
            section: .cable,
            subtitle: String(localized: "USB-C and Thunderbolt ports, cable ratings, charging diagnostics, devices and displays.")
        ) {
            HStack(spacing: 10) {
                if model.refreshing {
                    ProgressView().controlSize(.small)
                } else if model.isMonitoring {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.mint)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text("Live")
                            .font(.mhCaption.weight(.medium))
                            .foregroundStyle(Palette.textMuted)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background {
                        if ThemeStore.shared.isSoft {
                            SoftSurface.recessed(SurfaceShape.capsule, depth: .meter)
                        } else {
                            SurfaceShape.capsule.fill(Palette.inset)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Summary strip

    private func summaryStrip(_ content: CableSnapshotContent) -> some View {
        let connectedCount = content.connectedPorts.count
        let totalPorts = content.ports.count
        let peakCable = content.strongestConnectedCable
        let peakValue: String = {
            if let watts = peakCable?.maxWatts {
                return "\(watts) W"
            }
            if let gbps = peakCable?.speed.gigabitsPerSecond {
                return "\(Int(gbps)) Gbps"
            }
            return "—"
        }()
        let peakDetail: String = {
            guard let peakCable else { return String(localized: "No e-marked cable") }
            var parts: [String] = []
            if let gbps = peakCable.speed.gigabitsPerSecond {
                parts.append("\(Int(gbps)) Gbps")
            }
            if let current = CableFormatting.cableCurrentLabel(peakCable.current) {
                parts.append(current)
            }
            return parts.isEmpty ? CableFormatting.cableKindLabel(peakCable.kind) : parts.joined(separator: " · ")
        }()

        let totalDevices = content.usbDeviceCount + content.thunderboltDevices.count
        let deviceDetail: String = {
            if content.thunderboltDevices.isEmpty {
                return String(localized: "\(content.usbDeviceCount) USB")
            }
            return String(localized: "\(content.thunderboltDevices.count) Thunderbolt · \(content.usbDeviceCount) USB")
        }()

        let displayDetail: String = {
            guard let first = content.displays.first else { return String(localized: "None detected") }
            if let w = first.width, let h = first.height {
                if let hz = first.refreshHz {
                    return "\(w)×\(h) · \(CableFormatting.refreshRate(hz))"
                }
                return "\(w)×\(h)"
            }
            return first.name
        }()

        return Group {
            if compact {
                // Half a screen: two columns of two, so each card keeps a readable value.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2),
                          alignment: .leading, spacing: 12) {
                    cards(connectedCount: connectedCount, totalPorts: totalPorts, peakValue: peakValue,
                          peakDetail: peakDetail, peakCable: peakCable, totalDevices: totalDevices,
                          deviceDetail: deviceDetail, displayDetail: displayDetail, content: content)
                }
            } else {
                HStack(spacing: ThemeStore.shared.isSoft ? 14 : 12) {
                    cards(connectedCount: connectedCount, totalPorts: totalPorts, peakValue: peakValue,
                          peakDetail: peakDetail, peakCable: peakCable, totalDevices: totalDevices,
                          deviceDetail: deviceDetail, displayDetail: displayDetail, content: content)
                }
            }
        }
    }

    @ViewBuilder
    private func cards(connectedCount: Int, totalPorts: Int, peakValue: String, peakDetail: String,
                       peakCable: CableSpec?, totalDevices: Int, deviceDetail: String,
                       displayDetail: String, content: CableSnapshotContent) -> some View {
        StatCard(
            title: "USB-C Ports",
            value: "\(connectedCount) / \(totalPorts)",
            detail: String(localized: "\(connectedCount) connected"),
            detailColor: connectedCount > 0 ? Theme.mint : Palette.textMuted,
            accent: Theme.blue,
            symbol: "cable.connector",
            compact: true
        )
        StatCard(
            title: "Top Cable Rating",
            value: peakValue,
            detail: peakDetail,
            detailColor: peakCable != nil ? Palette.textMuted : Palette.textFaint,
            accent: Theme.amber,
            symbol: "bolt.fill",
            compact: true
        )
        StatCard(
            title: "Connected Devices",
            value: "\(totalDevices)",
            detail: deviceDetail,
            accent: Theme.cyan,
            symbol: "point.3.connected.trianglepath.dotted",
            compact: true
        )
        StatCard(
            title: "Displays",
            value: "\(content.displays.count)",
            detail: displayDetail,
            accent: Theme.violet,
            symbol: "display",
            compact: true
        )
    }

    // MARK: - Ports

    private func portsSection(_ content: CableSnapshotContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CableSectionHeader(
                title: "USB-C & Thunderbolt Ports",
                trailing: String(localized: "\(content.connectedPorts.count) of \(content.ports.count) connected")
            )
            if content.ports.isEmpty {
                Text("No USB-C or Thunderbolt ports reported on this Mac.")
                    .font(.mhCallout)
                    .foregroundStyle(Palette.textMuted)
                    .card()
            } else {
                if !content.connectedPorts.isEmpty {
                    let gap: CGFloat = ThemeStore.shared.isSoft ? 14 : 12
                    let count = content.connectedPorts.count
                    // Half a screen fits one port card: two of them squeeze the "Connected" pill
                    // into the port name. A full window keeps the wide pairs.
                    let columnCount = compact ? 1 : count == 4 ? 2 : min(max(count, 1), 3)
                    let columns = Array(repeating: GridItem(.flexible(), spacing: gap, alignment: .top), count: columnCount)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                        ForEach(content.connectedPorts, id: \.id) { port in
                            ConnectedPortCard(port: port)
                        }
                    }
                }
                if !content.unconnectedPorts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unused Ports")
                            .font(.mh(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.textMuted)
                        let compactColumns = [GridItem(.adaptive(minimum: 205, maximum: 260), spacing: 8, alignment: .top)]
                        LazyVGrid(columns: compactColumns, alignment: .leading, spacing: 8) {
                            ForEach(content.unconnectedPorts, id: \.id) { port in
                                EmptyPortChip(port: port)
                            }
                        }
                    }
                    .padding(.top, content.connectedPorts.isEmpty ? 0 : 2)
                }
            }
        }
    }

    // MARK: - Loading placeholder

    private var loadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 14) {
            SkeletonRows(count: 4).card()
            SkeletonRows(count: 3).card()
        }
    }
}

/// Consistent section heading across the Cable page.
struct CableSectionHeader: View {
    let title: LocalizedStringKey
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Theme.heading)
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.mhCaption)
                    .foregroundStyle(Palette.textMuted)
            }
        }
    }
}
