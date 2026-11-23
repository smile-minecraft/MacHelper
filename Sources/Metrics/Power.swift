import CSystemBridge
import Foundation
import SMCKit

public struct PowerReading: Sendable, Hashable, Codable {
    // nil = not reported on this machine/OS. On macOS 27 (M4) IOReport's CPU/ANE/DRAM channels
    // stay at zero for non-root callers; CPU falls back to the SMC rails on the base M4.
    public var cpuWatts: Double?
    public var gpuWatts: Double?
    public var aneWatts: Double?
    public var dramWatts: Double?
    /// Whole-system power from the SMC (`PSTR`), when available.
    public var systemWatts: Double?
    /// Whether this Mac has the `PSTR` system rail at all, independent of this sample's value.
    /// History uses it to keep the `power` column meaning system watts on such Macs even when
    /// one reading drops out. nil (older encoded readings) means unknown.
    public var hasSystemRail: Bool?
    /// Every energy-model channel, in watts, keyed by channel name.
    public var channels: [String: Double]
}

/// Samples the IOReport "Energy Model" group. Works without root, unlike `powermetrics`.
/// Each `sample()` returns average power since the previous call.
///
/// IOReport only has that group on Apple Silicon. Intel Macs have no per-rail channel to
/// subscribe to, so there the SMC `PSTR` system rail is the one measurement and a reading
/// carries the whole-system wattage with no split.
public final class PowerSampler: @unchecked Sendable {
    /// nil when this Mac has no "Energy Model" group (Intel) or the subscription could not be
    /// created. `sample()` then reads the SMC rails only.
    private let ioReport: (subscription: IOReportSubscriptionRef, channels: CFMutableDictionary)?
    private var previous: (CFDictionary, Date)?
    private let smc: SMC?
    private let hasSystemRail: Bool
    private let lock = NSLock()

    /// nil only when this Mac has neither IOReport's energy model nor the SMC `PSTR` rail,
    /// i.e. when there is nothing power could be measured from.
    public convenience init?(smc: SMC? = nil) {
        self.init(smc: smc, energyModel: Self.subscribeEnergyModel())
    }

    /// One source is enough: the per-rail channels on Apple Silicon, the SMC `PSTR` rail on Intel.
    /// A nil `energyModel` is the Intel case; tests use it to run that path on a Mac that does
    /// have IOReport.
    init?(smc: SMC?, energyModel: (subscription: IOReportSubscriptionRef, channels: CFMutableDictionary)?) {
        let systemRail = smc?.keyExists("PSTR") == true
        guard Self.canMeasure(ioReport: energyModel != nil, systemRail: systemRail) else { return nil }
        ioReport = energyModel
        self.smc = smc
        hasSystemRail = systemRail
    }

    /// One source is enough: the per-rail channels on Apple Silicon, or `PSTR` on Intel.
    static func canMeasure(ioReport: Bool, systemRail: Bool) -> Bool {
        ioReport || systemRail
    }

    public func sample() -> PowerReading? {
        lock.withLock {
            Self.reading(watts: ioReportWatts(),
                         systemWatts: smc.flatMap { SMCPowerRail.watts($0, key: "PSTR") },
                         cpuFallback: ChipFamily.current.isBaseM4 ? smc.flatMap(Self.cpuRailWatts) : nil,
                         hasSystemRail: hasSystemRail)
        }
    }

    /// Turns the two sources into one reading. `watts` is nil when IOReport is unavailable
    /// (Intel) or still warming up; the SMC `PSTR` value then stands on its own, with no per-rail
    /// split. nil when nothing could be measured, so a missing sensor never becomes a row of zeros.
    static func reading(watts: [String: Double]?, systemWatts: Double?, cpuFallback: Double?,
                        hasSystemRail: Bool) -> PowerReading? {
        let channels = watts ?? [:]
        /// Sum of matching channels; nil when nothing matched or every match reported exactly zero
        /// (a real rail is never exactly 0 J over a sampling interval).
        func sum(_ match: (String) -> Bool) -> Double? {
            let total = channels.filter { match($0.key) }.values.reduce(0, +)
            return total > 0 ? total : nil
        }
        // macOS 27 leaves IOReport's CPU energy frozen for unprivileged readers on the base M4.
        // The SMC still reports the CPU cluster rails there: PP0b (P cores), PPbb (E cores)
        // and PP7b (CPU SRAM). `PZC0` is not used because it also rises with GPU load.
        let reading = PowerReading(
            cpuWatts: cpuFallback ?? sum { $0 == "CPU Energy" } ?? sum { $0.hasSuffix("CPU Energy") },
            gpuWatts: sum { $0 == "GPU Energy" } ?? sum { $0 == "GPU" },
            aneWatts: sum { $0.hasPrefix("ANE") },
            dramWatts: sum { $0 == "DRAM" },
            systemWatts: systemWatts,
            hasSystemRail: hasSystemRail,
            channels: channels
        )
        let measured = [reading.cpuWatts, reading.gpuWatts, reading.aneWatts, reading.dramWatts,
                        reading.systemWatts]
        return measured.contains { $0 != nil } ? reading : nil
    }

    /// Per-channel watts averaged over the interval since the previous call, or nil when this Mac
    /// has no energy model or the first sample has no interval to divide by yet.
    private func ioReportWatts() -> [String: Double]? {
        guard let ioReport,
              let current = IOReportCreateSamples(ioReport.subscription, ioReport.channels, nil)
        else { return nil }
        let now = Date()
        defer { previous = (current, now) }
        guard let (prev, prevTime) = previous,
              let delta = IOReportCreateSamplesDelta(prev, current, nil)
        else { return nil }
        let seconds = now.timeIntervalSince(prevTime)
        guard seconds > 0 else { return nil }

        var watts: [String: Double] = [:]
        let items = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary] ?? []
        for channel in items {
            guard let name = IOReportChannelGetChannelName(channel) as String? else { continue }
            let unit = (IOReportChannelGetUnitLabel(channel) as String?)?.trimmingCharacters(in: .whitespaces) ?? ""
            let raw = Double(IOReportSimpleGetIntegerValue(channel, 0))
            let joules: Double = switch unit {
            case "mJ": raw / 1e3
            case "uJ", "µJ": raw / 1e6
            case "nJ": raw / 1e9
            default: raw / 1e3
            }
            watts[name, default: 0] += joules / seconds
        }
        return watts
    }

    private static func subscribeEnergyModel() -> (subscription: IOReportSubscriptionRef,
                                                   channels: CFMutableDictionary)? {
        guard let energy = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0),
              let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, energy)
        else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(nil, mutable, &subscribed, 0, nil),
              let subscribed
        else { return nil }
        return (subscription, subscribed.takeRetainedValue())
    }

    /// CPU-only SMC rails on the base M4: `PP0b` is the P-cluster, `PPbb` the E-cluster and
    /// `PP7b` CPU SRAM. Values that are zero or unreadable are dropped, so an unsupported rail
    /// cannot turn into a real zero wattage.
    private static func cpuRailWatts(_ smc: SMC) -> Double? {
        let keys: [FourCC] = ["PP0b", "PP7b", "PPbb"]
        let values = keys.compactMap { SMCPowerRail.watts(smc, key: $0) }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

/// Which GPU a single-reading consumer should report on a Mac with more than one accelerator.
///
/// Intel Macs with a discrete GPU expose the integrated and the discrete GPU as two IOAccelerator
/// services, and only one of them is doing the work. Picking the busiest entry keeps the number
/// and the chart aligned with what the machine is actually running on. A tie keeps the first
/// entry, which is the order IOAccelerator itself returned; an empty list has no selection.
public enum GPUSelection {
    public static func busiest(_ readings: [GPUReading]) -> GPUReading? {
        readings.max { $0.utilization < $1.utilization }
    }
}
