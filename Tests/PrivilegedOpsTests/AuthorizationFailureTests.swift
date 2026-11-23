import Testing
@testable import PrivilegedOps

/// The app stops a whole clean when the deep request fails; it reads the reason back from the
/// text the Helper sends over XPC (`String(describing: error)`, wrapped as "Helper error: …").
@Suite struct AuthorizationFailureTests {
    private func overXPC(_ error: SystemCleanupError) -> String { "Helper error: \(String(describing: error))" }

    @Test func recognisesEachAuthorizationFailure() {
        #expect(SystemCleanupError.authorizationFailure(in: overXPC(.authorizationCancelled)) == .authorizationCancelled)
        #expect(SystemCleanupError.authorizationFailure(in: overXPC(.authorizationRequired)) == .authorizationRequired)
        #expect(SystemCleanupError.authorizationFailure(in: overXPC(.authorizationDenied(-60005))) == .authorizationDenied(-60005))
        #expect(SystemCleanupError.authorizationFailure(in: String(describing: SystemCleanupError.authorizationDenied(-60007))) == .authorizationDenied(-60007))
    }

    @Test func otherFailuresAreNotAuthorizationFailures() {
        #expect(SystemCleanupError.authorizationFailure(in: overXPC(.unknownTarget("deep.x"))) == nil)
        #expect(SystemCleanupError.authorizationFailure(in: "XPC connection failed: interrupted") == nil)
        #expect(SystemCleanupError.authorizationFailure(in: "Helper did not respond (launchd may be refusing to start it; try re-registering)") == nil)
        #expect(SystemCleanupError.authorizationFailure(in: "administrator authorization failed (not a number)") == nil)
    }
}
