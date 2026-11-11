import Testing
@testable import FanControl

@Suite struct PresetCurveTests {
    static let presets: [(FanProfile, FanCurve)] = [
        (.quiet, .quiet), (.balanced, .balanced), (.performance, .performance),
    ]

    private static func treads(in curve: FanCurve) -> [(FanCurve.Point, FanCurve.Point)] {
        Array(zip(curve.points, curve.points.dropFirst()).filter { $0.0.fraction == $0.1.fraction })
    }

    private static func ramps(in curve: FanCurve) -> [(FanCurve.Point, FanCurve.Point)] {
        Array(zip(curve.points, curve.points.dropFirst()).filter { $0.0.fraction < $0.1.fraction })
    }

    @Test func presetsAreValidAndStepped() throws {
        for (profile, curve) in Self.presets {
            let label = "\(profile)"
            #expect((2...12).contains(curve.points.count), "\(label): point count")
            for (a, b) in zip(curve.points, curve.points.dropFirst()) {
                #expect(a.celsius < b.celsius, "\(label): temperatures must increase")
            }
            #expect(curve.points.allSatisfy { (20...110).contains($0.celsius) }, "\(label): temperature range")
            #expect(curve.points.allSatisfy { (0...1).contains($0.fraction) }, "\(label): fraction range")
            #expect(Self.treads(in: curve).count >= 2, "\(label): needs at least two treads")
            #expect(Self.ramps(in: curve).count >= 2, "\(label): needs at least two ramps")
            _ = try FanPolicy(mode: .curve(CurveSettings(curve: curve))).validated()
        }
    }

    @Test func fractionStaysConstantAcrossEachTread() {
        for (profile, curve) in Self.presets {
            for (a, b) in Self.treads(in: curve) {
                let middle = (a.celsius + b.celsius) / 2
                #expect(curve.fraction(at: a.celsius) == a.fraction, "\(profile): tread start \(a.celsius)")
                #expect(curve.fraction(at: middle) == a.fraction, "\(profile): tread middle \(middle)")
                #expect(curve.fraction(at: b.celsius) == b.fraction, "\(profile): tread end \(b.celsius)")
            }
        }
    }

    @Test func everyTreadIsBoundedByRamps() {
        for (profile, curve) in Self.presets {
            for (a, b) in Self.treads(in: curve) {
                if let before = curve.points.last(where: { $0.celsius < a.celsius }) {
                    #expect(before.fraction < a.fraction, "\(profile): no ramp into tread at \(a.celsius)")
                }
                if let after = curve.points.first(where: { $0.celsius > b.celsius }) {
                    #expect(after.fraction > b.fraction, "\(profile): no ramp out of tread at \(b.celsius)")
                }
            }
        }
    }

    /// The ordering invariant holds on every linear segment, so checking all breakpoints and the
    /// midpoints between them covers the whole 20–110 °C range.
    @Test func quietNeverExceedsBalancedOrPerformance() {
        let breaks = Set(Self.presets.flatMap { $0.1.points.map(\.celsius) }).sorted()
        var samples: [Double] = [20, 110]
        samples.append(contentsOf: breaks)
        for (a, b) in zip(breaks, breaks.dropFirst()) {
            samples.append((a + b) / 2)
        }

        for celsius in samples {
            let quiet = FanCurve.quiet.fraction(at: celsius)
            let balanced = FanCurve.balanced.fraction(at: celsius)
            let performance = FanCurve.performance.fraction(at: celsius)
            #expect(quiet <= balanced, "quiet > balanced at \(celsius) °C")
            #expect(balanced <= performance, "balanced > performance at \(celsius) °C")
        }
    }
}

@Suite struct PresetCurveIdentityTests {
    /// The points the three presets shipped before they became stepped. They must keep opening as
    /// the user's own curve instead of being relabelled as a built-in profile.
    private static let legacyPresetPoints: [[FanCurve.Point]] = [
        [.init(celsius: 60, fraction: 0), .init(celsius: 80, fraction: 0.4), .init(celsius: 95, fraction: 1)],
        [.init(celsius: 50, fraction: 0), .init(celsius: 70, fraction: 0.4), .init(celsius: 90, fraction: 1)],
        [.init(celsius: 40, fraction: 0.2), .init(celsius: 60, fraction: 0.6), .init(celsius: 80, fraction: 1)],
    ]

    @Test func currentPresetPointsResolveToTheirProfile() {
        for (profile, curve) in PresetCurveTests.presets {
            #expect(FanProfile.matching(curve) == profile)
        }
    }

    @Test func legacyPresetPointsResolveToCustom() {
        for points in Self.legacyPresetPoints {
            #expect(FanProfile.matching(FanCurve(points: points)) == .custom)
        }
    }

    @Test func editedPresetResolvesToCustom() {
        var points = FanCurve.balanced.points
        points[1].fraction += 0.01
        #expect(FanProfile.matching(FanCurve(points: points)) == .custom)
    }

    @Test func savedCustomCurveResolvesToCustom() {
        let custom = FanCurve(points: [
            .init(celsius: 30, fraction: 0.10),
            .init(celsius: 75, fraction: 0.55),
            .init(celsius: 105, fraction: 0.90),
        ])
        #expect(FanProfile.matching(custom) == .custom)
    }

    @Test func pointOrderDoesNotChangeIdentity() {
        #expect(FanProfile.matching(FanCurve(points: FanCurve.quiet.points.reversed())) == .quiet)
    }
}
