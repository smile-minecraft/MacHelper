import Foundation
import SettingsPortability
import Testing

@Suite struct DockSettingsTests {
    private func makeDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "DockSettingsTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func legacyTrueMigratesToWhileWindowOpen() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "showInDock")

        #expect(DockPreference.migrate(defaults) == .whileWindowOpen)
        #expect(defaults.string(forKey: "dockMode") == DockMode.whileWindowOpen.rawValue)
        #expect(defaults.object(forKey: "showInDock") == nil)
    }

    @Test func legacyFalseMigratesToNever() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "showInDock")

        #expect(DockPreference.migrate(defaults) == .never)
        #expect(defaults.string(forKey: "dockMode") == DockMode.never.rawValue)
        #expect(defaults.object(forKey: "showInDock") == nil)
    }

    @Test func existingModeWinsOverTheLegacyKey() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "showInDock")
        defaults.set(DockMode.never.rawValue, forKey: "dockMode")

        #expect(DockPreference.migrate(defaults) == .never)
        #expect(defaults.string(forKey: "dockMode") == DockMode.never.rawValue)
    }

    @Test func migrationRunsOnlyOnce() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "showInDock")

        #expect(DockPreference.migrate(defaults) == .never)
        // A stale legacy key must not override the mode written by the first migration.
        defaults.set(true, forKey: "showInDock")
        #expect(DockPreference.migrate(defaults) == .never)
    }

    @Test func unknownStoredModeFallsBackWithoutOverwritingIt() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("futureMode", forKey: "dockMode")

        #expect(DockPreference.migrate(defaults) == .whileWindowOpen)
        #expect(defaults.string(forKey: "dockMode") == "futureMode")
    }

    @Test func dockIconPolicyFollowsTheModeAndOpenWindows() {
        #expect(DockMode.always.showsDockIcon(hasOpenWindows: false))
        #expect(DockMode.always.showsDockIcon(hasOpenWindows: true))
        #expect(DockMode.whileWindowOpen.showsDockIcon(hasOpenWindows: true))
        #expect(!DockMode.whileWindowOpen.showsDockIcon(hasOpenWindows: false))
        #expect(!DockMode.never.showsDockIcon(hasOpenWindows: true))
        #expect(!DockMode.never.showsDockIcon(hasOpenWindows: false))
    }

    @Test func payloadDecodesTheLegacyBoolean() throws {
        let truePayload = try? JSONDecoder().decode(
            GeneralSettingsPayload.self,
            from: Data(#"{"showInDock":true,"language":"zh-Hant"}"#.utf8))
        #expect(truePayload?.dockMode == .whileWindowOpen)
        #expect(truePayload?.language == "zh-Hant")

        let falsePayload = try? JSONDecoder().decode(
            GeneralSettingsPayload.self,
            from: Data(#"{"showInDock":false}"#.utf8))
        #expect(falsePayload?.dockMode == .never)
    }

    @Test func payloadDecodesTheNewMode() {
        let payload = try? JSONDecoder().decode(
            GeneralSettingsPayload.self,
            from: Data(#"{"dockMode":"always"}"#.utf8))
        #expect(payload?.dockMode == .always)
    }

    @Test func payloadDefaultsToWhileWindowOpenWhenDockSettingsAreMissing() {
        let payload = try? JSONDecoder().decode(GeneralSettingsPayload.self, from: Data("{}".utf8))
        #expect(payload?.dockMode == .whileWindowOpen)
    }

    @Test func payloadEncodesOnlyTheNewMode() throws {
        let data = try JSONEncoder().encode(GeneralSettingsPayload(dockMode: .always, language: "ja"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["dockMode"] as? String == DockMode.always.rawValue)
        #expect(object["showInDock"] == nil)
        #expect(object["language"] as? String == "ja")
    }
}
