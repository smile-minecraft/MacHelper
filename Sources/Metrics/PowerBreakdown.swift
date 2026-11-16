import Foundation

/// How one power reading splits up, using only rails that were actually measured.
///
/// The whole-system rail (`PSTR`) is the total when the Mac has it. The chip node is the sum of
/// the measured chip parts (CPU, GPU, Neural Engine, memory). Displays, storage, fans and power
/// conversion have no separate sensor, so whatever the total has beyond the chip parts is one
/// "rest of system" share instead of invented per-part numbers.
public struct PowerBreakdown: Sendable, Equatable {
    public enum Part: String, Sendable, CaseIterable {
        case cpu, gpu, neuralEngine, memory
    }

    public struct Component: Sendable, Equatable {
        public let part: Part
        public let watts: Double
    }

    /// System watts, or the sum of the parts on a Mac without the system rail.
    public let total: Double
    /// Measured chip parts, in `Part` order; parts without a reading are left out.
    public let components: [Component]
    /// Sum of `components`.
    public let chip: Double
    /// Total minus the chip parts; nil without a system rail (nothing to subtract from).
    public let rest: Double?
    public let hasSystemRail: Bool

    public init?(_ r: PowerReading) {
        let pairs: [(Part, Double?)] = [(.cpu, r.cpuWatts), (.gpu, r.gpuWatts), (.neuralEngine, r.aneWatts), (.memory, r.dramWatts)]
        components = pairs.compactMap { part, w in
            guard let w, w.isFinite, w > 0 else { return nil }
            return Component(part: part, watts: w)
        }
        chip = components.reduce(0) { $0 + $1.watts }
        if let system = r.systemWatts, system.isFinite, system > 0 {
            hasSystemRail = true
            // The rails are read a moment apart; a chip sum above the system rail means the
            // remainder is too small to measure, not that it is negative.
            total = max(system, chip)
            rest = max(system - chip, 0)
        } else {
            hasSystemRail = false
            total = chip
            rest = nil
        }
        guard total > 0 else { return nil }
    }

    public func share(_ watts: Double) -> Double { total > 0 ? watts / total : 0 }
}
