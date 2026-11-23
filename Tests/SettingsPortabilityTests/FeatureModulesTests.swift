import Foundation
import SettingsPortability
import Testing

@Suite struct FeatureModulesTests {
    @Test func defaultsAreEnabledForEveryModule() {
        let features = FeatureSet()
        for module in FeatureModule.allCases {
            #expect(features.isEnabled(module))
            #expect(module.defaultEnabled)
        }
    }

    @Test func overridesWinAndReturningToTheDefaultClearsTheOverride() {
        var features = FeatureSet()
        features.setEnabled(.fans, false)
        #expect(!features.isEnabled(.fans))
        #expect(features.isEnabled(.monitor))

        features.setEnabled(.fans, true)
        #expect(features == FeatureSet())
    }

    @Test func decodingIgnoresUnknownKeysAndValuesOfTheWrongType() throws {
        let json = #"{"monitor":false,"futureModule":true,"health":"yes","fans":42}"#
        let features = try #require(try JSONDecoder().decode(FeatureSet.self, from: Data(json.utf8)))

        #expect(!features.isEnabled(.monitor))
        #expect(features.isEnabled(.health))
        #expect(features.isEnabled(.fans))

        // The one valid override survives; the malformed entries leave no trace.
        var cleared = features
        cleared.setEnabled(.monitor, true)
        #expect(cleared == FeatureSet())
    }

    @Test func visibilityCoversEveryEnabledAndModeCombination() {
        for module in FeatureModule.allCases {
            #expect(module.isVisible(enabled: true, simpleMode: false))
            #expect(module.isVisible(enabled: false, simpleMode: false) == false)
            if module.hiddenInSimpleMode {
                #expect(module.isVisible(enabled: true, simpleMode: true) == false)
            } else {
                #expect(module.isVisible(enabled: true, simpleMode: true))
            }
            #expect(module.isVisible(enabled: false, simpleMode: true) == false)
        }
    }

    @Test func simpleModeHidesOnlyMonitoringFansAndStartup() {
        #expect(Set(FeatureModule.allCases.filter(\.hiddenInSimpleMode)) == [.monitor, .fans, .startup])
    }

    @Test func tweaksModuleKeepsOldBackupsReadable() throws {
        #expect(FeatureModule.allCases.contains(.tweaks))
        #expect(FeatureModule.tweaks.isVisible(enabled: true, simpleMode: false))
        #expect(!FeatureModule.tweaks.hiddenInSimpleMode)

        let backupWithoutTweaks = try #require(try JSONDecoder().decode(
            GeneralSettingsPayload.self,
            from: Data(#"{"dockMode":"never","features":{"monitor":false}}"#.utf8)))
        #expect(backupWithoutTweaks.features?.isEnabled(.tweaks) == true)
        #expect(backupWithoutTweaks.features?.isEnabled(.monitor) == false)

        var features = FeatureSet()
        features.setEnabled(.tweaks, false)
        let roundTrip = try JSONDecoder().decode(FeatureSet.self,
                                                 from: try JSONEncoder().encode(features))
        #expect(!roundTrip.isEnabled(.tweaks))
    }

    @Test func oldPayloadWithoutFeaturesStillDecodes() throws {
        let legacy = try JSONDecoder().decode(
            GeneralSettingsPayload.self,
            from: Data(#"{"showInDock":true,"language":"zh-Hant"}"#.utf8))
        #expect(legacy.dockMode == .whileWindowOpen)
        #expect(legacy.features == nil)

        let current = try JSONDecoder().decode(
            GeneralSettingsPayload.self,
            from: Data(#"{"dockMode":"never"}"#.utf8))
        #expect(current.dockMode == .never)
        #expect(current.features == nil)
    }

    @Test func payloadWithFeaturesSurvivesARoundTrip() throws {
        var features = FeatureSet()
        features.setEnabled(.optimize, false)
        features.setEnabled(.startup, false)
        let payload = GeneralSettingsPayload(dockMode: .always, language: "ja", features: features)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(GeneralSettingsPayload.self, from: data)

        #expect(decoded == payload)
        #expect(decoded.features?.isEnabled(.optimize) == false)
        #expect(decoded.features?.isEnabled(.startup) == false)
        #expect(decoded.features?.isEnabled(.disk) == true)
    }
}
