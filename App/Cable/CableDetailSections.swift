import Cable
import SwiftUI

// MARK: - Charging Diagnostics

struct ChargingDiagnosticsSection: View {
    let power: PowerState
    let findings: [ChargingFinding]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CableSectionHeader(
                title: "Charging Diagnostics",
                trailing: headerTrailing
            )
            if power.isDesktopWithoutBattery {
                desktopNoticeCard
            } else {
                batteryPowerSummary
                findingsList
            }
        }
    }

    private var headerTrailing: String {
        if power.isDesktopWithoutBattery {
            return String(localized: "Not applicable")
        }
        if findings.isEmpty {
            return String(localized: "No issues")
        }
        return String(localized: "\(findings.count) findings")
    }

    private var desktopNoticeCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.mhTitle3)
                .foregroundStyle(Theme.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("This Mac has no battery, so charging diagnosis does not apply.")
                    .font(.mhHeadline)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Battery charging checks only apply to portable Macs with an internal battery.")
                    .font(.mhCallout)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private struct PowerStatItem: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let value: String
        let color: Color
    }

    @ViewBuilder
    private var batteryPowerSummary: some View {
        let items = powerStats
        if !items.isEmpty {
            HStack(alignment: .top, spacing: 20) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(.mhCaption)
                            .foregroundStyle(Palette.textMuted)
                        Text(item.value)
                            .font(Theme.smallNumeral)
                            .foregroundStyle(item.color)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .card()
        }
    }

    private var powerStats: [PowerStatItem] {
        var result: [PowerStatItem] = []
        if let watts = power.adapterWatts {
            var text = String(format: "%.0f W", watts)
            if let recommended = power.recommendedAdapterWatts {
                text += " / \(recommended) W"
            }
            result.append(PowerStatItem(id: "adapter", label: "Adapter", value: text, color: Palette.text))
        }
        if let external = power.externalConnected {
            let status: String
            let color: Color
            if !external {
                status = String(localized: "On battery")
                color = Palette.textMuted
            } else if power.isCharging == true {
                status = String(localized: "Charging")
                color = Theme.mint
            } else {
                status = String(localized: "Not charging")
                color = Theme.amber
            }
            result.append(PowerStatItem(id: "status", label: "Status", value: status, color: color))
        }
        if let temp = power.temperatureCelsius {
            let color = temp >= 45 ? Theme.rose : temp >= 40 ? Theme.amber : Palette.text
            result.append(PowerStatItem(id: "temp", label: "Battery Temp", value: String(format: "%.1f °C", temp), color: color))
        }
        if let limit = power.chargeLimitPercent {
            result.append(PowerStatItem(id: "limit", label: "Charge Limit", value: "\(limit)%", color: Palette.text))
        }
        return result
    }

    private var findingsList: some View {
        VStack(alignment: .leading, spacing: ThemeStore.shared.isSoft ? 12 : 8) {
            if findings.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.mhTitle3)
                        .foregroundStyle(Theme.mint)
                        .accessibilityHidden(true)
                    Text("No charging issues detected.")
                        .font(.mhHeadline)
                        .foregroundStyle(Theme.mint)
                }
                .card()
            } else {
                ForEach(findings, id: \.id) { finding in
                    findingCard(finding)
                }
            }
        }
    }

    private func findingCard(_ finding: ChargingFinding) -> some View {
        let tone = severityColor(finding.severity)
        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: severitySymbol(finding.severity))
                .font(.mhTitle3)
                .foregroundStyle(tone)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(finding.title)
                        .font(.mhHeadline)
                        .foregroundStyle(Palette.text)
                    Pill(text: severityLabel(finding.severity), color: tone)
                }
                Text(finding.reason)
                    .font(.mhCallout)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.mhCaption)
                        .foregroundStyle(tone)
                        .accessibilityHidden(true)
                    Text(finding.recommendation)
                        .font(.mhCallout)
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func severitySymbol(_ severity: FindingSeverity) -> String {
        switch severity {
        case .problem: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private func severityColor(_ severity: FindingSeverity) -> Color {
        switch severity {
        case .problem: Theme.rose
        case .warning: Theme.amber
        case .info: Theme.blue
        }
    }

    private func severityLabel(_ severity: FindingSeverity) -> String {
        switch severity {
        case .problem: String(localized: "Problem")
        case .warning: String(localized: "Warning")
        case .info: String(localized: "Info")
        }
    }
}

// MARK: - External Devices (Thunderbolt + USB Tree)

struct DevicesSection: View {
    let usbDevices: [USBDeviceNode]
    let thunderboltDevices: [ThunderboltDevice]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CableSectionHeader(
                title: "External Devices",
                trailing: summaryTrailing
            )

            if !thunderboltDevices.isEmpty {
                thunderboltCard
            }

            usbTreeCard
        }
    }

    private var summaryTrailing: String {
        let usbCount = countDevices(usbDevices)
        if thunderboltDevices.isEmpty {
            return String(localized: "\(usbCount) USB")
        }
        return String(localized: "\(thunderboltDevices.count) Thunderbolt · \(usbCount) USB")
    }

    private func countDevices(_ nodes: [USBDeviceNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + countDevices($1.children) }
    }

    private var thunderboltCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Thunderbolt / USB4 Devices")
            ForEach(Array(thunderboltDevices.enumerated()), id: \.offset) { index, device in
                if index > 0 {
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bolt.horizontal.fill")
                        .font(.mh(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.violet)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(device.name)
                                .font(.mh(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.text)
                            if let port = device.portNumber {
                                Pill(text: String(localized: "Port \(port)"), color: Theme.violet)
                            }
                        }
                        if let codes = CableFormatting.thunderboltCodes(device) {
                            Text(codes)
                                .font(.mhCaption)
                                .foregroundStyle(Palette.textMuted)
                        }
                    }
                    Spacer(minLength: 8)
                    if let vid = device.vendorID {
                        let idText = device.deviceID.map { "\(CableFormatting.hexID(vid)):\(CableFormatting.hexID($0))" }
                            ?? CableFormatting.hexID(vid)
                        Text(idText)
                            .font(.mh(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.textFaint)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .card()
    }

    private var usbTreeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "USB Device Tree")
            if usbDevices.isEmpty {
                Text("No USB devices detected.")
                    .font(.mhCallout)
                    .foregroundStyle(Palette.textMuted)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(usbDevices.enumerated()), id: \.offset) { index, root in
                        if index > 0 {
                            Rectangle()
                                .fill(Palette.hairline)
                                .frame(height: 1)
                                .padding(.vertical, 6)
                        }
                        USBDeviceTreeNodeView(node: root, depth: 0)
                    }
                }
            }
        }
        .card()
    }
}

private struct USBDeviceTreeNodeView: View {
    let node: USBDeviceNode
    let depth: Int

    var body: some View {
        let bottleneck = CableFormatting.isSpeedBelowCapability(node)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                if depth > 0 {
                    HStack(spacing: 0) {
                        ForEach(0..<depth, id: \.self) { level in
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(Palette.hairline)
                                    .frame(width: 1, height: 22)
                                    .padding(.leading, 8)
                                if level == depth - 1 {
                                    Rectangle()
                                        .fill(Palette.hairline)
                                        .frame(width: 10, height: 1)
                                } else {
                                    Spacer().frame(width: 10)
                                }
                            }
                        }
                    }
                    .accessibilityHidden(true)
                }

                Image(systemName: nodeIcon)
                    .font(.mh(size: 11.5, weight: .medium))
                    .foregroundStyle(nodeIconColor)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(node.name)
                            .font(.mh(size: 12.5, weight: node.isHub ? .semibold : .medium))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        if node.isHub {
                            Pill(text: String(localized: "Hub"), color: Palette.textMuted)
                        }
                        portTag
                        if bottleneck {
                            Pill(text: String(localized: "Speed below capability"), color: Theme.amber)
                        }
                    }
                    if let subtitle = deviceSubtitle(bottleneck: bottleneck) {
                        Text(subtitle)
                            .font(.mhCaption2)
                            .foregroundStyle(bottleneck ? Theme.amber : Palette.textFaint)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(CableFormatting.usbSpeed(node.negotiatedSpeedMbps))
                        .font(.mh(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(bottleneck ? Theme.amber : Palette.text)
                    if let maxMbps = node.maxSpeedMbps, maxMbps != node.negotiatedSpeedMbps {
                        Text(String(localized: "Capable ≥ \(CableFormatting.usbSpeed(maxMbps))"))
                            .font(.mhCaption2.monospacedDigit())
                            .foregroundStyle(Palette.textFaint)
                    }
                }
            }
            .padding(.vertical, 4)

            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                USBDeviceTreeNodeView(node: child, depth: depth + 1)
            }
        }
    }

    @ViewBuilder
    private var portTag: some View {
        if let port = node.portNumber {
            Pill(text: String(localized: "Port \(port)"), color: Theme.blue)
        } else if node.isBuiltIn {
            Pill(text: String(localized: "Mac Built-in"), color: Palette.textMuted)
        } else {
            Pill(text: String(localized: "Port unknown"), color: Palette.textFaint)
        }
    }

    private var nodeIcon: String {
        if node.isBuiltIn && node.isHub { return "macmini" }
        if node.isHub { return "point.3.connected.trianglepath.dotted" }
        return "cable.connector.horizontal"
    }

    private var nodeIconColor: Color {
        if CableFormatting.isSpeedBelowCapability(node) { return Theme.amber }
        if node.isBuiltIn { return Palette.textMuted }
        if node.isHub { return Theme.cyan }
        return Theme.blue
    }

    private func deviceSubtitle(bottleneck: Bool) -> String? {
        var parts: [String] = []
        if let vendor = node.vendorName, !vendor.isEmpty, !node.name.localizedCaseInsensitiveContains(vendor) {
            parts.append(vendor)
        }
        if bottleneck, let maxMbps = node.maxSpeedMbps, let negMbps = node.negotiatedSpeedMbps {
            parts.append(String(localized: "Negotiated \(CableFormatting.usbSpeed(negMbps)) on a device capable of ≥ \(CableFormatting.usbSpeed(maxMbps))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Displays

struct DisplaysSection: View {
    let displays: [DisplayInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CableSectionHeader(
                title: "Displays",
                trailing: displays.isEmpty ? nil : String(localized: "\(displays.count) connected")
            )
            if displays.isEmpty {
                Text("No displays detected.")
                    .font(.mhCallout)
                    .foregroundStyle(Palette.textMuted)
                    .card()
            } else {
                let columns = [GridItem(.adaptive(minimum: 340, maximum: .infinity), spacing: ThemeStore.shared.isSoft ? 16 : 12, alignment: .top)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: ThemeStore.shared.isSoft ? 16 : 12) {
                    ForEach(displays, id: \.id) { display in
                        displayCard(display)
                    }
                }
            }
        }
    }

    private func displayCard(_ display: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                let shape = SurfaceShape(cornerRadius: ThemeStore.shared.isSoft ? 10 : 8)
                Image(systemName: "display")
                    .font(.mh(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.violet)
                    .frame(width: 32, height: 32)
                    .background {
                        if ThemeStore.shared.isSoft {
                            ZStack {
                                SoftSurface.recessed(shape, depth: .meter)
                                shape.fill(Theme.violet.opacity(0.10))
                            }
                        } else {
                            shape.fill(Theme.violet.opacity(0.14))
                        }
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name)
                        .font(.mh(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    if let manufacturer = display.manufacturer, !manufacturer.isEmpty {
                        Text(manufacturer)
                            .font(.mhCaption)
                            .foregroundStyle(Palette.textMuted)
                    }
                }
                Spacer(minLength: 6)
                if let connection = connectionLabel(display) {
                    Pill(text: connection, color: Theme.violet)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                if let w = display.width, let h = display.height {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Resolution")
                            .font(.mhCaption2)
                            .foregroundStyle(Palette.textFaint)
                        Text(verbatim: "\(w) × \(h)")
                            .font(Theme.smallNumeral)
                            .foregroundStyle(Palette.text)
                    }
                }
                if let hz = display.refreshHz {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Refresh Rate")
                            .font(.mhCaption2)
                            .foregroundStyle(Palette.textFaint)
                        Text(CableFormatting.refreshRate(hz))
                            .font(Theme.smallNumeral)
                            .foregroundStyle(Theme.mint)
                    }
                }
                if let linkRate = display.linkRate, !linkRate.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Link Rate")
                            .font(.mhCaption2)
                            .foregroundStyle(Palette.textFaint)
                        Text(linkRate)
                            .font(.mh(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Palette.text)
                    }
                }
            }

            let notes = displayNotes(display)
            if !notes.isEmpty {
                HStack(spacing: 6) {
                    if display.tunneled == true {
                        Pill(text: String(localized: "Tunneled"), color: Theme.cyan)
                    }
                    if let pixelNote = pixelBackingNote(display) {
                        Text(pixelNote)
                            .font(.mhCaption2.monospacedDigit())
                            .foregroundStyle(Palette.textFaint)
                    }
                }
            }
        }
        .card(padding: 15)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func connectionLabel(_ display: DisplayInfo) -> String? {
        switch (display.connectionType, display.portNumber) {
        case let (type?, port?):
            return String(localized: "\(type) · Port \(port)")
        case let (type?, nil):
            return type
        case let (nil, port?):
            return String(localized: "Port \(port)")
        case (nil, nil):
            return nil
        }
    }

    private func pixelBackingNote(_ display: DisplayInfo) -> String? {
        guard let pw = display.pixelWidth, let ph = display.pixelHeight else { return nil }
        if pw == display.width && ph == display.height { return nil }
        return String(localized: "Backing pixels \(pw) × \(ph)")
    }

    private func displayNotes(_ display: DisplayInfo) -> [String] {
        var out: [String] = []
        if display.tunneled == true { out.append("tunneled") }
        if pixelBackingNote(display) != nil { out.append("pixels") }
        return out
    }
}
