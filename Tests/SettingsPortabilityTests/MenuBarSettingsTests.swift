import Foundation
import SettingsPortability
import Testing

@Suite struct MenuBarSettingsTests {
    private func makeDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "MenuBarSettingsTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func theItemIsShownWhenNothingWasStored() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(MenuBarPreference.isVisible(defaults))
    }

    @Test func theStoredChoiceSurvives() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        MenuBarPreference.write(visible: false, to: defaults)
        #expect(!MenuBarPreference.isVisible(defaults))

        MenuBarPreference.write(visible: true, to: defaults)
        #expect(MenuBarPreference.isVisible(defaults))
    }

    @Test func aNonBooleanValueDoesNotHideTheItem() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        // A newer version could store something else under the same key; the item stays reachable.
        defaults.set("hidden", forKey: MenuBarPreference.visibleKey)

        #expect(MenuBarPreference.isVisible(defaults))
    }

    @Test func aHiddenItemAlwaysKeepsTheDockIcon() {
        #expect(DockPolicy.effectiveMode(requested: .always, menuBarVisible: false) == .always)
        #expect(DockPolicy.effectiveMode(requested: .whileWindowOpen, menuBarVisible: false) == .always)
        #expect(DockPolicy.effectiveMode(requested: .never, menuBarVisible: false) == .always)
    }

    @Test func aShownItemKeepsTheRequestedDockMode() {
        #expect(DockPolicy.effectiveMode(requested: .always, menuBarVisible: true) == .always)
        #expect(DockPolicy.effectiveMode(requested: .whileWindowOpen, menuBarVisible: true) == .whileWindowOpen)
        #expect(DockPolicy.effectiveMode(requested: .never, menuBarVisible: true) == .never)
    }

    @Test func onlyTheAlwaysModeIsOfferedWhileTheItemIsHidden() {
        #expect(DockPolicy.allows(.always, menuBarVisible: false))
        #expect(!DockPolicy.allows(.whileWindowOpen, menuBarVisible: false))
        #expect(!DockPolicy.allows(.never, menuBarVisible: false))
        for mode in DockMode.allCases {
            #expect(DockPolicy.allows(mode, menuBarVisible: true))
        }
    }

    @Test func thePayloadCarriesTheMenuBarChoiceThroughACodableRoundTrip() throws {
        let payload = GeneralSettingsPayload(dockMode: .always, menuBarVisible: false,
                                             language: "zh-Hant")
        let decoded = try JSONDecoder().decode(GeneralSettingsPayload.self,
                                               from: JSONEncoder().encode(payload))

        #expect(decoded == payload)
        #expect(decoded.menuBarVisible == false)
    }

    @Test func aPayloadWithoutTheFieldDecodesAsShown() throws {
        // Backups written before the switch existed have no field; those versions always showed it.
        let decoded = try JSONDecoder().decode(
            GeneralSettingsPayload.self,
            from: Data(#"{"dockMode":"never","language":"ja"}"#.utf8))

        #expect(decoded.menuBarVisible)
        #expect(decoded.dockMode == .never)
    }

    @Test func theEncodingAlwaysWritesTheMenuBarChoice() throws {
        let data = try JSONEncoder().encode(GeneralSettingsPayload())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["menuBarVisible"] as? Bool == true)
    }

    @Test func aPayloadThatHidesTheItemResolvesTheDockModeToAlways() throws {
        // What an import of a hand-written or future file can contain: the item hidden while the
        // Dock mode asks for no Dock icon. Applying it would leave the app with no way in.
        let decoded = try JSONDecoder().decode(
            GeneralSettingsPayload.self,
            from: Data(#"{"dockMode":"never","menuBarVisible":false}"#.utf8))

        #expect(decoded.effectiveDockMode == .always)
        #expect(decoded.normalized().dockMode == .always)
        // The menu bar choice itself is kept, so the app still hides the item.
        #expect(decoded.normalized().menuBarVisible == false)
    }

    @Test func normalizingAShownItemLeavesTheDockModeAlone() {
        for mode in DockMode.allCases {
            let payload = GeneralSettingsPayload(dockMode: mode, menuBarVisible: true)
            #expect(payload.normalized().dockMode == mode)
        }
    }

    @Test func normalizingKeepsTheOtherFields() {
        var features = FeatureSet()
        features.setEnabled(.fans, false)
        let payload = GeneralSettingsPayload(dockMode: .never, menuBarVisible: false,
                                             language: "ko", features: features)
        let normalized = payload.normalized()

        #expect(normalized.language == "ko")
        #expect(normalized.features == payload.features)
    }
}
