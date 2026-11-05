import Foundation

/// Validation shared by the thermal readers. A sensor that reports zero, a non-finite value or
/// something outside the plausible die range did not produce a reading. Passing it on would make
/// the UI show a real temperature (often 0 °C) for a channel the machine does not populate.
public enum SMCThermal {
    public static func celsius(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, raw > 0, raw < 150 else { return nil }
        return raw
    }

    /// Apple Silicon GPU temperature keys use the `Tg` prefix (`Tg0G`, `Tg0H`, …).
    public static func isGPUKey(_ key: FourCC) -> Bool {
        let s = key.description
        return s.hasPrefix("Tg") || s.hasPrefix("TG")
    }
}

/// A single SMC power rail. Zero and non-finite values mean the rail is not populated; they are
/// not a real wattage, so they come back as `nil`.
public enum SMCPowerRail {
    public static func normalizedWatts(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        return raw
    }

    public static func watts(_ smc: SMC, key: FourCC) -> Double? {
        normalizedWatts(try? smc.readDouble(key))
    }
}
