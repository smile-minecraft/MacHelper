import Testing
@testable import FanControl

private let linear = FanCurve(points: [.init(celsius: 40, fraction: 0), .init(celsius: 80, fraction: 1)])

private func input(_ t: Double, hottest: Double? = nil) -> FanTickInput {
    FanTickInput(sourceCelsius: t, hottestCelsius: hottest ?? t, fanMinRPM: 1000, fanMaxRPM: 5000,
                 firmwareTargetRPM: nil, dt: 1)
}

private func controller(_ silicon: FanSilicon) -> CurveController {
    CurveController(settings: CurveSettings(curve: linear, hysteresis: 3, maxSlewRPMPerSecond: 0, onlyIncrease: false),
                    limits: .for(silicon))
}

@Suite struct SafetyLimitsTests {
    @Test func appleSiliconKeepsTheStandardTripPoints() {
        #expect(SafetyLimits.standard.releaseAboveCelsius == 108)
        #expect(SafetyLimits.standard.resumeBelowCelsius == 100)
        #expect(SafetyLimits.for(.appleSilicon) == .standard)
    }

    @Test func intelTripsBelowItsThermalLimit() {
        let intel = SafetyLimits.for(.intel)
        #expect(intel.releaseAboveCelsius == 95)
        #expect(intel.resumeBelowCelsius == 88)
        // Resume has to stay strictly below the trip point or the valve would chatter.
        #expect(intel.resumeBelowCelsius < intel.releaseAboveCelsius)
    }

    @Test func intelHandsTheFanBackWellBeforeAppleSilicon() {
        var intel = controller(.intel)
        var apple = controller(.appleSilicon)
        _ = intel.step(input(60))
        _ = apple.step(input(60))

        // 95 °C is the Intel trip point: the curve no longer sees this tick.
        #expect(intel.step(input(60, hottest: 95)) == .automatic)
        // The same temperature is ordinary load on Apple Silicon, where the curve keeps control.
        #expect(apple.step(input(60, hottest: 95)) == .manual(rpm: 3000))
        // Only the Apple Silicon limits reach past 108 °C.
        #expect(apple.step(input(60, hottest: 108)) == .automatic)
    }

    @Test func intelStaysInControlJustBelowItsTripPoint() {
        var intel = controller(.intel)
        #expect(intel.step(input(60, hottest: 94.9)) == .manual(rpm: 3000))
    }
}
