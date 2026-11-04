import Foundation
import IOKit

public struct BatteryReading: Sendable, Hashable, Codable {
    /// 0...1
    public var charge: Double
    public var isCharging: Bool
    public var externalPower: Bool
    /// Positive while charging, negative while discharging.
    public var watts: Double
    public var cycleCount: Int
    /// Current full-charge capacity / design capacity.
    public var health: Double?
    public var celsius: Double?
}

/// Reads `AppleSmartBattery`. Returns nil on desktops (no battery service).
/// Note: not yet verified on hardware (the dev machine is a Mac mini).
public enum BatterySampler {
    public static func sample() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else { return nil }

        func int(_ k: String) -> Int? { (dict[k] as? NSNumber)?.intValue }
        func bool(_ k: String) -> Bool { (dict[k] as? NSNumber)?.boolValue ?? false }

        guard let current = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0 else { return nil }
        // Amperage is reported as a signed 64-bit value; NSNumber.intValue preserves the sign.
        let watts = Double(int("Voltage") ?? 0) / 1000 * Double(int("Amperage") ?? 0) / 1000
        let rawMax = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        let design = int("DesignCapacity")
        return BatteryReading(
            charge: Double(current) / Double(max),
            isCharging: bool("IsCharging"),
            externalPower: bool("ExternalConnected"),
            watts: watts,
            cycleCount: int("CycleCount") ?? 0,
            health: zip2(rawMax, design).flatMap { $1 > 0 ? Double($0) / Double($1) : nil },
            celsius: int("Temperature").map { Double($0) / 100 }
        )
    }

    private static func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}
