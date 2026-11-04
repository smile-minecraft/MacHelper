import Foundation
import Testing
@testable import FanControl

@Suite struct FanPolicyTests {
    @Test func codableRoundTrip() throws {
        let policies: [FanPolicy] = [
            .automatic,
            FanPolicy(mode: .fixed(fraction: 0.4)),
            FanPolicy(mode: .curve(CurveSettings(curve: .balanced, source: .cpu, hysteresis: 4, onlyIncrease: false))),
        ]
        for p in policies {
            let decoded = try JSONDecoder().decode(FanPolicy.self, from: JSONEncoder().encode(p))
            #expect(decoded == p)
        }
    }

    @Test func validationAcceptsPresets() throws {
        for curve in [FanCurve.quiet, .balanced, .performance] {
            _ = try FanPolicy(mode: .curve(CurveSettings(curve: curve))).validated()
        }
    }

    @Test func validationRejectsBadInput() {
        let bad: [FanPolicy] = [
            FanPolicy(mode: .fixed(fraction: 1.5)),
            FanPolicy(mode: .fixed(fraction: .nan)),
            FanPolicy(mode: .curve(CurveSettings(curve: FanCurve(points: [.init(celsius: 50, fraction: 0.5)])))),
            FanPolicy(mode: .curve(CurveSettings(curve: FanCurve(points: [.init(celsius: 5, fraction: 0), .init(celsius: 60, fraction: 1)])))),
            FanPolicy(mode: .curve(CurveSettings(curve: .balanced, hysteresis: 40))),
        ]
        for p in bad {
            #expect(throws: FanPolicyError.self) { try p.validated() }
        }
    }

    @Test func onlyFixedNeedsHeartbeat() {
        #expect(FanPolicy(mode: .fixed(fraction: 0.5)).requiresHeartbeat)
        #expect(!FanPolicy.automatic.requiresHeartbeat)
        #expect(!FanPolicy(mode: .curve(CurveSettings(curve: .quiet))).requiresHeartbeat)
    }

    @Test func safetyDefaults() {
        #expect(SafetyLimits.standard.releaseAboveCelsius > SafetyLimits.standard.resumeBelowCelsius)
    }
}
