import Foundation

/// What the Helper should do with the fans. Sent by the app, persisted and executed by the Helper.
public struct FanPolicy: Codable, Sendable, Equatable {
    public enum Mode: Codable, Sendable, Equatable {
        /// Firmware control.
        case automatic
        /// Fixed speed as a fraction (0...1) of each fan's min…max range.
        /// Requires the app's heartbeat: if the app goes away, the Helper returns to automatic.
        case fixed(fraction: Double)
        /// Temperature curve. Runs inside the Helper and keeps running when the app quits.
        case curve(CurveSettings)
    }

    public var mode: Mode

    public init(mode: Mode) { self.mode = mode }

    public static let automatic = FanPolicy(mode: .automatic)

    public var requiresHeartbeat: Bool {
        if case .fixed = mode { return true }
        return false
    }

    /// Validates untrusted input (the Helper calls this on everything it receives).
    public func validated() throws -> FanPolicy {
        switch mode {
        case .automatic:
            return self
        case .fixed(let f):
            guard f.isFinite, (0...1).contains(f) else { throw FanPolicyError.invalid("fixed fraction out of range") }
            return self
        case .curve(let s):
            guard (2...12).contains(s.curve.points.count) else { throw FanPolicyError.invalid("curve needs 2–12 points") }
            for p in s.curve.points {
                guard p.celsius.isFinite, p.fraction.isFinite, (20...110).contains(p.celsius), (0...1).contains(p.fraction)
                else { throw FanPolicyError.invalid("curve point out of range") }
            }
            guard s.hysteresis.isFinite, (0...15).contains(s.hysteresis) else { throw FanPolicyError.invalid("hysteresis out of range") }
            guard s.maxSlewRPMPerSecond.isFinite, (0...10_000).contains(s.maxSlewRPMPerSecond)
            else { throw FanPolicyError.invalid("slew rate out of range") }
            return self
        }
    }
}

public enum FanPolicyError: Error, CustomStringConvertible, Sendable {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let m): "Invalid fan policy: \(m)" }
    }
}

/// Built-in profiles shown in the UI.
public enum FanProfile: String, Codable, Sendable, CaseIterable, Identifiable {
    case quiet, balanced, performance, custom
    public var id: String { rawValue }

    public var presetCurve: FanCurve? {
        switch self {
        case .quiet: .quiet
        case .balanced: .balanced
        case .performance: .performance
        case .custom: nil
        }
    }
}

// MARK: - Automatic profile switching

/// "When <trigger>, use <target>". Rules are checked in order; the first match wins, and with no
/// match the policy the user chose by hand applies.
public struct FanAutoRule: Codable, Sendable, Hashable, Identifiable {
    public enum Trigger: Codable, Sendable, Hashable {
        case appRunning(bundleID: String, name: String)
        case onBattery
        case onPowerAdapter
    }

    public enum Target: String, Codable, Sendable, CaseIterable, Identifiable {
        case system, quiet, balanced, performance
        public var id: String { rawValue }

        public var policy: FanPolicy {
            switch self {
            case .system: .automatic
            case .quiet: FanPolicy(mode: .curve(CurveSettings(curve: .quiet)))
            case .balanced: FanPolicy(mode: .curve(CurveSettings(curve: .balanced)))
            case .performance: FanPolicy(mode: .curve(CurveSettings(curve: .performance)))
            }
        }
    }

    public var id: UUID
    public var trigger: Trigger
    public var target: Target

    public init(id: UUID = UUID(), trigger: Trigger, target: Target) {
        self.id = id
        self.trigger = trigger
        self.target = target
    }

    public func matches(runningBundleIDs: Set<String>, onBattery: Bool) -> Bool {
        switch trigger {
        case .appRunning(let id, _): runningBundleIDs.contains(id)
        case .onBattery: onBattery
        case .onPowerAdapter: !onBattery
        }
    }

    public static func firstMatch(_ rules: [FanAutoRule], runningBundleIDs: Set<String>, onBattery: Bool) -> FanAutoRule? {
        rules.first { $0.matches(runningBundleIDs: runningBundleIDs, onBattery: onBattery) }
    }
}
