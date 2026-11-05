import SMCKit

/// Turns monitor readings into the columns of the shared minute history. The app and the
/// background recorder both write this table, so a column must keep one meaning no matter
/// which process wrote the minute.
public enum MonitorHistorySample {
    public static func cpu(_ reading: CPUReading) -> [String: Double] {
        ["cpu": reading.total]
    }

    public static func gpu(_ reading: GPUReading) -> [String: Double] {
        ["gpu": reading.utilization]
    }

    public static func memory(_ reading: MemoryReading) -> [String: Double] {
        guard reading.totalBytes > 0 else { return [:] }
        return ["memory": Double(reading.usedBytes) / Double(reading.totalBytes)]
    }

    public static func disk(_ reading: DiskReading) -> [String: Double] {
        ["diskRead": reading.readBytesPerSecond, "diskWrite": reading.writeBytesPerSecond]
    }

    public static func network(_ reading: NetworkReading) -> [String: Double] {
        ["networkIn": reading.inBytesPerSecond, "networkOut": reading.outBytesPerSecond]
    }

    public static func battery(_ reading: BatteryReading) -> [String: Double] {
        ["battery": reading.charge]
    }

    public static func fan(_ readings: [FanReading]) -> [String: Double] {
        readings.first.map { ["fan": $0.actualRPM] } ?? [:]
    }

    /// System watts on a Mac with the `PSTR` rail, GPU watts only on a Mac without it. A rail
    /// that drops out for one sample leaves the minute without a value instead of mixing GPU
    /// watts into a column of system watts.
    public static func power(_ reading: PowerReading) -> [String: Double] {
        let value = reading.hasSystemRail == true ? reading.systemWatts : (reading.systemWatts ?? reading.gpuWatts)
        return value.map { ["power": $0] } ?? [:]
    }

    /// Hottest CPU-die sensor, the value stored in the `temperature` column by both writers.
    public static func cpuCelsius(_ readings: [TemperatureReading]) -> Double? {
        readings.filter { $0.category == .cpu }.map(\.celsius).max()
    }

    public static func temperature(_ readings: [TemperatureReading]) -> [String: Double] {
        cpuCelsius(readings).map { ["temperature": $0] } ?? [:]
    }
}
