import CoreGraphics
import Foundation
import IOKit

/// Read-only IOKit adapter. Each `snapshot()` is independent and safe to call
/// repeatedly (e.g. every 3 seconds from the future App page). It never writes
/// hardware properties and needs no helper or administrator rights.
public enum CableReader {
    public static func snapshot() -> CableSnapshot {
        let portNodes = dedupe(services(matching: "AppleHPMInterfaceType10") + services(matching: "IOPort"))
        let stateClasses = [
            "IOPortTransportStateCC", "IOPortTransportStateUSB2", "IOPortTransportStateUSB3",
            "IOPortTransportStateCIO", "IOPortTransportStateDisplayPort", "IOPortTransportStatePCIe",
        ]
        let states = stateClasses.flatMap { services(matching: $0) }
        let cabledNodes = services(matching: "IOPortTransportComponentCCUSBPDSOPp")
        let ports = IORegistryParser.parsePorts(ports: portNodes, states: states, cables: cabledNodes)
        let cables = IORegistryParser.parseCables(cabledNodes)
        let devices = IORegistryParser.parseUSBDevices(usbDevices())
        let displays = IORegistryDisplayParser.parseDisplays(states: states, modes: displayModes())
        let thunderbolt = IORegistryThunderboltParser.parse(states)
        let battery = services(matching: "AppleSmartBattery").first ?? [:]
        let model = machineModel()
        let power = IORegistryPowerParser.parse(battery, model: model)
        return CableSnapshot(
            machineModel: model,
            ports: ports,
            cables: cables,
            usbDevices: devices,
            thunderboltDevices: thunderbolt,
            displays: displays,
            power: power,
            findings: ChargingDiagnosis.evaluate(
                power: power, ports: ports, cables: cables, usbDevices: devices, displays: displays
            )
        )
    }

    /// Current CoreGraphics modes, used for the display's active resolution and
    /// refresh rate. IORegistry only exposes the EDID preferred timing.
    public static func displayModes() -> [DisplayModeInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.compactMap { id in
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            return DisplayModeInfo(
                vendorID: Int(CGDisplayVendorNumber(id)),
                productID: Int(CGDisplayModelNumber(id)),
                width: mode.width,
                height: mode.height,
                refreshHz: mode.refreshRate > 0 ? mode.refreshRate : nil,
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight
            )
        }
    }

    // MARK: - IOKit plumbing

    private static func services(matching className: String) -> [[String: Any]] {
        var iterator = io_iterator_t(0)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            if let properties = properties(of: service, includeChildren: true, depth: 2) {
                result.append(properties)
            }
            IOObjectRelease(service)
        }
        return result
    }

    private static func usbDevices() -> [[String: Any]] {
        var iterator = io_iterator_t(0)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            if var properties = properties(of: service, includeChildren: false, depth: 0),
               let location = properties["locationID"] as? NSNumber {
                properties["ParentLocationID"] = parentLocationID(of: service)
                if location.uint64Value != 0 { result.append(properties) }
            }
            IOObjectRelease(service)
        }
        return result
    }

    private static func properties(of service: io_service_t, includeChildren: Bool, depth: Int) -> [String: Any]? {
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = raw?.takeRetainedValue() as? [String: Any]
        else { return nil }
        var result = dict
        if result["IOObjectClass"] == nil,
           let className = IOObjectCopyClass(service)?.takeRetainedValue() as String? {
            result["IOObjectClass"] = className
        }
        if includeChildren, depth > 0 {
            let kids = childProperties(of: service, depth: depth)
            if !kids.isEmpty { result["IORegistryEntryChildren"] = kids }
        }
        return result
    }

    private static func childProperties(of service: io_service_t, depth: Int) -> [[String: Any]] {
        var iterator = io_iterator_t(0)
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while true {
            let child = IOIteratorNext(iterator)
            if child == 0 { break }
            if let properties = properties(of: child, includeChildren: depth > 1, depth: depth - 1) {
                result.append(properties)
            }
            IOObjectRelease(child)
        }
        return result
    }

    private static func parentLocationID(of service: io_service_t) -> NSNumber? {
        var current = service
        var firstParent = true
        defer { if !firstParent { IOObjectRelease(current) } }
        for _ in 0..<8 {
            var parent = io_object_t(0)
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { return nil }
            if !firstParent { IOObjectRelease(current) }
            current = parent
            firstParent = false
            guard let props = properties(of: parent, includeChildren: false, depth: 0) else { continue }
            let isDevice = (props["IOObjectClass"] as? String) == "IOUSBHostDevice"
            if isDevice, let location = props["locationID"] as? NSNumber { return location }
        }
        return nil
    }

    private static func machineModel() -> String? {
        guard let platform = services(matching: "IOPlatformExpertDevice").first else { return nil }
        if let data = platform["model"] as? Data {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        }
        return platform["model"] as? String
    }

    private static func dedupe(_ nodes: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<String>()
        return nodes.filter { node in
            let key = "\(IORegistryParser.number(node, "PortNumber") ?? -1)-\(IORegistryParser.text(node, "PortDescription") ?? IORegistryParser.text(node, "Description") ?? "")"
            return seen.insert(key).inserted
        }
    }
}
