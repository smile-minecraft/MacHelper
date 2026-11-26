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

    @Test func onlyTheShippedAdjustmentsAreImplemented() {
        let implemented = Set(TweakCatalog.all.filter(\.implemented).map(\.id))
        #expect(implemented == [.finderCutPaste, .finderNewFile, .finderContextMenu, .dockClickAction,
                                .musicBlockAutolaunch, .windowCmdTabRestore, .inputQuitGuard,
                                .windowTrafficLights, .windowSwitcherMenu, .missionControlWindowButtons])
        for id in TweakID.allCases where !implemented.contains(id) {
            #expect(!TweakCatalog.isAvailable(id))
        }
    }

    @Test func theFinderColumnTweakSaysWhyItIsNotShipped() throws {
        let definition = TweakCatalog.definition(for: .finderColumnAutosize)
        #expect(!definition.implemented)
        let reason = try #require(definition.unavailableReason)
        #expect(reason.contains("Accessibility"))
        // Every other unavailable tweak is simply not written yet.
        for definition in TweakCatalog.all where !definition.implemented && definition.id != .finderColumnAutosize {
            #expect(definition.unavailableReason == nil)
        }
    }

    @Test func theFinderTweaksCarryTheOptionsTheBehavioursRead() {
        let newFile = TweakCatalog.definition(for: .finderNewFile)
        #expect(newFile.permissions == [.accessibility, .automationFinder])
        #expect(newFile.option("shortcut")?.parse("ctrl+option+n") == .string("ctrl+option+n"))
        #expect(newFile.option("template")?.isValid(.string("markdown")) == true)
        #expect(newFile.option("template")?.isValid(.string("docx")) == false)
        #expect(newFile.option("baseName")?.parse("Notes") == .string("Notes"))

        let contextMenu = TweakCatalog.definition(for: .finderContextMenu)
        #expect(contextMenu.permissions == [.finderExtension])
        #expect(contextMenu.option("terminalBundleID")?.parse("com.googlecode.iterm2") == .string("com.googlecode.iterm2"))

        // Cut and paste needs the event tap only: no Apple Events, no extension.
        #expect(TweakCatalog.definition(for: .finderCutPaste).permissions == [.accessibility])
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

        let trafficLights = TweakCatalog.definition(for: .windowTrafficLights)
        #expect(trafficLights.option("closeAction")!.parse("quit") == .string("quit"))
        #expect(trafficLights.option("closeAction")!.parse("minimize") == nil)
        #expect(trafficLights.option("minimizeAction")!.parse("hide") == .string("hide"))
        #expect(trafficLights.option("zoomAction")!.parse("fill") == .string("fill"))
        #expect(trafficLights.option("zoomAction")!.parse("fullscreen") == nil)
        #expect(trafficLights.option("excludedApps")!.parse("com.apple.Safari,com.apple.dt.Xcode")
            == .stringList(["com.apple.Safari", "com.apple.dt.Xcode"]))

        let switcher = TweakCatalog.definition(for: .windowSwitcherMenu)
        #expect(switcher.option("hotkey")!.parse("ctrl+opt+w") == .string("ctrl+opt+w"))

        let missionControl = TweakCatalog.definition(for: .missionControlWindowButtons)
        #expect(missionControl.option("buttons")!.parse("close,minimize") == .stringList(["close", "minimize"]))
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
        // Column autosizing is the one tweak this build cannot offer.
        let columnAutosize = settings.setEnabled(.finderColumnAutosize, true)
        #expect(!columnAutosize)
        #expect(!settings.isEnabled(.finderColumnAutosize))
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

/// The app-list text field on the Tweaks page and the CLI read lists the same way.
@Suite struct TweakListTextTests {
    @Test func aListSurvivesTheRoundTripThroughText() {
        let list = ["com.apple.Terminal", "com.apple.Safari"]
        #expect(TweakListText.parse(TweakListText.format(list)) == list)
    }

    /// The field used to save on every keystroke and show the parsed list back, so the comma that
    /// starts a second id vanished as soon as it was typed. The field now saves when editing ends;
    /// a trailing separator or blank entry is simply dropped at that point.
    @Test func separatorsBlanksAndRepeatsAreDropped() {
        #expect(TweakListText.parse("com.apple.Terminal,") == ["com.apple.Terminal"])
        #expect(TweakListText.parse(" com.apple.Terminal ,, com.apple.Safari\ncom.apple.Notes ")
                == ["com.apple.Terminal", "com.apple.Safari", "com.apple.Notes"])
        #expect(TweakListText.parse("com.apple.Safari, com.apple.safari") == ["com.apple.Safari"])
        #expect(TweakListText.parse("") == [])
        #expect(TweakListText.parse(" , ") == [])
    }

    @Test func theCLIParsesListsWithTheSameRule() throws {
        let excluded = try #require(TweakCatalog.definition(for: .inputQuitGuard).option("excludedApps"))
        #expect(excluded.parse("com.apple.Terminal, com.apple.terminal, ,com.apple.Safari")
                == .stringList(["com.apple.Terminal", "com.apple.Safari"]))
    }
}
