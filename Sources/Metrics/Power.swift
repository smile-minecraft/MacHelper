import CSystemBridge
import Foundation
import SMCKit

public struct PowerReading: Sendable, Hashable, Codable {
    // nil = not reported on this machine/OS. On macOS 27 (M4) IOReport only exposes GPU energy to
    // non-root callers; CPU/ANE/DRAM channels exist but stay at zero.
    public var cpuWatts: Double?
    public var gpuWatts: Double?
    public var aneWatts: Double?
    public var dramWatts: Double?
    /// Whole-system power from the SMC (`PSTR`), when available.
    public var systemWatts: Double?
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
            return PowerReading(
                cpuWatts: sum { $0 == "CPU Energy" } ?? sum { $0.hasSuffix("CPU Energy") },
                gpuWatts: sum { $0 == "GPU Energy" } ?? sum { $0 == "GPU" },
                aneWatts: sum { $0.hasPrefix("ANE") },
                dramWatts: sum { $0 == "DRAM" },
                systemWatts: smc.flatMap { try? $0.readDouble("PSTR") },
                channels: watts
            )
        }
    }
}
