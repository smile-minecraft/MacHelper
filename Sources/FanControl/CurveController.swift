import Foundation

/// What the controller wants done with one fan this tick.
public enum FanCommand: Sendable, Equatable {
    /// Hand control back to the firmware.
    case automatic
    case manual(rpm: Double)
}

/// Hard limits enforced by the Helper. Not user-configurable.
public struct SafetyLimits: Sendable, Hashable {
    /// Any sensor at or above this → release to firmware immediately.
    public var releaseAboveCelsius: Double
    /// After a trip, control resumes only once the hottest sensor is back below this.
    public var resumeBelowCelsius: Double
    // Apple Silicon dies routinely run near 100 °C under load (Tj max ≈ 110 °C), so a lower trip point would
    // hand control back exactly when a curve matters. Returning to firmware is always safe: it has its own protection.
    public init(releaseAboveCelsius: Double = 108, resumeBelowCelsius: Double = 100) {
        self.releaseAboveCelsius = releaseAboveCelsius
        self.resumeBelowCelsius = resumeBelowCelsius
    }
    public static let standard = SafetyLimits()
}

/// Inputs for one control tick of one fan.
public struct FanTickInput: Sendable {
    public var sourceCelsius: Double
    /// Hottest of all sensors, for the safety valve.
    public var hottestCelsius: Double
    public var fanMinRPM: Double
    public var fanMaxRPM: Double
    /// The firmware's own target, only meaningful while the fan is in automatic mode.
    public var firmwareTargetRPM: Double?
    public var dt: TimeInterval

    public init(sourceCelsius: Double, hottestCelsius: Double, fanMinRPM: Double, fanMaxRPM: Double,
                firmwareTargetRPM: Double?, dt: TimeInterval) {
        self.sourceCelsius = sourceCelsius
        self.hottestCelsius = hottestCelsius
        self.fanMinRPM = fanMinRPM
        self.fanMaxRPM = fanMaxRPM
        self.firmwareTargetRPM = firmwareTargetRPM
        self.dt = dt
    }
}

/// Stateful curve evaluation for one fan: hysteresis, slew-rate limiting, clamping,
/// "only increase" hand-off and the over-temperature safety valve.
public struct CurveController: Sendable {
    public var settings: CurveSettings
    public let limits: SafetyLimits

    /// Temperature the curve is currently evaluated at (after hysteresis).
    public private(set) var effectiveCelsius: Double?
    public private(set) var lastCommandedRPM: Double?
    /// Firmware target observed the last time the fan was automatic.
    private var lastFirmwareRPM: Double?

    public init(settings: CurveSettings, limits: SafetyLimits = .standard) {
        self.settings = settings
        self.limits = limits
    }

    public mutating func step(_ input: FanTickInput) -> FanCommand {
        // 1. Safety valve: hot → firmware owns the fan, whatever the curve says.
        if input.hottestCelsius >= limits.releaseAboveCelsius || !input.sourceCelsius.isFinite {
            return release()
        }

        // 2. Hysteresis: follow rises immediately, follow falls only past the dead band.
        let t = input.sourceCelsius
        if let e = effectiveCelsius {
            if t > e || t < e - settings.hysteresis { effectiveCelsius = t }
        } else {
            effectiveCelsius = t
        }

        let lo = input.fanMinRPM, hi = max(input.fanMaxRPM, input.fanMinRPM)
        var desired = lo + settings.curve.fraction(at: effectiveCelsius!) * (hi - lo)

        // 3. Only-increase: if the firmware already wants at least this much, let it drive.
        if let fw = input.firmwareTargetRPM { lastFirmwareRPM = fw }
        if settings.onlyIncrease, let fw = lastFirmwareRPM {
            let margin = 50.0
            if lastCommandedRPM == nil, desired <= fw + margin { return release(keepTemperature: true) }
            if lastCommandedRPM != nil, desired < fw { return release(keepTemperature: true) }
            desired = max(desired, fw)
        }

        // 4. Slew limit, starting from the firmware's speed when we first take over.
        let start = lastCommandedRPM ?? lastFirmwareRPM ?? desired
        let maxStep = settings.maxSlewRPMPerSecond * max(input.dt, 0)
        var next = desired
        if maxStep > 0 { next = min(max(desired, start - maxStep), start + maxStep) }

        // 5. Clamp to the fan's physical range.
        next = min(max(next, lo), hi)
        lastCommandedRPM = next
        return .manual(rpm: next)
    }

    private mutating func release(keepTemperature: Bool = false) -> FanCommand {
        lastCommandedRPM = nil
        if !keepTemperature { effectiveCelsius = nil }
        return .automatic
    }
}
