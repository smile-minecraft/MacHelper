import Foundation
import Testing
import Tweaks

@Suite struct TweakCatalogTests {
    @Test func everyAdjustmentIsListedExactlyOnce() {
        let ids = Set(TweakCatalog.all.map(\.id))
        #expect(ids.count == 11)
        #expect(ids == Set(TweakID.allCases))
        #expect(TweakID.allCases.count == 11)
    }

    @Test func onlyFourAdjustmentsAreImplemented() {
        let implemented = Set(TweakCatalog.all.filter(\.implemented).map(\.id))
        #expect(implemented == [.dockClickAction, .musicBlockAutolaunch, .windowCmdTabRestore, .inputQuitGuard])
        for id in TweakID.allCases where !implemented.contains(id) {
            #expect(!TweakCatalog.isAvailable(id))
        }
    }

    @Test func everyCategoryHasAdjustmentsAndTitles() {
        for category in TweakCategory.allCases {
            #expect(!TweakCatalog.ids(in: category).isEmpty)
            #expect(!category.title.isEmpty)
        }
    }

    @Test func optionRangesAndEnumsAreValidatedAtTheBoundary() {
        let hold = TweakCatalog.definition(for: .inputQuitGuard).option("holdSeconds")!
        #expect(hold.isValid(.double(0.6)))
        #expect(hold.isValid(.double(0.2)))
        #expect(hold.isValid(.double(3.0)))
        #expect(!hold.isValid(.double(0.1)))
        #expect(!hold.isValid(.double(3.01)))
        #expect(!hold.isValid(.int(1)))
        #expect(hold.parse("0.8") == .double(0.8))
        #expect(hold.parse("nope") == nil)

        let mode = TweakCatalog.definition(for: .inputQuitGuard).option("mode")!
        #expect(mode.isValid(.string("doublePress")))
        #expect(!mode.isValid(.string("triplePress")))
        #expect(!mode.isValid(.bool(true)))

        let excluded = TweakCatalog.definition(for: .inputQuitGuard).option("excludedApps")!
        #expect(excluded.parse("com.apple.Terminal, com.apple.Safari") == .stringList(["com.apple.Terminal", "com.apple.Safari"]))
        #expect(!excluded.isValid(.string("com.apple.Terminal")))

        let action = TweakCatalog.definition(for: .dockClickAction).option("action")!
        #expect(action.parse("minimize") == .string("minimize"))
        #expect(action.parse("close") == nil)
    }
}

@Suite struct TweakSettingsTests {
    @Test func defaultsAreOffAndRoundTripKeepsOverrides() throws {
        let settings = TweakSettings()
        for id in TweakID.allCases { #expect(!settings.isEnabled(id)) }

        var changed = settings
        let enabled = changed.setEnabled(.inputQuitGuard, true)
        let hold = changed.setValue("holdSeconds", for: .inputQuitGuard, to: .double(1.25))
        let excluded = changed.setValue("excludedApps", for: .inputQuitGuard, to: .stringList(["com.apple.Terminal"]))
        #expect(enabled && hold && excluded)
        #expect(changed.double("holdSeconds", for: .inputQuitGuard) == 1.25)

        let data = try JSONEncoder().encode(changed)
        let decoded = try JSONDecoder().decode(TweakSettings.self, from: data)
        #expect(decoded == changed)
        #expect(decoded.stringList("excludedApps", for: .inputQuitGuard) == ["com.apple.Terminal"])
        #expect(decoded.string("mode", for: .inputQuitGuard) == "hold")
    }

    @Test func unknownIdsAndOptionsDoNotInvalidateTheFile() throws {
        let json = #"""
        {
          "input.quit-guard": {
            "enabled": true,
            "holdSeconds": 1.1,
            "typoOption": true,
            "mode": "triplePress",
            "guardCloseWindow": "yes"
          },
          "finder.not-real": { "enabled": true },
          "future.tweak": { "enabled": true },
          "broken": 42
        }
        """#
        let settings = try JSONDecoder().decode(TweakSettings.self, from: Data(json.utf8))
        #expect(settings.isEnabled(.inputQuitGuard))
        #expect(settings.double("holdSeconds", for: .inputQuitGuard) == 1.1)
        #expect(settings.string("mode", for: .inputQuitGuard) == "hold")
        #expect(!settings.bool("guardCloseWindow", for: .inputQuitGuard))
        #expect(!settings.isEnabled(.finderCutPaste))
    }

    @Test func unimplementedTweaksCannotBeEnabled() {
        var settings = TweakSettings()
        let finderSwitch = settings.setEnabled(.finderCutPaste, true)
        #expect(!finderSwitch)
        #expect(!settings.isEnabled(.finderCutPaste))
        let finderOption = settings.setValue("crossVolume", for: .finderCutPaste, to: .bool(true))
        #expect(finderOption)
        // Options for a coming-soon tweak can be prepared, but the switch itself stays off.
        #expect(settings.bool("crossVolume", for: .finderCutPaste))
        let dockSwitch = settings.setEnabled(.dockClickAction, true)
        #expect(dockSwitch)
        #expect(settings.isEnabled(.dockClickAction))
    }

    @Test func returningToDefaultsRemovesOverridesAndResetClearsOneOrAll() throws {
        var settings = TweakSettings()
        settings.setEnabled(.inputQuitGuard, true)
        settings.setValue("holdSeconds", for: .inputQuitGuard, to: .double(0.6))
        settings.setEnabled(.dockClickAction, true)
        let data = try JSONEncoder().encode(settings)
        let raw = try #require(String(data: data, encoding: .utf8))
        #expect(!raw.contains("holdSeconds"))
        #expect(raw.contains("input.quit-guard"))

        settings.setValue("holdSeconds", for: .inputQuitGuard, to: .double(1.0))
        settings.reset(.inputQuitGuard)
        #expect(!settings.isEnabled(.inputQuitGuard))
        #expect(settings.double("holdSeconds", for: .inputQuitGuard) == 0.6)
        #expect(settings.isEnabled(.dockClickAction))
        settings.reset()
        #expect(!settings.isEnabled(.dockClickAction))
    }

    @Test func invalidOptionValuesAreRejectedRatherThanClamped() {
        var settings = TweakSettings()
        let outOfRange = settings.setValue("holdSeconds", for: .inputQuitGuard, to: .double(99))
        #expect(!outOfRange)
        #expect(settings.double("holdSeconds", for: .inputQuitGuard) == 0.6)
        let badEnum = settings.setValue("action", for: .dockClickAction, to: .string("quit"))
        let badOption = settings.setValue("missing", for: .dockClickAction, to: .bool(true))
        #expect(!badEnum && !badOption)
    }
}
