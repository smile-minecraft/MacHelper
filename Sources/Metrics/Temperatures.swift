import CSystemBridge
import Foundation
import SMCKit

public struct TemperatureReading: Sendable, Hashable, Codable, Identifiable {
    public enum Category: String, Sendable, Codable { case cpu, gpu, memory, battery, storage, other }
    public var id: String { name }
    public let name: String
    public let celsius: Double
    public let category: Category
}

/// Reads Apple Silicon temperature sensors through the private IOHIDEventSystem API.
/// No privileges required.
public final class HIDTemperatureSensors: @unchecked Sendable {
    private let client: IOHIDEventSystemClient
    private let lock = NSLock()

    public init?() {
        let matching: [String: Int] = [
            "PrimaryUsagePage": Int(MH_HID_USAGE_PAGE_APPLE_VENDOR),
            "PrimaryUsage": Int(MH_HID_USAGE_TEMPERATURE_SENSOR),
        ]
        // The default client works in a user session; a root daemon may need an explicit
        // "monitor" client. Use the first one that actually exposes sensors.
        let candidates: [() -> IOHIDEventSystemClient?] = [
            { IOHIDEventSystemClientCreate(kCFAllocatorDefault) },
            { IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 1, nil) },
        ]
        for make in candidates {
            guard let c = make() else { continue }
            _ = IOHIDEventSystemClientSetMatching(c, matching as CFDictionary)
            if let services = IOHIDEventSystemClientCopyServices(c) as? [IOHIDServiceClient], !services.isEmpty {
                client = c
                return
            }
        }
        return nil
    }

    public func read() -> [TemperatureReading] {
        lock.withLock {
            guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return [] }
            var result: [TemperatureReading] = []
            for service in services {
                guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String,
                      let event = IOHIDServiceClientCopyEvent(service, Int64(MH_HID_EVENT_TYPE_TEMPERATURE), 0, 0)
                else { continue }
                let value = IOHIDEventGetFloatValue(event, Int32(MH_HID_EVENT_FIELD_TEMPERATURE))
                guard let celsius = SMCThermal.celsius(value) else { continue }
                result.append(TemperatureReading(name: name, celsius: celsius, category: Self.categorize(name)))
            }
            // Several sensors can share a name; keep the hottest.
            let merged = Dictionary(result.map { ($0.name, $0) }) { $0.celsius >= $1.celsius ? $0 : $1 }
            return merged.values.sorted { $0.name < $1.name }
        }
    }

    static func categorize(_ name: String) -> TemperatureReading.Category {
        let n = name.lowercased()
        // Apple Silicon names: "PMU tdie1" (SoC die), "PMU tdev1", "gas gauge battery", "NAND CH0 temp"
        if n.contains("gpu") { return .gpu }
        if n.contains("battery") || n.contains("gas gauge") { return .battery }
        if n.contains("nand") || n.contains("ssd") { return .storage }
        if n.contains("tdie") || n.contains("cpu") || n.contains("soc") { return .cpu }
        return .other
    }
}

/// SMC-based temperatures. On Intel this is the only source; on Apple Silicon it supplements HID
/// with per-cluster CPU/GPU keys whose names vary per chip, so we discover them by prefix.
public enum SMCTemperatures {
    public static func read(_ smc: SMC, keys: [FourCC]) -> [TemperatureReading] {
        keys.compactMap { key in
            guard let celsius = SMCThermal.celsius(try? smc.readDouble(key)) else { return nil }
            return TemperatureReading(name: key.description, celsius: celsius, category: category(for: key))
        }
    }

    /// All `T…` keys that currently decode to a plausible temperature.
    public static func discoverKeys(_ smc: SMC) -> [FourCC] {
        guard let keys = try? smc.allKeys() else { return [] }
        return keys.filter { key in
            guard key.description.hasPrefix("T"),
                  let info = try? smc.keyInfo(key),
                  ["flt ", "sp78", "fpe2", "ioft"].contains(info.type.description),
                  let v = try? smc.readDouble(key)
            else { return false }
            return v > 5 && v < 130
        }
    }

    public static func category(for key: FourCC) -> TemperatureReading.Category {
        let s = key.description
        // TPD*/TRD* mirror the HID "PMU tdie*"/"PMU2 tdie*" die sensors on Apple Silicon (verified on M4).
        if s.hasPrefix("Tp") || s.hasPrefix("Te") || s.hasPrefix("TC") || s.hasPrefix("TPD") || s.hasPrefix("TRD") { return .cpu }
        if SMCThermal.isGPUKey(key) { return .gpu }
        if s.hasPrefix("TB") { return .battery }
        if s.hasPrefix("TH") || s.hasPrefix("TN") { return .storage }
        if s.hasPrefix("Tm") || s.hasPrefix("TM") { return .memory }
        return .other
    }
}
