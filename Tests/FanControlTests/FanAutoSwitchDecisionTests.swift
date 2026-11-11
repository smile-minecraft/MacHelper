import Testing
@testable import FanControl

@Suite struct FanAutoSwitchDecisionTests {
    private let performance = FanAutoRule.Target.performance.policy
    private let quiet = FanAutoRule.Target.quiet.policy

    private func shouldApply(
        policy: FanPolicy,
        applied: FanPolicy?,
        applying: FanPolicy? = nil,
        helperEnabled: Bool = true,
        hasRuleContext: Bool = true
    ) -> Bool {
        FanAutoSwitchDecision.shouldApply(
            policy: policy, applied: applied, applying: applying,
            helperEnabled: helperEnabled, hasRuleContext: hasRuleContext)
    }

    @Test func appliesARuleOnTheFirstPass() {
        #expect(shouldApply(policy: performance, applied: nil))
    }

    /// The same rule keeps matching, but the last attempt did not land (Helper disabled or XPC
    /// failed): the next pass must send it again instead of trusting the unchanged rule.
    @Test func reappliesWhenThePolicyWasNeverConfirmed() {
        #expect(shouldApply(policy: performance, applied: .automatic))
    }

    @Test func skipsWhenThePolicyIsAlreadyConfirmed() {
        #expect(!shouldApply(policy: performance, applied: performance))
    }

    @Test func doesNotSendASecondRequestWhileOneIsInFlight() {
        #expect(!shouldApply(policy: performance, applied: .automatic, applying: performance))
        #expect(!shouldApply(policy: quiet, applied: .automatic, applying: performance))
    }

    @Test func retriesAfterAFailureClearedTheInFlightRequest() {
        // A failure leaves `applied` at the last confirmed policy and sets `applying` back to nil.
        #expect(shouldApply(policy: performance, applied: .automatic, applying: nil))
    }

    @Test func waitsForTheHelperAndRetriesWhenItComesBack() {
        #expect(!shouldApply(policy: performance, applied: .automatic, helperEnabled: false))
        #expect(shouldApply(policy: performance, applied: .automatic, helperEnabled: true))
    }

    @Test func restoresTheBasePolicyWhenARuleEnds() {
        #expect(shouldApply(policy: .automatic, applied: performance))
    }

    @Test func sendsABasePolicyThatDiffersFromTheConfirmedOneWithoutRules() {
        #expect(shouldApply(policy: .automatic, applied: performance, hasRuleContext: false))
    }

    @Test func staysQuietOnTheFirstPassWithNoRuleAndNoConfirmedPolicy() {
        #expect(!shouldApply(policy: .automatic, applied: nil, hasRuleContext: false))
    }
}
