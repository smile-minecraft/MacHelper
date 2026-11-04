import Foundation

public enum FanMode: String, Sendable, Codable {
    case automatic
    case manual
}

public struct FanReading: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public let actualRPM: Double
    public let targetRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let mode: FanMode

    public init(id: Int, actualRPM: Double, targetRPM: Double, minRPM: Double, maxRPM: Double, mode: FanMode) {
        self.id = id
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.mode = mode
    }
}

/// How manual fan control has to be performed on this machine. Discovered by probing keys,
/// so unknown future chips work as long as they keep one of the known key layouts.
public struct FanControlStrategy: Sendable, Hashable, CustomStringConvertible {
    public enum ModeKeyStyle: Sendable, Hashable {
        /// `F0Md` (Intel, M1–M4)
        case perFanUpper
        /// `F0md` (M5)
        case perFanLower
        /// `FS! ` bitmask (older Intel)
        case forceBitmask
        case none
    }

    public let fanCount: Int
    public let modeKeyStyle: ModeKeyStyle
    /// M3/M4 firmware rejects manual mode unless the `Ftst` diagnostic flag is held at 1.
    public let requiresFtstUnlock: Bool

    public var canControl: Bool { fanCount > 0 && modeKeyStyle != .none }

    public func modeKey(fan: Int) -> FourCC? {
        switch modeKeyStyle {
        case .perFanUpper: FourCC("F\(fan)Md")
        case .perFanLower: FourCC("F\(fan)md")
        case .forceBitmask: FourCC("FS! ")
        case .none: nil
        }
    }

    public var description: String {
        "fans=\(fanCount) modeKey=\(modeKeyStyle) ftstUnlock=\(requiresFtstUnlock)"
    }

    public static func probe(_ smc: SMC, chip: ChipFamily = .current) -> FanControlStrategy {
        let count = (try? smc.readDouble("FNum")).map { Int($0) } ?? 0
        let style: ModeKeyStyle
        if count == 0 {
            style = .none
        } else if smc.keyExists("F0Md") {
            style = .perFanUpper
        } else if smc.keyExists("F0md") {
            style = .perFanLower
        } else if smc.keyExists("FS! ") {
            style = .forceBitmask
        } else {
            style = .none
        }
        // Ftst only matters on M3/M4-class firmware. M5 has no Ftst; M1/M2 do not need it.
        var needsFtst = false
        if case .apple(let gen, _) = chip, gen >= 3, smc.keyExists("Ftst") {
            needsFtst = true
        }
        return FanControlStrategy(fanCount: count, modeKeyStyle: style, requiresFtstUnlock: needsFtst)
    }
}

/// Reads fans, and (as root) writes fan targets. Used by the app for reading and by the Helper for control.
public final class FanDriver: @unchecked Sendable {
    public let smc: SMC
    public let strategy: FanControlStrategy
    private let lock = NSLock()
    private var manualFans: Set<Int> = []

    public init(smc: SMC, strategy: FanControlStrategy? = nil) {
        self.smc = smc
        self.strategy = strategy ?? .probe(smc)
    }

    public func readFans() -> [FanReading] {
        (0..<strategy.fanCount).compactMap { try? readFan($0) }
    }

    public func readFan(_ i: Int) throws -> FanReading {
        let mode: FanMode
        switch strategy.modeKeyStyle {
        case .perFanUpper, .perFanLower:
            mode = (try? smc.readDouble(strategy.modeKey(fan: i)!)).map { $0 == 0 ? .automatic : .manual } ?? .automatic
        case .forceBitmask:
            let mask = Int((try? smc.readDouble("FS! ")) ?? 0)
            mode = mask & (1 << i) != 0 ? .manual : .automatic
        case .none:
            mode = .automatic
        }
        return FanReading(
            id: i,
            actualRPM: try smc.readDouble(FourCC("F\(i)Ac")),
            targetRPM: (try? smc.readDouble(FourCC("F\(i)Tg"))) ?? 0,
            minRPM: (try? smc.readDouble(FourCC("F\(i)Mn"))) ?? 0,
            maxRPM: (try? smc.readDouble(FourCC("F\(i)Mx"))) ?? 0,
            mode: mode
        )
    }

    /// Whether the firmware currently holds the Ftst flag (it is cleared on wake from sleep).
    public var ftstEngaged: Bool {
        ((try? smc.readDouble("Ftst")) ?? 0) != 0
    }

    /// Puts `fan` into manual mode at `rpm`, clamped to the fan's own min/max. Requires root.
    public func setManual(fan: Int, rpm: Double) throws {
        try lock.withLock {
            let reading = try readFan(fan)
            let target = clamp(rpm, reading.minRPM, reading.maxRPM)

            if strategy.requiresFtstUnlock, !ftstEngaged {
                try smc.write("Ftst", value: 1)
            }
            if reading.mode != .manual {
                try writeModeWithRetry(fan: fan, manual: true)
            }
            try smc.write(FourCC("F\(fan)Tg"), value: target)
            manualFans.insert(fan)
        }
    }

    /// Returns `fan` to firmware control. Requires root.
    public func setAutomatic(fan: Int) throws {
        try lock.withLock {
            try writeMode(fan: fan, manual: false)
            manualFans.remove(fan)
            if strategy.requiresFtstUnlock, manualFans.isEmpty {
                try? smc.write("Ftst", value: 0)
            }
        }
    }

    /// Best-effort: return every fan to automatic. Never throws; used by safety paths.
    public func restoreAllAutomatic() {
        lock.withLock {
            for i in 0..<strategy.fanCount { try? writeMode(fan: i, manual: false) }
            manualFans.removeAll()
            if strategy.requiresFtstUnlock { try? smc.write("Ftst", value: 0) }
        }
    }

    /// Call after wake: firmware clears Ftst, so manual fans silently fall back to auto.
    /// Re-engages Ftst and the mode key for fans we believe we own.
    public func reassertAfterWake() throws {
        let owned = lock.withLock { manualFans }
        guard !owned.isEmpty else { return }
        try lock.withLock {
            if strategy.requiresFtstUnlock, !ftstEngaged { try smc.write("Ftst", value: 1) }
            for fan in owned { try writeModeWithRetry(fan: fan, manual: true) }
        }
    }

    // MARK: Private

    private func writeMode(fan: Int, manual: Bool) throws {
        switch strategy.modeKeyStyle {
        case .perFanUpper, .perFanLower:
            try smc.write(strategy.modeKey(fan: fan)!, value: manual ? 1 : 0)
        case .forceBitmask:
            var mask = Int(try smc.readDouble("FS! "))
            if manual { mask |= 1 << fan } else { mask &= ~(1 << fan) }
            try smc.write("FS! ", value: Double(mask))
        case .none:
            throw SMCError.keyNotFound("F0Md")
        }
    }

    /// With Ftst engaged, the firmware may take a moment before it accepts the mode write.
    private func writeModeWithRetry(fan: Int, manual: Bool, attempts: Int = 20) throws {
        var lastError: Error?
        for _ in 0..<attempts {
            do {
                try writeMode(fan: fan, manual: manual)
                if try readFan(fan).mode == (manual ? .manual : .automatic) { return }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw lastError ?? SMCError.smcResult(key: strategy.modeKey(fan: fan) ?? "F0Md", code: 0xff)
    }
}

@inline(__always)
func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    lo > hi ? v : min(max(v, lo), hi)
}
