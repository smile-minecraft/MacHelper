import ServiceManagement

/// The privileged Helper's first-launch bookkeeping. Installing it goes through `PermissionFlow`
/// (explanation, install, then the floating guide for the approval), from Settings → Helper and
/// Settings → Permissions alike.
enum HelperSetup {
    static let onboardingKey = "onboarding.helper.shown"

    /// Offered once, on a launch where the Helper isn't running; never in snapshot runs.
    static var shouldOfferOnboarding: Bool {
        !CommandLine.arguments.contains { $0.hasPrefix("--snapshot") }
            && !UserDefaults.standard.bool(forKey: onboardingKey)
            && HelperClient.shared.status != .enabled
    }
}
