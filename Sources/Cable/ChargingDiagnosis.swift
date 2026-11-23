import Foundation

/// Pure charging diagnosis. No IOKit, no global state: callers pass the same
/// typed snapshot the UI and CLI display, so every rule is independently testable.
public enum ChargingDiagnosis {
    /// Transports that carry data. A port that carries any of them is a hub, a
    /// display or a dock rather than a plain charger receptacle.
    private static let dataTransports: Set<Transport> = [.usb2, .usb3, .cio, .displayPort]

    public static func evaluate(
        power: PowerState,
        ports: [PortStatus] = [],
        usbDevices: [USBDeviceNode] = [],
        displays: [DisplayInfo] = []
    ) -> [ChargingFinding] {
        // A Mac mini / Mac Studio exposes AppleSmartBattery with FamilyCode 0.
        // Reporting "not charging" there would be invented data.
        if power.isDesktopWithoutBattery {
            return [ChargingFinding(
                id: "charging.notApplicable.desktop",
                severity: .info,
                title: "Charging diagnosis not applicable",
                reason: power.batteryInstalled == false
                    ? "This Mac reports BatteryInstalled = false; it has no internal battery to charge."
                    : "This model is a desktop Mac without an internal battery.",
                recommendation: "Check adapter and system power readings instead; no battery charging state can be diagnosed."
            )]
        }

        var findings: [ChargingFinding] = []
        let connectedPorts = ports.filter { $0.connected == true }
        // A charger answers Discover Identity as SOP and carries no data: that is
        // what separates the charging port from a keyboard or a dock on another
        // port. Cables on those other ports must not produce charging warnings.
        let chargingPorts = connectedPorts.filter { port in
            port.partner?.vendorID != nil && !port.activeTransports.contains(where: dataTransports.contains)
        }
        let cablePorts = chargingPorts.isEmpty ? connectedPorts : chargingPorts
        let cablePortFallback = chargingPorts.isEmpty
        let watts = power.adapterWatts
        let adapterAbove60 = watts.map { $0 > 60 } ?? false

        // 1. Adapter below the model's expected wattage.
        if let watts, let recommended = power.recommendedAdapterWatts, watts < Double(recommended) {
            findings.append(ChargingFinding(
                id: "charging.adapter.underpowered",
                severity: watts < Double(recommended) * 0.6 ? .problem : .warning,
                title: "Adapter is smaller than recommended",
                reason: String(format: "The adapter reports %.0f W; this model expects at least %d W.", watts, recommended),
                recommendation: "Use the specified Apple adapter for full performance while charging."
            ))
        }

        // 2. A 3 A cable cannot carry more than 60 W.
        if adapterAbove60, let port = cablePorts.first(where: { $0.cable?.current == .amps3 }) {
            findings.append(ChargingFinding(
                id: "cable.current3a.limit60w",
                severity: cablePortFallback ? .info : .warning,
                title: "3 A cable limits charging to 60 W",
                reason: cablePortFallback
                    ? String(format: "No port is identifiable as the charging port. If the charger is connected to %@, its e-marker reports 3 A while the adapter can deliver %.0f W.", port.id, watts ?? 0)
                    : String(format: "The e-marker on %@ reports 3 A while the adapter can deliver %.0f W.", port.id, watts ?? 0),
                recommendation: "Use a 5 A e-marked cable for 100 W or EPR charging."
            ))
        }

        // 3. No e-marker means the source must stay at 3 A / 60 W.
        if adapterAbove60, let port = cablePorts.first(where: { $0.cable?.kind == .absent }) {
            findings.append(ChargingFinding(
                id: "cable.noEmarker",
                severity: cablePortFallback ? .info : .warning,
                title: "No e-marker on the connected cable",
                reason: cablePortFallback
                    ? "No port is identifiable as the charging port. If the charger is connected to \(port.id), its cable did not answer Discover Identity, so the source falls back to 3 A / 60 W."
                    : "The cable on \(port.id) did not answer Discover Identity, so the source falls back to 3 A / 60 W.",
                recommendation: "Use an e-marked USB-C cable if the adapter offers more than 60 W."
            ))
        }

        // 4. Charging paused for a reported reason.
        if power.externalConnected == true, power.isCharging == false, !power.notChargingReasons.isEmpty {
            let thermal = power.notChargingReasons.contains { $0.localizedCaseInsensitiveContains("temperature") }
            findings.append(ChargingFinding(
                id: "charging.paused.reason",
                severity: thermal ? .problem : .warning,
                title: "Charging is paused",
                reason: "NotChargingReason: " + power.notChargingReasons.joined(separator: "; ") + ".",
                recommendation: thermal
                    ? "Let the Mac cool down and make sure its vents are unobstructed."
                    : "Check the adapter, cable and any charging limit before expecting a full charge."
            ))
        }

        // 5. Power shared through a dock or a display: a port with a PD partner that
        // also carries DisplayPort, Thunderbolt/USB4, a USB hub's traffic or a USB-C
        // display. HDMI shares port numbers with USB-C, so only USB-C displays count.
        let hubPorts = Set(flattenDevices(usbDevices).filter(\.isHub).compactMap(\.portNumber))
        let displayPorts = Set(displays.filter { ($0.connectionType ?? "").localizedCaseInsensitiveContains("USB-C") }.compactMap(\.portNumber))
        let dockTransports: Set<Transport> = [.displayPort, .cio]
        let supplyPorts = connectedPorts.filter { port in
            guard port.partner?.vendorID != nil else { return false }
            if port.activeTransports.contains(where: dockTransports.contains) { return true }
            guard let number = port.number else { return false }
            return hubPorts.contains(number) || displayPorts.contains(number)
        }
        // A dock only explains slow charging when the Mac runs on external power and no
        // other port has a plain charger on it: a laptop on its own charger with a
        // Thunderbolt dock beside it is not charging through the dock.
        let supplyIDs = Set(supplyPorts.map(\.id))
        let dedicatedChargers = chargingPorts.filter { !supplyIDs.contains($0.id) }
        if power.externalConnected == true, dedicatedChargers.isEmpty, let port = supplyPorts.first {
            findings.append(ChargingFinding(
                id: "charging.throughHubOrDisplay",
                severity: .info,
                title: "Power may be shared through a hub or display",
                reason: "\(port.id) has a PD partner and carries DisplayPort, Thunderbolt/USB4 or USB hub traffic, so the charger may reach the Mac through that dock or display.",
                recommendation: "Connect the charger directly to the Mac if charging seems slow."
            ))
        }

        // 6. Battery temperature.
        if let temperature = power.temperatureCelsius, temperature >= 40 {
            findings.append(ChargingFinding(
                id: "battery.overheating",
                severity: temperature >= 45 ? .problem : .warning,
                title: "Battery is hot",
                reason: String(format: "AppleSmartBattery reports %.1f °C.", temperature),
                recommendation: "Move the Mac to a cooler place and check for a demanding workload."
            ))
        }

        // 7. A device negotiating far below its own capability. maxSpeedMbps is only
        // set when the descriptors prove a USB 3 link, so this cannot fire for a
        // device whose capability IORegistry does not describe.
        for device in flattenDevices(usbDevices) {
            guard let negotiated = device.negotiatedSpeedMbps, let maximum = device.maxSpeedMbps,
                  maximum >= 5_000, negotiated <= 480 else { continue }
            findings.append(ChargingFinding(
                id: "device.speedBottleneck.\(device.locationID.map(String.init) ?? device.name)",
                severity: .warning,
                title: "\(device.name) is running at USB 2.0 speed",
                reason: "The device supports \(maximum / 1000) Gbps but negotiated \(negotiated) Mbps.",
                recommendation: "Try a USB 3.x cable or connect the device directly instead of through a USB 2.0 hub."
            ))
        }

        return findings
    }

    private static func flattenDevices(_ nodes: [USBDeviceNode]) -> [USBDeviceNode] {
        nodes.flatMap { [$0] + flattenDevices($0.children) }
    }
}
