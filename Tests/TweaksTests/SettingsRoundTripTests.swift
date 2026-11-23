import CoreGraphics
import Foundation
import Testing
@testable import Tweaks

/// tweaks.json is written by one process and read by another; what goes in must come back out.
@Suite struct SettingsRoundTripTests {
    private func roundTrip(_ settings: TweakSettings) throws -> TweakSettings {
        try JSONDecoder().decode(TweakSettings.self, from: JSONEncoder().encode(settings))
    }

    @Test func wholeNumberSecondsSurviveTheFile() throws {
        for seconds in [1.0, 2.0, 3.0, 0.8] {
            var settings = TweakSettings()
            let stored = settings.setValue("holdSeconds", for: .inputQuitGuard, to: .double(seconds))
            #expect(stored)
            #expect(try roundTrip(settings).double("holdSeconds", for: .inputQuitGuard) == seconds)
        }
        // The CLI may also hand over an int for a double option.
        var settings = TweakSettings()
        let storedInt = settings.setValue("holdSeconds", for: .inputQuitGuard, to: .int(2))
        #expect(storedInt)
        #expect(settings.double("holdSeconds", for: .inputQuitGuard) == 2)
    }

    @Test func oneUnreadableValueDropsOnlyThatValue() throws {
        let json = #"""
        {"input.quit-guard": {"enabled": true, "futureObject": {"a": 1}, "futureNull": null,
                              "mixed": [1, "a"], "holdSeconds": 1.5, "guardCloseWindow": "yes"}}
        """#
        let settings = try JSONDecoder().decode(TweakSettings.self, from: Data(json.utf8))
        #expect(settings.isEnabled(.inputQuitGuard))
        #expect(settings.double("holdSeconds", for: .inputQuitGuard) == 1.5)
        #expect(!settings.bool("guardCloseWindow", for: .inputQuitGuard))   // wrong type → default
    }

    @Test func aTweakNotInThisBuildIsNeverOnFromTheFile() throws {
        let json = #"{"mission-control.window-buttons": {"enabled": true}, "music.block-autolaunch": {"enabled": true}}"#
        let settings = try JSONDecoder().decode(TweakSettings.self, from: Data(json.utf8))
        #expect(!settings.isEnabled(.missionControlWindowButtons))
        #expect(settings.isEnabled(.musicBlockAutolaunch))
    }

    @Test func modifierBitsMatchCoreGraphics() {
        #expect(TweakRules.controlFlag == CGEventFlags.maskControl.rawValue)
        #expect(TweakRules.alternateFlag == CGEventFlags.maskAlternate.rawValue)
        #expect(TweakRules.shiftFlag == CGEventFlags.maskShift.rawValue)
        #expect(TweakRules.commandFlag == CGEventFlags.maskCommand.rawValue)
    }
}
