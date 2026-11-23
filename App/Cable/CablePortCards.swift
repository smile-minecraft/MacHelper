import Cable
import SwiftUI

/// Detailed card for a connected USB-C / Thunderbolt port showing link state, transports,
/// negotiated speed, power contract, and decoded cable specification.
struct ConnectedPortCard: View {
    let port: PortStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            portHeader
            linkDetails
            Spacer(minLength: 0)
            if let cable = port.cable {
                CableSpecBox(cable: cable)
            }
        }
        .modifier(CardStyle(padding: 14, fillHeight: true))
    }

    private var portHeader: some View {
        HStack(alignment: .top, spacing: 9) {
            portIconBadge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(CableFormatting.portDisplayTitle(port))
                        .font(.mh(size: 13.5, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Text(port.id)
                        .font(.mh(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(port.deviceName ?? String(localized: "Connected device"))
                    .font(.mh(size: 12.5, weight: .medium))
                    .foregroundStyle(port.deviceName != nil ? Palette.text : Palette.textMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Pill(text: String(localized: "Connected"), color: Theme.mint)
                if let orientation = CableFormatting.orientationLabel(port.orientation) {
                    Text(orientation)
                        .font(.mhCaption2)
                        .foregroundStyle(Palette.textFaint)
                }
            }
        }
    }

    private var portIconBadge: some View {
        let isThunderbolt = port.activeTransports.contains(.cio)
        let tint = isThunderbolt ? Theme.violet : Theme.blue
        let shape = SurfaceShape(cornerRadius: ThemeStore.shared.isSoft ? 10 : 8)
        return Image(systemName: isThunderbolt ? "bolt.horizontal.fill" : "cable.connector")
            .font(.mh(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background {
                if ThemeStore.shared.isSoft {
                    ZStack {
                        SoftSurface.recessed(shape, depth: .meter)
                        shape.fill(tint.opacity(0.10))
                    }
                } else {
                    shape.fill(tint.opacity(0.14))
                }
            }
            .accessibilityHidden(true)
    }

    private var linkDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !port.activeTransports.isEmpty {
                HStack(spacing: 6) {
                    ForEach(displayTransports, id: \.self) { transport in
                        TransportBadge(transport: transport)
                    }
                }
            }

            if let speed = port.negotiatedSpeed {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Link")
                        .font(.mhCaption)
                        .foregroundStyle(Palette.textMuted)
                    Text(speed)
                        .font(.mh(size: 12, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let contractText = powerContractSummary {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Power")
                        .font(.mhCaption)
                        .foregroundStyle(Palette.textMuted)
                    Text(contractText)
                        .font(.mh(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.amber)
                }
            }

            if let partner = partnerSummary {
                Text(partner)
                    .font(.mh(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.textFaint)
            }
        }
    }

    private var displayTransports: [Transport] {
        // Put data/video transports before CC so the primary link stands out first.
        let order: [Transport] = [.cio, .displayPort, .pcie, .usb3, .usb2, .cc, .other]
        return order.filter { port.activeTransports.contains($0) }
    }

    private var powerContractSummary: String? {
        guard let contract = port.powerContract else { return nil }
        var parts: [String] = []
        if let watts = contract.watts { parts.append(String(format: "%.1f W", watts)) }
        if let volts = contract.volts { parts.append(String(format: "%.1f V", volts)) }
        if let amps = contract.amps { parts.append(String(format: "%.2f A", amps)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var partnerSummary: String? {
        guard let partner = port.partner else { return nil }
        var parts: [String] = []
        if let name = partner.productName, !name.isEmpty, name != port.deviceName {
            parts.append(name)
        }
        if let vid = partner.vendorID {
            if let pid = partner.productID {
                parts.append(String(localized: "Partner \(CableFormatting.hexID(vid)):\(CableFormatting.hexID(pid))"))
            } else {
                parts.append(String(localized: "Partner \(CableFormatting.hexID(vid))"))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Inset panel inside a port card displaying either the decoded e-marker cable ratings
/// or the explicit no-e-marker notice.
struct CableSpecBox: View {
    let cable: CableSpec

    var body: some View {
        let shape = SurfaceShape(cornerRadius: ThemeStore.shared.isSoft ? 12 : 8)
        Group {
            if cable.kind == .absent {
                noEmarkerContent
            } else if cable.kind == .unknown && cable.maxWatts == nil && cable.speed == .unknown {
                unknownCableContent
            } else {
                decodedCableContent
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if ThemeStore.shared.isSoft {
                SoftSurface.recessed(shape, depth: .track)
            } else {
                shape.fill(Palette.inset.opacity(0.7))
                    .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
            }
        }
    }

    private var noEmarkerContent: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.mh(size: 13))
                .foregroundStyle(Theme.amber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("No e-marker")
                    .font(.mh(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                Text("No e-marker: up to 3 A / 60 W, data rate unknown.")
                    .font(.mhCaption)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unknownCableContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.mh(size: 12))
                .foregroundStyle(Palette.textFaint)
                .accessibilityHidden(true)
            Text("Cable identity unknown")
                .font(.mhCaption)
                .foregroundStyle(Palette.textMuted)
        }
    }

    private var decodedCableContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.mh(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                    .accessibilityHidden(true)
                Text(CableFormatting.cableKindLabel(cable.kind))
                    .font(.mh(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                if cable.eprCapable == true {
                    Pill(text: "EPR", color: Theme.amber)
                }
                if let plug = CableFormatting.cablePlugLabel(cable.plug) {
                    Text(plug)
                        .font(.mhCaption2)
                        .foregroundStyle(Palette.textFaint)
                }
                Spacer(minLength: 4)
                if let vid = cable.vendorID {
                    Text(String(localized: "Vendor \(CableFormatting.hexID(vid))"))
                        .font(.mh(size: 10.5, design: .monospaced))
                        .foregroundStyle(Palette.textMuted)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                specColumn(label: "Data Rate", value: CableFormatting.cableSpeedLabel(cable.speed))
                HStack(alignment: .top, spacing: 14) {
                    if let current = CableFormatting.cableCurrentLabel(cable.current) {
                        specColumn(label: "Max Current", value: current)
                    }
                    if let maxWatts = cable.maxWatts {
                        let wattsText = "\(maxWatts) W"
                        let detail = CableFormatting.cableVoltageLabel(cable.voltage)
                        specColumn(label: "Max Power", value: detail.map { "\(wattsText) (\($0))" } ?? wattsText, accent: Theme.amber)
                    }
                }
            }

            if let metadataLine = secondaryMetadataLine {
                Text(metadataLine)
                    .font(.mhCaption2)
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func specColumn(label: LocalizedStringKey, value: String, accent: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.mhCaption2)
                .foregroundStyle(Palette.textFaint)
            Text(value)
                .font(.mh(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(accent ?? Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var secondaryMetadataLine: String? {
        var parts: [String] = []
        if let latency = CableFormatting.cableLatencyLabel(cable.latency) {
            parts.append(String(localized: "Latency \(latency)"))
        }
        if let pid = cable.productID {
            parts.append(String(localized: "Product \(CableFormatting.hexID(pid))"))
        }
        if let active = cable.active {
            if let copper = active.copper {
                parts.append(copper ? String(localized: "Copper") : String(localized: "Optical"))
            }
            if let retimer = active.retimer {
                parts.append(retimer ? String(localized: "Retimer") : String(localized: "Redriver"))
            }
            if let maxTemp = active.maximumOperatingCelsius {
                parts.append(String(localized: "Max \(maxTemp) °C"))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Compact pill-card for an unconnected USB-C port so unused ports never clutter the layout.
struct EmptyPortChip: View {
    let port: PortStatus

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Palette.textFaint.opacity(0.45))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(CableFormatting.portDisplayTitle(port))
                .font(.mh(size: 12, weight: .medium))
                .foregroundStyle(Palette.textMuted)
            Text(port.id)
                .font(.mh(size: 10, design: .monospaced))
                .foregroundStyle(Palette.textFaint)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(port.connected == false ? String(localized: "Empty") : String(localized: "Unknown"))
                .font(.mhCaption)
                .foregroundStyle(Palette.textFaint)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .opacity(0.85)
    }
}

/// Compact transport protocol badge (Thunderbolt/USB4, USB 3, USB 2, DisplayPort, PCIe, PD).
struct TransportBadge: View {
    let transport: Transport

    var body: some View {
        Pill(text: CableFormatting.transportLabel(transport), color: tint)
    }

    private var tint: Color {
        switch transport {
        case .cio: Theme.violet
        case .usb3: Theme.blue
        case .usb2: Theme.cyan
        case .displayPort: Theme.mint
        case .pcie: Theme.orange
        case .cc, .other: Palette.textMuted
        }
    }
}
