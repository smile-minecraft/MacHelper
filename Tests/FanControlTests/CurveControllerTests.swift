import Testing
@testable import FanControl

private func input(_ t: Double, hottest: Double? = nil, fw: Double? = nil, dt: Double = 1) -> FanTickInput {
    FanTickInput(sourceCelsius: t, hottestCelsius: hottest ?? t, fanMinRPM: 1000, fanMaxRPM: 5000,
                 firmwareTargetRPM: fw, dt: dt)
}

private let linear = FanCurve(points: [.init(celsius: 40, fraction: 0), .init(celsius: 80, fraction: 1)])

@Suite struct FanCurveTests {
    @Test func interpolation() {
        #expect(linear.fraction(at: 20) == 0)
        #expect(linear.fraction(at: 60) == 0.5)
        #expect(linear.fraction(at: 100) == 1)
    }

    @Test func pointsAreSortedAndClamped() {
        let c = FanCurve(points: [.init(celsius: 80, fraction: 2), .init(celsius: 40, fraction: -1)])
        #expect(c.points.map(\.celsius) == [40, 80])
        #expect(c.points.map(\.fraction) == [0, 1])
    }
}

@Suite struct CurveControllerTests {
    func controller(onlyIncrease: Bool = false, hysteresis: Double = 3, slew: Double = 0) -> CurveController {
        CurveController(settings: CurveSettings(curve: linear, hysteresis: hysteresis,
                                                maxSlewRPMPerSecond: slew, onlyIncrease: onlyIncrease))
    }

    @Test func followsCurve() {
        var c = controller()
        #expect(c.step(input(60)) == .manual(rpm: 3000))
    }

    @Test func hysteresisIgnoresSmallDrops() {
        var c = controller(hysteresis: 3)
        _ = c.step(input(60))
        #expect(c.step(input(58)) == .manual(rpm: 3000))   // within dead band
        #expect(c.step(input(56)) == .manual(rpm: 2600))   // past it
        #expect(c.step(input(57)) == .manual(rpm: 2700))   // rises follow immediately
    }

    @Test func slewLimit() {
        var c = controller(slew: 500)
        _ = c.step(input(40))                               // 1000 rpm
        #expect(c.step(input(80)) == .manual(rpm: 1500))   // wants 5000, limited
        #expect(c.step(input(80, dt: 2)) == .manual(rpm: 2500))
    }

    @Test func safetyValveReleases() {
        var c = controller()
        _ = c.step(input(60))
        #expect(c.step(input(60, hottest: 109)) == .automatic)
    }

    @Test func nonFiniteTemperatureReleases() {
        var c = controller()
        #expect(c.step(input(.nan, hottest: 50)) == .automatic)
    }

    @Test func onlyIncreaseDefersToFirmware() {
        var c = controller(onlyIncrease: true)
        // Firmware wants 3500, curve wants 3000 → stay automatic.
        #expect(c.step(input(60, fw: 3500)) == .automatic)
        // Curve rises past firmware → take over.
        #expect(c.step(input(70)) == .manual(rpm: 4000))
        // Curve falls back below the firmware's last request → hand back.
        #expect(c.step(input(55)) == .automatic)
    }

    @Test func clampsToFanRange() {
        var c = CurveController(settings: CurveSettings(
            curve: FanCurve(points: [.init(celsius: 0, fraction: 1)]), maxSlewRPMPerSecond: 0, onlyIncrease: false))
        let cmd = c.step(FanTickInput(sourceCelsius: 50, hottestCelsius: 50, fanMinRPM: 1200, fanMaxRPM: 4800,
                                      firmwareTargetRPM: nil, dt: 1))
        #expect(cmd == .manual(rpm: 4800))
    }
}

@Suite struct FanAutoRuleTests {
    @Test func firstMatchingRuleWins() {
        let xcode = FanAutoRule(trigger: .appRunning(bundleID: "com.apple.dt.Xcode", name: "Xcode"), target: .performance)
        let battery = FanAutoRule(trigger: .onBattery, target: .quiet)
        let rules = [xcode, battery]
        #expect(FanAutoRule.firstMatch(rules, runningBundleIDs: ["com.apple.dt.Xcode"], onBattery: true)?.target == .performance)
        #expect(FanAutoRule.firstMatch(rules, runningBundleIDs: [], onBattery: true)?.target == .quiet)
        #expect(FanAutoRule.firstMatch(rules, runningBundleIDs: [], onBattery: false) == nil)
    }

    @Test func targetsAreValidPolicies() {
        for t in FanAutoRule.Target.allCases { #expect((try? t.policy.validated()) != nil) }
        #expect(FanAutoRule.Target.system.policy == .automatic)
    }
}
