import Foundation
import Testing
@testable import Telemetry

@Suite struct TelemetryPreferencesTests {
    @Test func defaultIsOptOutAndCreatesNoIdentity() {
        let name = makePreferenceSuite()
        defer { removePreferenceSuite(name) }
        let preferences = TelemetryPreferences(suiteName: name, infoDictionary: [:])

        #expect(!preferences.isEnabled)
        #expect(preferences.installID == nil)
        #expect(UserDefaults(suiteName: name)?.object(forKey: TelemetryPreferences.installIDKey) == nil)
    }

    @Test func disablingErasesTheIdentifierImmediately() throws {
        let name = makePreferenceSuite()
        defer { removePreferenceSuite(name) }
        let preferences = TelemetryPreferences(suiteName: name, infoDictionary: [:])

        preferences.setEnabled(true)
        let first = try #require(preferences.installID)
        #expect(first == preferences.installID, "the same ID is reused within one opt-in session")

        let rotated = try #require(preferences.rotateInstallID())
        #expect(rotated != first)

        preferences.setEnabled(false)
        #expect(!preferences.isEnabled)
        #expect(preferences.installID == nil)
        #expect(UserDefaults(suiteName: name)?.object(forKey: TelemetryPreferences.installIDKey) == nil)
        #expect(preferences.rotateInstallID() == nil, "rotation is a no-op while opted out")
    }

    @Test func endpointIsNilUntilConfigured() throws {
        let name = makePreferenceSuite()
        defer { removePreferenceSuite(name) }

        let emptyPlist = TelemetryPreferences(suiteName: name,
                                              infoDictionary: [TelemetryPreferences.endpointInfoPlistKey: ""])
        #expect(emptyPlist.configuredEndpoint == nil)

        let fromPlist = TelemetryPreferences(
            suiteName: name,
            infoDictionary: [TelemetryPreferences.endpointInfoPlistKey: "https://telemetry.example.com/v1"])
        #expect(fromPlist.configuredEndpoint?.absoluteString == "https://telemetry.example.com/v1")

        let override = try #require(URL(string: "https://override.example.com/v2"))
        fromPlist.setEndpointOverride(override)
        #expect(fromPlist.endpointOverride == override)
        #expect(fromPlist.configuredEndpoint == override, "the override wins over the build value")
        fromPlist.setEndpointOverride(nil)
        #expect(fromPlist.endpointOverride == nil)
    }

    @Test func diagnosticLaunchesAreExcluded() {
        #expect(TelemetryRuntime.isNonProduction(arguments: ["MacHelper", "--measure-pages", "/tmp/x"]))
        #expect(TelemetryRuntime.isNonProduction(arguments: ["MacHelper", "--selftest"]))
        #expect(TelemetryRuntime.isNonProduction(arguments: ["MacHelper", "--snapshot-settings"]))
        #expect(TelemetryRuntime.isNonProduction(arguments: ["MacHelper", "--snapshot-window", "/tmp/x"]))
        #expect(!TelemetryRuntime.isNonProduction(arguments: ["MacHelper"]))
        #expect(!TelemetryRuntime.isNonProduction(arguments: ["MacHelper", "--demo-battery"]))
    }
}
