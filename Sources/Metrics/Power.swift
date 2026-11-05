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
public final class PowerSampler: @unchecked Sendable {
    private let subscription: IOReportSubscriptionRef
    private let channels: CFMutableDictionary
    private var previous: (CFDictionary, Date)?
    private let smc: SMC?
    private let hasSystemRail: Bool
    private let lock = NSLock()

    public init?(smc: SMC? = nil) {
        guard let energy = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0),
              let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, energy)
        else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, mutable, &subscribed, 0, nil),
              let subscribed
        else { return nil }
        subscription = sub
        channels = subscribed.takeRetainedValue()
        self.smc = smc
        hasSystemRail = smc?.keyExists("PSTR") == true
    }

    public func sample() -> PowerReading? {
        lock.withLock {
            guard let current = IOReportCreateSamples(subscription, channels, nil) else { return nil }
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

            /// Sum of matching channels; nil when nothing matched or every match reported exactly zero
            /// (a real rail is never exactly 0 J over a sampling interval).
            func sum(_ match: (String) -> Bool) -> Double? {
                let total = watts.filter { match($0.key) }.values.reduce(0, +)
                return total > 0 ? total : nil
            }
            // macOS 27 leaves IOReport's CPU energy frozen for unprivileged readers on the base M4.
            // The SMC still reports the CPU cluster rails there: PP0b (P cores), PPbb (E cores)
            // and PP7b (CPU SRAM). `PZC0` is not used because it also rises with GPU load.
            let ioCPU = sum { $0 == "CPU Energy" } ?? sum { $0.hasSuffix("CPU Energy") }
            let smcCPU = ChipFamily.current.isBaseM4 ? smc.flatMap(Self.cpuRailWatts) : nil
            return PowerReading(
                cpuWatts: smcCPU ?? ioCPU,
                gpuWatts: sum { $0 == "GPU Energy" } ?? sum { $0 == "GPU" },
                aneWatts: sum { $0.hasPrefix("ANE") },
                dramWatts: sum { $0 == "DRAM" },
                systemWatts: smc.flatMap { SMCPowerRail.watts($0, key: "PSTR") },
                hasSystemRail: hasSystemRail,
                channels: watts
            )
        }
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
