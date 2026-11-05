import SMCKit

/// The single rule for individual temperature sensors, shared by the app and the background
/// recorder. HID is preferred; on Apple Silicon it exposes CPU/device sensors but no GPU
/// sensor, so the SMC `Tg*` keys fill that gap when HID has no GPU reading. A name HID
/// already reported is never added a second time from SMC. The overview `temperature` column
/// is separate: it is the hottest CPU-die sensor, and the GPU readings added here never
/// change it.
public enum TemperatureSources {
    public static func readings(hid: HIDTemperatureSensors?, smc: SMC?,
                                smcKeys: [FourCC]) -> [TemperatureReading]? {
        guard let hid else {
            return smc.map { SMCTemperatures.read($0, keys: smcKeys) }
        }
        var readings = hid.read()
        if let smc, !readings.contains(where: { $0.category == .gpu }) {
            let names = Set(readings.map(\.name))
            let gpuKeys = smcKeys.filter { SMCTemperatures.category(for: $0) == .gpu }
            readings += SMCTemperatures.read(smc, keys: gpuKeys).filter { !names.contains($0.name) }
        }
        return readings
    }
}
