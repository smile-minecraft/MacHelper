import Foundation
import Metrics

/// Made-up readings for previewing pages this Mac has no hardware for, e.g. the battery page on a
/// Mac mini: `make run ARGS=--demo-battery`. Debug builds only; a release build ignores the flag.
///
/// The demo battery discharges for seven minutes and charges for three, over and over, so the
/// drawn battery, the status and the charge history all move. Its values never reach the
/// history database: the minute rows keep only real measurements.
enum DemoData {
    #if DEBUG
    static let battery = CommandLine.arguments.contains("--demo-battery")
    #else
    static let battery = false
    #endif

    static func batteryReading(at date: Date = Date()) -> BatteryReading {
        let period = 600.0, discharge = 420.0
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        let charging = t >= discharge
        let charge = charging
            ? 0.62 + 0.24 * (t - discharge) / (period - discharge)
            : 0.86 - 0.24 * t / discharge
        let wobble = sin(date.timeIntervalSinceReferenceDate / 7)
        return BatteryReading(charge: charge, isCharging: charging, externalPower: charging,
                              watts: charging ? 18.5 + wobble : -(9.4 + 1.2 * wobble),
                              cycleCount: 214, health: 0.912, celsius: 30.8 + 1.5 * wobble)
    }

    /// Accessories added next to the real ones, so the accessory rows show every kind of detail
    /// (earbuds with a case, a charging device).
    static var accessories: [AccessoryBatteryReading] {
        guard battery else { return [] }
        return [
            AccessoryBatteryReading(id: "demo.airpods", name: "AirPods Pro", kind: .headphones, charge: 0.46,
                                    components: [.init(id: .left, charge: 0.78), .init(id: .right, charge: 0.81),
                                                 .init(id: .chargingCase, charge: 0.46)]),
            AccessoryBatteryReading(id: "demo.trackpad", name: "Magic Trackpad", kind: .trackpad, charge: 0.34,
                                    isCharging: true),
        ]
    }
}
