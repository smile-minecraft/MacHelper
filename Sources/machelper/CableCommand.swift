import ArgumentParser
import Cable
import Foundation

struct CableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cable",
        abstract: "Show USB-C cable, port, device, display and charging diagnostics (read-only).",
        discussion: "All commands accept --json with a stable schemaVersion. No administrator rights or hardware writes.",
        subcommands: [CableStatus.self, CablePorts.self, CableDevices.self, CableDisplays.self, CableCharging.self]
    )

    @OptionGroup var output: OutputOptions

    /// No subcommand means status; ArgumentParser calls this instead of a default
    /// subcommand so explicit names such as `ports` are not swallowed.
    func run() throws {
        var status = CableStatus()
        status.output = output
        try status.run()
    }
}

private enum CableText {
    static func watts(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.0f W", value)
    }

    static func speed(_ mbps: Int?) -> String {
        guard let mbps else { return "speed unknown" }
        return mbps >= 1000 ? "\(mbps / 1000) Gbps" : "\(mbps) Mbps"
    }

    static func connected(_ port: PortStatus) -> String {
        switch port.connected {
        case .some(true): return "connected"
        case .some(false): return "empty"
        case .none: return "unknown"
        }
    }

    static func transports(_ port: PortStatus) -> String {
        port.activeTransports.map(\.rawValue).joined(separator: ",")
    }

    static func cable(_ spec: CableSpec?) -> String {
        guard let spec else { return "no cable identity" }
        return spec.summary + (spec.maxWatts.map { " / \($0) W max" } ?? "")
    }

    static func deviceTree(_ nodes: [USBDeviceNode], indent: String = "") {
        for node in nodes {
            let hub = node.isHub ? " [hub]" : ""
            let port = node.portNumber.map { " port \($0)" } ?? " (built in; port unknown)"
            // No "max" claim when the descriptor does not prove a speed.
            let maximum = node.maxSpeedMbps.map { " / max \(speed($0))" } ?? ""
            Output.line("\(indent)\(node.name)\(hub)\(port)  \(speed(node.negotiatedSpeedMbps))\(maximum)")
            deviceTree(node.children, indent: indent + "  ")
        }
    }
}

private enum CableJSON {
    struct Status: Encodable {
        let schemaVersion = 1
        let generatedAt: Date
        let machineModel: String?
        let ports: [PortStatus]
        let cables: [CableSpec]
        let usbDevices: [USBDeviceNode]
        let thunderboltDevices: [ThunderboltDevice]
        let displays: [DisplayInfo]
        let power: PowerState
        let findings: [ChargingFinding]
    }

    struct Ports: Encodable {
        let schemaVersion = 1
        let ports: [PortStatus]
        let cables: [CableSpec]
    }

    struct Devices: Encodable {
        let schemaVersion = 1
        let usbDevices: [USBDeviceNode]
        let thunderboltDevices: [ThunderboltDevice]
    }

    struct Displays: Encodable {
        let schemaVersion = 1
        let displays: [DisplayInfo]
    }

    struct Charging: Encodable {
        let schemaVersion = 1
        let power: PowerState
        let findings: [ChargingFinding]
    }
}

struct CableStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Full cable and charging overview (default).")
    @OptionGroup var output: OutputOptions

    func run() throws {
        let snapshot = CableReader.snapshot()
        if output.json {
            return try Output.json(CableJSON.Status(
                generatedAt: snapshot.generatedAt,
                machineModel: snapshot.machineModel,
                ports: snapshot.ports,
                cables: snapshot.cables,
                usbDevices: snapshot.usbDevices,
                thunderboltDevices: snapshot.thunderboltDevices,
                displays: snapshot.displays,
                power: snapshot.power,
                findings: snapshot.findings
            ))
        }
        let connected = snapshot.ports.filter { $0.connected == true }.count
        Output.line("USB-C ports: \(connected) connected / \(snapshot.ports.count) total")
        for port in snapshot.ports where port.connected == true {
            Output.line("  \(port.id)  \(CableText.transports(port))  \(port.negotiatedSpeed ?? "speed unknown")")
            Output.line("    cable: \(CableText.cable(port.cable))")
        }
        if !snapshot.displays.isEmpty {
            Output.line("Displays: " + snapshot.displays.map { "\($0.name) \($0.width.map(String.init) ?? "?")x\($0.height.map(String.init) ?? "?") \($0.refreshHz.map { String(format: "%.0f Hz", $0) } ?? "refresh unknown")" }.joined(separator: "; "))
        }
        Output.line("Charging: \(snapshot.power.isDesktopWithoutBattery ? "not applicable (desktop)" : "adapter \(CableText.watts(snapshot.power.adapterWatts))")")
        for finding in snapshot.findings {
            Output.line("  [\(finding.severity.rawValue)] \(finding.title): \(finding.reason)")
        }
    }
}

struct CablePorts: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ports", abstract: "Show every USB-C port and its cable.")
    @OptionGroup var output: OutputOptions

    func run() throws {
        let snapshot = CableReader.snapshot()
        if output.json {
            return try Output.json(CableJSON.Ports(ports: snapshot.ports, cables: snapshot.cables))
        }
        for port in snapshot.ports {
            Output.line("\(port.id)  \(CableText.connected(port))  orientation=\(port.orientation.rawValue)  transports=\(CableText.transports(port))")
            Output.line("  speed: \(port.negotiatedSpeed ?? "unknown"), device: \(port.deviceName ?? "unknown")")
            Output.line("  cable: \(CableText.cable(port.cable))")
        }
    }
}

struct CableDevices: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "devices", abstract: "Show the USB device and Thunderbolt tree.")
    @OptionGroup var output: OutputOptions

    func run() throws {
        let snapshot = CableReader.snapshot()
        if output.json {
            return try Output.json(CableJSON.Devices(
                usbDevices: snapshot.usbDevices,
                thunderboltDevices: snapshot.thunderboltDevices
            ))
        }
        if snapshot.usbDevices.isEmpty {
            Output.line("No USB devices reported.")
        } else {
            CableText.deviceTree(snapshot.usbDevices)
        }
        for device in snapshot.thunderboltDevices {
            let generation = device.generation.map(String.init) ?? "?"
            let cableSpeed = device.cableSpeed.map(String.init) ?? "?"
            Output.line("Thunderbolt: \(device.name)  generation code \(generation), cable speed code \(cableSpeed)")
        }
    }
}

struct CableDisplays: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "displays", abstract: "Show connected displays and their link path.")
    @OptionGroup var output: OutputOptions

    func run() throws {
        let snapshot = CableReader.snapshot()
        if output.json {
            return try Output.json(CableJSON.Displays(displays: snapshot.displays))
        }
        if snapshot.displays.isEmpty {
            Output.line("No displays reported.")
            return
        }
        for display in snapshot.displays {
            let resolution = "\(display.width.map(String.init) ?? "?")x\(display.height.map(String.init) ?? "?")"
            let refresh = display.refreshHz.map { String(format: "%.0f Hz", $0) } ?? "refresh unknown"
            Output.line("\(display.name)  \(resolution) \(refresh)  via \(display.connectionType ?? "unknown")\(display.portNumber.map { " port \($0)" } ?? "")")
            Output.line("  link: \(display.linkRate ?? "unknown")\(display.tunneled == true ? " (tunneled)" : "")")
        }
    }
}

struct CableCharging: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "charging", abstract: "Show charging diagnosis findings.")
    @OptionGroup var output: OutputOptions

    func run() throws {
        let snapshot = CableReader.snapshot()
        if output.json {
            return try Output.json(CableJSON.Charging(power: snapshot.power, findings: snapshot.findings))
        }
        let power = snapshot.power
        Output.line("Adapter: \(power.adapterDescription ?? "unknown") \(CableText.watts(power.adapterWatts))")
        Output.line("External power: \(power.externalConnected.map { $0 ? "yes" : "no" } ?? "unknown"), charging: \(power.isCharging.map { $0 ? "yes" : "no" } ?? "unknown")")
        if power.notChargingReasons.isEmpty {
            Output.line("Not charging reason: none reported")
        } else {
            Output.line("Not charging reason: \(power.notChargingReasons.joined(separator: "; "))")
        }
        if snapshot.findings.isEmpty {
            Output.line("No findings.")
            return
        }
        for finding in snapshot.findings {
            Output.line("[\(finding.severity.rawValue)] \(finding.id)")
            Output.line("  \(finding.title)")
            Output.line("  Why: \(finding.reason)")
            Output.line("  Try: \(finding.recommendation)")
        }
    }
}
