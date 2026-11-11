import Foundation

/// A temperature → fan-speed curve. Speed is a fraction (0...1) of the fan's own min…max range,
/// so one curve applies to fans with different limits.
public struct FanCurve: Codable, Sendable, Hashable {
    public struct Point: Codable, Sendable, Hashable {
        public var celsius: Double
        public var fraction: Double
        public init(celsius: Double, fraction: Double) {
            self.celsius = celsius
            self.fraction = min(max(fraction, 0), 1)
        }
    }

    public private(set) var points: [Point]

    public init(points: [Point]) {
        self.points = points.sorted { $0.celsius < $1.celsius }
    }

    /// Piecewise-linear interpolation; flat beyond the first and last points.
    public func fraction(at celsius: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if celsius <= first.celsius { return first.fraction }
        if celsius >= last.celsius { return last.fraction }
        for (a, b) in zip(points, points.dropFirst()) where celsius <= b.celsius {
            let span = b.celsius - a.celsius
            guard span > 0 else { return b.fraction }
            return a.fraction + (b.fraction - a.fraction) * (celsius - a.celsius) / span
        }
        return last.fraction
    }

    // Each preset climbs in ramps separated by short plateaus: the fans settle on a tread instead
    // of tracking every degree, and the next ramp is steep enough to stay ahead of the heat.
    // Quiet ≤ Balanced ≤ Performance at every temperature.

    public static let quiet = FanCurve(points: [
        .init(celsius: 55, fraction: 0.00),
        .init(celsius: 60, fraction: 0.00),   // tread: stay silent through idle warmth
        .init(celsius: 68, fraction: 0.12),
        .init(celsius: 71, fraction: 0.12),   // tread: hold the first quiet step
        .init(celsius: 80, fraction: 0.40),
        .init(celsius: 83, fraction: 0.40),   // tread: the old 80 °C anchor speed
        .init(celsius: 90, fraction: 0.72),
        .init(celsius: 93, fraction: 0.72),   // tread: keep the fans steady in the low 90s
        .init(celsius: 95, fraction: 0.88),
        .init(celsius: 100, fraction: 1.00),
    ])

    public static let balanced = FanCurve(points: [
        .init(celsius: 45, fraction: 0.00),
        .init(celsius: 50, fraction: 0.00),   // tread: no fan noise while the machine idles
        .init(celsius: 58, fraction: 0.15),
        .init(celsius: 61, fraction: 0.15),   // tread: first gentle step
        .init(celsius: 70, fraction: 0.40),
        .init(celsius: 73, fraction: 0.40),   // tread: the old 70 °C anchor speed
        .init(celsius: 82, fraction: 0.65),
        .init(celsius: 85, fraction: 0.65),   // tread: holds through a short workload spike
        .init(celsius: 92, fraction: 0.92),
        .init(celsius: 95, fraction: 0.92),   // tread: near full speed before the last ramp
        .init(celsius: 100, fraction: 1.00),
    ])

    public static let performance = FanCurve(points: [
        .init(celsius: 40, fraction: 0.20),
        .init(celsius: 48, fraction: 0.32),
        .init(celsius: 51, fraction: 0.32),   // tread: early step to keep the fans audible but calm
        .init(celsius: 58, fraction: 0.58),
        .init(celsius: 61, fraction: 0.58),   // tread: the old 60 °C anchor speed
        .init(celsius: 68, fraction: 0.72),
        .init(celsius: 71, fraction: 0.72),   // tread: short plateau before the final ramp
        .init(celsius: 78, fraction: 0.95),
        .init(celsius: 81, fraction: 1.00),
        .init(celsius: 100, fraction: 1.00),  // tread: full speed through sustained heat
    ])
}

public enum TemperatureSource: String, Codable, Sendable, CaseIterable {
    case cpu, gpu, hottest
}

public struct CurveSettings: Codable, Sendable, Hashable {
    public var curve: FanCurve
    public var source: TemperatureSource
    /// Falling temperature must drop this many °C below the last applied value before the curve follows it.
    public var hysteresis: Double
    /// Max change of the commanded speed, in RPM per second.
    public var maxSlewRPMPerSecond: Double
    /// Never command less than the firmware wants: release to automatic instead.
    public var onlyIncrease: Bool

    public init(curve: FanCurve, source: TemperatureSource = .hottest, hysteresis: Double = 3,
                maxSlewRPMPerSecond: Double = 300, onlyIncrease: Bool = true) {
        self.curve = curve
        self.source = source
        self.hysteresis = hysteresis
        self.maxSlewRPMPerSecond = maxSlewRPMPerSecond
        self.onlyIncrease = onlyIncrease
    }
}
