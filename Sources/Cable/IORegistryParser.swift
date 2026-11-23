import Foundation

private func paired<T, U>(_ first: T?, _ second: U?) -> (T, U)? {
    guard let first, let second else { return nil }
    return (first, second)
}

/// Pure parsers for IORegistry property dictionaries. Nothing here touches IOKit:
/// the reader layer turns IOService properties into `[String: Any]` and these
/// functions turn them into typed values. Missing or wrongly typed keys stay nil.
public enum IORegistryParser {
    // MARK: - Generic plist access

    public static func number(_ dict: [String: Any]?, _ key: String) -> Int? {
        guard let value = dict?[key] else { return nil }
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        if let i = value as? UInt64, i <= UInt64(Int.max) { return Int(i) }
        if let d = value as? Double, d.rounded() == d, d <= Double(Int.max) { return Int(d) }
        return nil
    }

    public static func double(_ dict: [String: Any]?, _ key: String) -> Double? {
        guard let value = dict?[key] else { return nil }
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    public static func text(_ dict: [String: Any]?, _ key: String) -> String? {
        dict?[key] as? String
    }

    public static func flag(_ dict: [String: Any]?, _ key: String) -> Bool? {
        guard let value = dict?[key] else { return nil }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    public static func array(_ dict: [String: Any]?, _ key: String) -> [[String: Any]]? {
        (dict?[key] as? [[String: Any]])
    }

    public static func children(_ dict: [String: Any]) -> [[String: Any]] {
        array(dict, "IORegistryEntryChildren") ?? []
    }

    private static func bytes(_ value: Any?) -> Data? {
        if let data = value as? Data { return data }
        if let data = value as? NSData { return Data(referencing: data) }
        if let list = value as? [UInt8] { return Data(list) }
        if let list = value as? [NSNumber] { return Data(list.map { $0.uint8Value }) }
        return nil
    }

    // MARK: - Cable (SOP')

    /// Parses one `IOPortTransportComponentCCUSBPDSOPp` node, including its Metadata.
    public static func parseCable(_ node: [String: Any]) -> CableSpec? {
        let metadata = array(node, "Metadata")?.first ?? (node["Metadata"] as? [String: Any]) ?? [:]
        let vdoValues = (metadata["VDOs"] as? [Any]) ?? []
        let vdos = vdoValues.compactMap { bytes($0) }
        guard vdos.count >= 4 else { return nil }

        let description = text(metadata, "Product Type Description") ?? text(node, "Product Type Description")
        let productType = number(metadata, "Product Type") ?? number(node, "Product Type")
        let kind: CableKind = {
            if productType == 4 { return .active }
            if productType == 3 { return .passive }
            if let description {
                if description.localizedCaseInsensitiveContains("active") { return .active }
                if description.localizedCaseInsensitiveContains("passive") { return .passive }
            }
            return .unknown
        }()
        return CableVDOParser.decode(
            vdos: vdos,
            kind: kind,
            vendorID: number(metadata, "Vendor ID") ?? number(node, "Vendor ID"),
            productID: number(metadata, "Product ID") ?? number(node, "Product ID")
        )
    }

    public static func parseCables(_ nodes: [[String: Any]]) -> [CableSpec] {
        nodes.compactMap { parseCable($0) }
    }

    // MARK: - Ports and transports

    private static func transport(_ raw: String) -> Transport? {
        switch raw.lowercased() {
        case "cc": return .cc
        case "usb2": return .usb2
        case "usb3": return .usb3
        case "cio": return .cio
        case "displayport": return .displayPort
        case "pcie": return .pcie
        default: return .other
        }
    }

    private static func stateNodes(_ states: [[String: Any]], containing name: String) -> [[String: Any]] {
        states.filter { node in
            (text(node, "IOObjectClass") ?? text(node, "TransportTypeDescription") ?? "").localizedCaseInsensitiveContains(name)
        }
    }

    private static func component(_ children: [[String: Any]], named fragment: String) -> [String: Any]? {
        children.first { child in
            let name = (text(child, "ComponentName") ?? "") + (text(child, "Address Description") ?? "")
                + (text(child, "IOObjectClass") ?? "")
            return name.contains(fragment)
        }
    }

    private static func contract(_ cc: [String: Any]?) -> PowerContract? {
        guard let cc else { return nil }
        let metadata = (cc["Metadata"] as? [String: Any]) ?? [:]
        let millivolts = double(metadata, "Voltage (mV)") ?? double(cc, "Voltage (mV)")
        let milliamps = double(metadata, "Current (mA)") ?? double(cc, "Current (mA)")
        let volts = millivolts.map { $0 / 1000 }
        let amps = milliamps.map { $0 / 1000 }
        let watts = paired(volts, amps).map { $0.0 * $0.1 }
            ?? double(metadata, "Watts").map { $0 }
        guard volts != nil || amps != nil || watts != nil else { return nil }
        return PowerContract(volts: volts, amps: amps, watts: watts)
    }

    private static func negotiatedSpeed(states: [[String: Any]]) -> String? {
        let cio = stateNodes(states, containing: "CIO").first
        if let cio, flag(cio, "Active") == true {
            let generation = number(cio, "Generation").map(String.init) ?? "?"
            let cable = number(cio, "CableSpeed").map(String.init) ?? "?"
            // IOPortTransportStateCIO exposes link codes, not rates. No Apple
            // documentation maps Generation/CableSpeed onto a Thunderbolt generation
            // or Gb/s, and a single machine's system_profiler entry (Thunderbolt 3,
            // 40 Gb/s at generation 2 / cable speed 3) is not a mapping table, so the
            // codes are reported as codes: "Gen2" would read like USB 10 Gbps.
            return "Thunderbolt/USB4 link active (generation code \(generation), cable speed code \(cable))"
        }
        let usb3 = stateNodes(states, containing: "USB3").first(where: { flag($0, "Active") == true })
        if let rate = usb3.flatMap({ text($0, "DataRateDescription") }) { return rate }
        let usb2 = stateNodes(states, containing: "USB2").first(where: { flag($0, "Active") == true })
        if let rate = usb2.flatMap({ text($0, "DataRateDescription") }) { return rate }
        let dp = stateNodes(states, containing: "DisplayPort").first(where: { flag($0, "Active") == true })
        return dp.flatMap { text($0, "LinkRateDescription") }
    }

    /// Builds port status from the port objects and all `IOPortTransportState*`
    /// objects whose `ParentPortNumber` links them to that port.
    public static func parsePorts(ports: [[String: Any]], states: [[String: Any]], cables: [[String: Any]] = []) -> [PortStatus] {
        var byPort: [Int: [[String: Any]]] = [:]
        for state in states {
            guard let port = number(state, "ParentPortNumber") ?? number(state, "ParentBuiltInPortNumber") else { continue }
            // A DisplayPort transport on the HDMI connector shares port number 1 with
            // a USB-C port; only USB-C transports belong on the USB-C port status.
            if let type = text(state, "ParentPortTypeDescription"), type != "USB-C" { continue }
            byPort[port, default: []].append(state)
        }
        var cablesByPort: [Int: [String: Any]] = [:]
        for cable in cables {
            guard let port = number(cable, "ParentPortNumber") ?? number(cable, "ParentBuiltInPortNumber") else { continue }
            cablesByPort[port] = cable
        }

        return ports.compactMap { port -> PortStatus? in
            let portNumber = number(port, "PortNumber") ?? number(port, "ParentPortNumber")
            let type = text(port, "PortTypeDescription") ?? "Unknown"
            guard type == "USB-C", portNumber != nil || text(port, "Description") != nil else { return nil }
            let portStates = portNumber.flatMap { byPort[$0] } ?? []
            let cc = stateNodes(portStates, containing: "CC").first
            let ccChildren = cc.flatMap { children($0) } ?? []
            let sop = component(ccChildren, named: "USBPDSOP") ?? component(ccChildren, named: ">SOP<")
            let sopPrime = component(ccChildren, named: "SOPp") ?? component(ccChildren, named: "SOP'")
            let cableNode = sopPrime ?? (portNumber.flatMap { cablesByPort[$0] })
            let connected = flag(port, "ConnectionActive")
            let cable: CableSpec? = {
                if let cableNode, let decoded = parseCable(cableNode) { return decoded }
                guard connected == true else { return nil }
                return .noEmarker
            }()

            var transports: [Transport] = []
            for raw in (port["TransportsActive"] as? [String]) ?? [] {
                if let t = transport(raw) { transports.append(t) }
            }
            for state in portStates where flag(state, "Active") == true {
                let className = text(state, "IOObjectClass") ?? ""
                let t: Transport? = className.contains("USB2") ? .usb2
                    : className.contains("USB3") ? .usb3
                    : className.contains("CIO") ? .cio
                    : className.contains("DisplayPort") ? .displayPort
                    : className.contains("PCIe") ? .pcie : nil
                if let t, !transports.contains(t) { transports.append(t) }
            }
            let orientationCode = number(port, "PlugOrientation")
            let orientation: PlugOrientation = orientationCode == 0 ? .normal
                : orientationCode == 1 ? .flipped : .unknown
            let usb = stateNodes(portStates, containing: "USB3").first ?? stateNodes(portStates, containing: "USB2").first
            let cio = stateNodes(portStates, containing: "CIO").first
            let deviceName = text(usb, "Product") ?? text(cio, "Device Model Name")

            return PortStatus(
                id: text(port, "PortDescription") ?? text(port, "Description") ?? "Port-\(portNumber.map(String.init) ?? "?")",
                number: portNumber,
                portType: type,
                connected: connected,
                orientation: orientation,
                activeTransports: transports,
                negotiatedSpeed: negotiatedSpeed(states: portStates),
                partner: PartnerIdentity(
                    vendorID: number(sop, "Vendor ID") ?? number(cc, "Vendor ID (SOP)"),
                    productID: number(sop, "Product ID") ?? number(cc, "Product ID (SOP)")
                ),
                powerContract: contract(cc),
                cable: cable,
                deviceName: deviceName
            )
        }
    }

    // MARK: - USB device tree

    /// `parentLocationID` is added by the reader from the IORegistry parent chain.
    /// `IOUSBHostDevice` carries no port key, so a device's port is filled in later
    /// by ``attributeUSBPorts(devices:states:)``.
    public static func parseUSBDevices(_ nodes: [[String: Any]]) -> [USBDeviceNode] {
        let all: [USBDeviceNode] = nodes.compactMap { node in
            guard text(node, "IOObjectClass") == "IOUSBHostDevice" else { return nil }
            let bcd = number(node, "bcdUSB")
            let negotiated = number(node, "UsbLinkSpeed").map { $0 / 1_000_000 }
            // bcdUSB is the protocol version the device speaks, not its link rate:
            // IORegistry exposes no BOS Device Capability descriptor. A 3.x device
            // is at least a 5 Gbps device (which matches what it negotiated when the
            // link is SuperSpeed), while 2.x and below prove nothing about a
            // SuperSpeed capability, so the maximum stays unknown instead of
            // claiming 480 Mbps for a bcdUSB 0x200 device.
            let maxSpeed: Int? = {
                guard let bcd, bcd >= 0x300 else { return nil }
                return max(negotiated ?? 5_000, 5_000)
            }()
            return USBDeviceNode(
                locationID: number(node, "locationID").flatMap { UInt64(exactly: $0) },
                parentLocationID: number(node, "ParentLocationID").flatMap { UInt64(exactly: $0) },
                name: text(node, "USB Product Name") ?? text(node, "IORegistryEntryName") ?? "Unknown device",
                vendorName: text(node, "USB Vendor Name"),
                vendorID: number(node, "idVendor"),
                productID: number(node, "idProduct"),
                deviceClass: number(node, "bDeviceClass"),
                isHub: number(node, "bDeviceClass") == 9,
                negotiatedSpeedMbps: negotiated,
                maxSpeedMbps: maxSpeed
            )
        }
        let ids = Set(all.compactMap(\.locationID))
        let roots = all.filter { device in
            guard let parent = device.parentLocationID else { return true }
            return !ids.contains(parent)
        }
        func build(_ device: USBDeviceNode, visiting: Set<UInt64>) -> USBDeviceNode {
            var copy = device
            guard let id = device.locationID, !visiting.contains(id) else { return copy }
            let children = all.filter { $0.parentLocationID == id }
                .map { build($0, visiting: visiting.union([id])) }
                .sorted { ($0.locationID ?? 0) < ($1.locationID ?? 0) }
            copy.children = children
            return copy
        }
        return roots.map { build($0, visiting: []) }.sorted { ($0.locationID ?? 0) < ($1.locationID ?? 0) }
    }

    /// One USB transport state naming the device plugged directly into its port.
    private struct PortDeviceHint {
        let portNumber: Int
        let vendorID: Int
        let productID: Int
        let productName: String?

        func matches(_ device: USBDeviceNode) -> Bool {
            vendorID == device.vendorID && productID == device.productID
        }

        func matchesName(of device: USBDeviceNode) -> Bool {
            guard let productName else { return false }
            return productName.compare(device.name, options: .caseInsensitive) == .orderedSame
        }
    }

    /// `IOPortTransportStateUSB2` and `IOPortTransportStateUSB3` name the device
    /// attached to that port (`Vendor ID`, `Product ID`, `Product`), which is how a
    /// USB device learns which USB-C port it belongs to; `IOUSBHostDevice` itself has
    /// no port property. Every device under a matched hub inherits its port. A node
    /// that still has no port belongs to the Mac's own tree (its root hubs) or could
    /// not be attributed, so it is flagged ``USBDeviceNode/isBuiltIn``.
    public static func attributeUSBPorts(devices: [USBDeviceNode], states: [[String: Any]]) -> [USBDeviceNode] {
        let hints = portDeviceHints(states)
        let duplicates = duplicateCounts(devices)
        return devices.map { attribute($0, hints: hints, duplicates: duplicates, inherited: nil) }
    }

    private static func duplicateCounts(_ devices: [USBDeviceNode]) -> [String: Int] {
        var counts: [String: Int] = [:]
        func walk(_ node: USBDeviceNode) {
            counts[identityKey(node), default: 0] += 1
            counts[nameKey(node), default: 0] += 1
            node.children.forEach(walk)
        }
        devices.forEach(walk)
        return counts
    }

    private static func identityKey(_ device: USBDeviceNode) -> String {
        "\(device.vendorID.map(String.init) ?? "-"):\(device.productID.map(String.init) ?? "-")"
    }

    private static func nameKey(_ device: USBDeviceNode) -> String {
        identityKey(device) + ":" + device.name.lowercased()
    }

    private static func portDeviceHints(_ states: [[String: Any]]) -> [PortDeviceHint] {
        states.compactMap { state in
            let className = text(state, "IOObjectClass") ?? ""
            guard className.contains("USB2") || className.contains("USB3") else { return nil }
            // A Type-A receptacle shows the same transport states; only USB-C port
            // numbers line up with the port status list.
            if let type = text(state, "ParentPortTypeDescription"), type != "USB-C" { return nil }
            guard let portNumber = number(state, "ParentPortNumber") ?? number(state, "ParentBuiltInPortNumber"),
                  let vendorID = number(state, "Vendor ID"),
                  let productID = number(state, "Product ID")
            else { return nil }
            return PortDeviceHint(
                portNumber: portNumber,
                vendorID: vendorID,
                productID: productID,
                productName: text(state, "Product")
            )
        }
    }

    /// Two identical devices (same VID/PID) are told apart by the name the port
    /// state reports. If several devices share both identifiers and the name, the
    /// port stays unknown rather than picking one.
    private static func directPort(for device: USBDeviceNode, hints: [PortDeviceHint], duplicates: [String: Int]) -> Int? {
        let candidates = hints.filter { $0.matches(device) }
        guard !candidates.isEmpty else { return nil }
        let namedPorts = Set(candidates.filter { $0.matchesName(of: device) }.map(\.portNumber))
        if namedPorts.count == 1, duplicates[nameKey(device)] == 1 {
            return namedPorts.first
        }
        let ports = Set(candidates.map(\.portNumber))
        if ports.count == 1, duplicates[identityKey(device)] == 1 {
            return ports.first
        }
        return nil
    }

    private static func attribute(
        _ node: USBDeviceNode,
        hints: [PortDeviceHint],
        duplicates: [String: Int],
        inherited: Int?
    ) -> USBDeviceNode {
        var copy = node
        if let direct = directPort(for: node, hints: hints, duplicates: duplicates) {
            copy.portNumber = direct
        } else if copy.portNumber == nil {
            copy.portNumber = inherited
        }
        copy.isBuiltIn = copy.portNumber == nil
        let port = copy.portNumber
        copy.children = node.children.map {
            attribute($0, hints: hints, duplicates: duplicates, inherited: port)
        }
        return copy
    }
}

// MARK: - Displays

public enum IORegistryDisplayParser {
    public static func parseDisplays(states: [[String: Any]], modes: [DisplayModeInfo] = []) -> [DisplayInfo] {
        states.compactMap { state -> DisplayInfo? in
            guard (IORegistryParser.text(state, "IOObjectClass") ?? "").localizedCaseInsensitiveContains("DisplayPort") else { return nil }
            let metadata = (state["Metadata"] as? [String: Any]) ?? [:]
            let edid = edidBytes(state) ?? edidBytes(metadata)
            let edidInfo = edid.flatMap { parseEDID($0) }
            let vendorID = edidInfo?.vendorID
            let productID = IORegistryParser.number(state, "ProductID") ?? IORegistryParser.number(metadata, "ProductID") ?? edidInfo?.productID
            let matched = modes.first { mode in
                (vendorID == nil || mode.vendorID == nil || mode.vendorID == vendorID)
                    && (productID == nil || mode.productID == nil || mode.productID == productID)
            }
            let port = IORegistryParser.number(state, "ParentPortNumber") ?? IORegistryParser.number(state, "ParentBuiltInPortNumber")
            let name = IORegistryParser.text(state, "ProductName") ?? IORegistryParser.text(metadata, "ProductName") ?? "Display"
            return DisplayInfo(
                id: "display-\(port.map(String.init) ?? "?")-\(productID.map(String.init) ?? "unknown")",
                name: name,
                manufacturer: IORegistryParser.text(state, "ManufacturerName") ?? IORegistryParser.text(metadata, "ManufacturerName"),
                width: matched?.width ?? edidInfo?.width,
                height: matched?.height ?? edidInfo?.height,
                refreshHz: matched?.refreshHz ?? edidInfo?.refreshHz,
                pixelWidth: matched?.pixelWidth,
                pixelHeight: matched?.pixelHeight,
                connectionType: IORegistryParser.text(state, "ParentPortTypeDescription"),
                portNumber: port,
                tunneled: IORegistryParser.flag(state, "Tunneled"),
                linkRate: IORegistryParser.text(state, "LinkRateDescription")
            )
        }
    }

    private static func edidBytes(_ dict: [String: Any]) -> Data? {
        if let data = dict["EDID"] as? Data { return data }
        if let data = dict["EDID"] as? NSData { return Data(referencing: data) }
        return nil
    }

    private struct EDIDInfo {
        let vendorID: Int
        let productID: Int
        let width: Int
        let height: Int
        let refreshHz: Double?
    }

    /// Reads the EDID vendor/product block and first detailed timing descriptor.
    /// The descriptor is the display's preferred timing, not necessarily the
    /// current mode; CoreGraphics modes supplied by the reader take precedence.
    private static func parseEDID(_ data: Data) -> EDIDInfo? {
        let b = [UInt8](data)
        guard b.count >= 0x48 else { return nil }
        let vendor = Int(b[8]) << 8 | Int(b[9])
        let product = Int(b[10]) << 8 | Int(b[11])
        let d = Array(b[0x36..<0x48])
        let pixelClock = Int(UInt16(d[0]) | (UInt16(d[1]) << 8)) * 10_000
        let hActive = ((Int(d[4]) >> 4) << 8) | Int(d[2])
        let hBlank = ((Int(d[4]) & 0x0F) << 8) | Int(d[3])
        let vActive = ((Int(d[7]) >> 4) << 8) | Int(d[5])
        let vBlank = ((Int(d[7]) & 0x0F) << 8) | Int(d[6])
        let total = (hActive + hBlank) * (vActive + vBlank)
        guard hActive > 0, vActive > 0, total > 0 else { return nil }
        let refresh = Double(pixelClock) / Double(total)
        return EDIDInfo(
            vendorID: vendor,
            productID: product,
            width: hActive,
            height: vActive,
            refreshHz: refresh > 0 && refresh < 500 ? refresh : nil
        )
    }
}

// MARK: - Thunderbolt

public enum IORegistryThunderboltParser {
    public static func parse(_ states: [[String: Any]]) -> [ThunderboltDevice] {
        states.compactMap { state -> ThunderboltDevice? in
            guard (IORegistryParser.text(state, "IOObjectClass") ?? "").localizedCaseInsensitiveContains("CIO"),
                  IORegistryParser.flag(state, "Active") == true else { return nil }
            let name = IORegistryParser.text(state, "Device Model Name") ?? IORegistryParser.text(state, "Device Vendor Name") ?? "Thunderbolt device"
            return ThunderboltDevice(
                name: name,
                vendorID: IORegistryParser.number(state, "Device Vendor ID") ?? IORegistryParser.number(state, "Vendor ID"),
                deviceID: IORegistryParser.number(state, "Device ID"),
                generation: IORegistryParser.number(state, "Generation"),
                cableSpeed: IORegistryParser.number(state, "CableSpeed"),
                cableGeneration: IORegistryParser.number(state, "CableGeneration"),
                portNumber: IORegistryParser.number(state, "ParentPortNumber")
            )
        }
    }
}

// MARK: - Power

public enum IORegistryPowerParser {
    public static func parse(_ battery: [String: Any], model: String?) -> PowerState {
        let adapter = (battery["AdapterDetails"] as? [String: Any])
            ?? (battery["AppleRawAdapterDetails"] as? [[String: Any]])?.first ?? [:]
        let charger = battery["ChargerData"] as? [String: Any] ?? [:]
        let telemetry = battery["PowerTelemetryData"] as? [String: Any] ?? [:]
        let volts = IORegistryParser.double(adapter, "Voltage").map { $0 / 1000 }
        let amps = IORegistryParser.double(adapter, "Current").map { $0 / 1000 }
        let watts = IORegistryParser.double(adapter, "Watts")
            ?? paired(volts, amps).map { $0.0 * $0.1 }
        let reason = IORegistryParser.number(charger, "NotChargingReason") ?? IORegistryParser.number(battery, "NotChargingReason")
        return PowerState(
            machineModel: model,
            batteryInstalled: IORegistryParser.flag(battery, "BatteryInstalled"),
            designCapacity: IORegistryParser.number(battery, "DesignCapacity"),
            adapterWatts: watts,
            adapterVolts: volts,
            adapterAmps: amps,
            adapterDescription: IORegistryParser.text(adapter, "Description"),
            adapterFamilyCode: IORegistryParser.number(adapter, "FamilyCode"),
            recommendedAdapterWatts: recommendedAdapterWatts(model: model),
            externalConnected: IORegistryParser.flag(battery, "ExternalConnected"),
            isCharging: IORegistryParser.flag(battery, "IsCharging"),
            notChargingReasonRaw: reason,
            notChargingReasons: decodeNotChargingReason(reason),
            temperatureCelsius: IORegistryParser.double(battery, "Temperature").map { $0 / 100 },
            systemPowerInWatts: IORegistryParser.double(telemetry, "SystemPowerIn").map { $0 / 1000 },
            chargeLimitPercent: IORegistryParser.number(battery, "ChargeLimit")
                ?? IORegistryParser.number(battery, "ChargingLimit"),
            optimizedCharging: IORegistryParser.flag(battery, "OptimizedChargingEnabled")
                ?? IORegistryParser.flag(battery, "OptimizedCharging")
        )
    }

    /// Conservative minimum adapter wattages. Unknown models return nil: guessing
    /// a wattage would create false charging warnings on unsupported hardware.
    public static func recommendedAdapterWatts(model: String?) -> Int? {
        guard let model else { return nil }
        let m = model.lowercased()
        if m.contains("macbookair") { return 35 }
        if m.contains("macbookpro") {
            return ["18,3", "18,4", "15,3", "15,4"].contains(where: m.contains) ? 140 : 96
        }
        return nil
    }

    /// AppleSmartBattery NotChargingReason is a bit field on Apple Silicon
    /// (see Battman's published SMC CHNC bit layout). Legacy values 1, 128 and
    /// 256/272 fit the same decoding: full, VBUS missing, high-temperature stop.
    public static func decodeNotChargingReason(_ raw: Int?) -> [String] {
        guard let raw, raw != 0, raw >= 0 else { return [] }
        let value = UInt64(raw)
        var result: [String] = []
        func add(_ bit: Int, _ text: String) {
            if value & (UInt64(1) << UInt64(bit)) != 0 { result.append(text) }
        }
        add(0, "Battery fully charged")
        add(1, "Temperature below minimum to stop charging")
        add(2, "Temperature above maximum to stop charging")
        add(3, "Temperature below minimum to start charging")
        add(4, "Temperature above maximum to start charging")
        add(5, "Charge timer expired")
        add(6, "Battery not present")
        add(7, "VBUS not present")
        add(8, "High state of charge with high temperature")
        add(9, "Battery communication failed")
        add(10, "Charging disabled by system mode")
        add(11, "Kiosk mode")
        add(13, "USB Power Delivery negotiation")
        add(15, "Predictive charging / charging limit")
        add(16, "Inductive charging path")
        add(20, "Client adapter inhibit")
        if value & (UInt64(0xFF) << 56) != 0 { result.append("Battery or charger fault") }
        return result
    }
}
