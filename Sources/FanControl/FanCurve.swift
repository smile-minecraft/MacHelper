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

    public static let quiet = FanCurve(points: [.init(celsius: 60, fraction: 0), .init(celsius: 80, fraction: 0.4), .init(celsius: 95, fraction: 1)])
    public static let balanced = FanCurve(points: [.init(celsius: 50, fraction: 0), .init(celsius: 70, fraction: 0.4), .init(celsius: 90, fraction: 1)])
    public static let performance = FanCurve(points: [.init(celsius: 40, fraction: 0.2), .init(celsius: 60, fraction: 0.6), .init(celsius: 80, fraction: 1)])
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
