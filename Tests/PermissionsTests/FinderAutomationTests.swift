import Foundation
import Testing
@testable import Permissions

/// The Finder automation request behind the explanation's Continue button: how macOS's answer is
/// read, what happens next, and the signing setting without which macOS never asks at all.
@Suite struct FinderAutomationTests {
    @Test func appleEventAnswersMapToTheFourStates() {
        #expect(FinderAutomationStatus(appleEventStatus: 0) == .granted)
        #expect(FinderAutomationStatus(appleEventStatus: -1743) == .denied)
        #expect(FinderAutomationStatus(appleEventStatus: -1744) == .undetermined)
        // procNotFound: Finder is not running, so macOS has nothing to ask about.
        #expect(FinderAutomationStatus(appleEventStatus: -600) == .unavailable)
        #expect(FinderAutomationStatus(appleEventStatus: -1712) == .unavailable)  // errAETimeout
    }

    @Test func continueNeverEndsInSilence() {
        func next(_ asked: FinderAutomationStatus, before: FinderAutomationStatus = .undetermined,
                  recorded: FinderAutomationStatus, launch: Bool = true) -> FinderAutomationFollowUp {
            FinderAutomationFollowUp.after(asked: asked, before: before, recorded: recorded, canLaunchFinder: launch)
        }
        #expect(next(.granted, recorded: .granted) == .done)
        // The person chose Don't Allow in the alert just shown: respected, no Settings window.
        #expect(next(.denied, recorded: .denied) == .done)
        // Refused before: macOS never asks twice, the switch lives in System Settings.
        #expect(next(.denied, before: .denied, recorded: .denied) == .openSettings)
        // Refused at once and nothing recorded: macOS never showed its alert (the build without the
        // Apple Events entitlement behaved exactly like this, and Continue looked dead).
        #expect(next(.denied, recorded: .undetermined) == .promptNotShown)
        // Asked with the prompt allowed and still undecided: macOS declined to show the alert.
        #expect(next(.undetermined, recorded: .undetermined) == .promptNotShown)
        // Finder not running: start it and ask again, once.
        #expect(next(.unavailable, before: .unavailable, recorded: .unavailable) == .launchFinderAndRetry)
        #expect(next(.unavailable, before: .unavailable, recorded: .unavailable, launch: false) == .promptNotShown)
        let all: [FinderAutomationStatus] = [.granted, .denied, .undetermined, .unavailable]
        for asked in all {
            for before in all {
                for recorded in all {
                    #expect(next(asked, before: before, recorded: recorded, launch: false) != .launchFinderAndRetry)
                }
            }
        }
    }

    /// Under the Hardened Runtime macOS only shows the Automation consent alert to an app signed
    /// with `com.apple.security.automation.apple-events`; without it the request returns at once and
    /// Continue appears to do nothing.
    @Test func theAppIsSignedWithTheAppleEventsEntitlement() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()   // Tests/PermissionsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let project = try String(contentsOf: root.appending(path: "project.yml"), encoding: .utf8)
        #expect(project.contains("ENABLE_HARDENED_RUNTIME: YES"))
        // The setting must sit in the app target, between its `MacHelper:` header and the next target.
        let app = try #require(project.range(of: "\n  MacHelper:\n"))
        let next = try #require(project.range(of: "\n  MacHelperHelper:\n"))
        let appTarget = project[app.upperBound..<next.lowerBound]
        #expect(appTarget.contains("CODE_SIGN_ENTITLEMENTS: App/MacHelper.entitlements"))
        #expect(appTarget.contains("NSAppleEventsUsageDescription"))

        let data = try Data(contentsOf: root.appending(path: "App/MacHelper.entitlements"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["com.apple.security.automation.apple-events"] as? Bool == true)
    }
}
