import Foundation

/// Whether a pass of the automatic fan switching should send its policy to the Helper.
///
/// Passes run on a timer and on app notifications, and may run again before an earlier request
/// finishes. The caller therefore keeps only two facts about the Helper: the policy it last
/// confirmed (`applied`) and the policy whose request is still in flight (`applying`). A request
/// that failed is not recorded as applied, so the next pass sends it again.
public enum FanAutoSwitchDecision {
    /// - Parameters:
    ///   - policy: The policy the current state asks for: a matching rule's target, or the base policy.
    ///   - applied: The policy the Helper last confirmed, or `nil` when nothing is known yet.
    ///   - applying: The policy with a request in flight, or `nil`. At most one request is allowed.
    ///   - helperEnabled: Whether the Helper is enabled and can accept requests.
    ///   - hasRuleContext: Whether a rule matches now or matched on the previous pass. With neither,
    ///     and without a confirmed policy, there is nothing to undo and the first pass stays quiet.
    public static func shouldApply(
        policy: FanPolicy,
        applied: FanPolicy?,
        applying: FanPolicy?,
        helperEnabled: Bool,
        hasRuleContext: Bool
    ) -> Bool {
        guard helperEnabled, applying == nil, policy != applied else { return false }
        return hasRuleContext || applied != nil
    }
}
