import CoreGraphics
import Testing
@testable import Tweaks

/// The cheap decisions the event tap makes on its own thread before it asks the Dock anything.
@Suite struct EventRulesTests {
    private let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let side = CGRect(x: 1920, y: -200, width: 1080, height: 1920)

    @Test func onlyClicksNearABottomOrSideEdgeAreHitTested() {
        #expect(TweakRules.isNearDockEdge(CGPoint(x: 960, y: 1070), displays: [main]))   // bottom Dock
        #expect(TweakRules.isNearDockEdge(CGPoint(x: 10, y: 500), displays: [main]))     // left Dock
        #expect(TweakRules.isNearDockEdge(CGPoint(x: 1910, y: 500), displays: [main]))   // right Dock
        #expect(!TweakRules.isNearDockEdge(CGPoint(x: 960, y: 500), displays: [main]))   // middle of the screen
        #expect(!TweakRules.isNearDockEdge(CGPoint(x: 960, y: 10), displays: [main]))    // menu bar, never the Dock
        #expect(TweakRules.isNearDockEdge(CGPoint(x: 2400, y: 1700), displays: [main, side]))  // second display's bottom
        #expect(!TweakRules.isNearDockEdge(CGPoint(x: 2400, y: 700), displays: [main, side]))
        #expect(!TweakRules.isNearDockEdge(CGPoint(x: 960, y: 1070), displays: []))
    }

    @Test func aSwallowedDownAlsoSwallowsItsUpAndNothingElse() {
        var pairing = MouseClickPairing()
        var results: [Bool] = []
        results.append(pairing.mouseUp())                 // stray up: passes
        results.append(pairing.mouseDown(matched: true))
        results.append(pairing.mouseUp())                 // the Dock never sees the release
        results.append(pairing.mouseUp())                 // only that one
        results.append(pairing.mouseDown(matched: false))
        results.append(pairing.mouseUp())                 // an ordinary click keeps its release
        #expect(results == [false, true, true, false, false, false])
    }

    @Test func hintNamesTheShortcutThatWasHeldBack() {
        #expect(TweakRules.guardHint(keyCode: TweakRules.keyQ, doublePress: false) == .holdToQuit)
        #expect(TweakRules.guardHint(keyCode: TweakRules.keyW, doublePress: false) == .holdToClose)
        #expect(TweakRules.guardHint(keyCode: TweakRules.keyQ, doublePress: true) == .pressTwiceToQuit)
        #expect(TweakRules.guardHint(keyCode: TweakRules.keyW, doublePress: true) == .pressTwiceToClose)
    }

    @Test func dialogStyleAppWindowsCountAsUserWindows() {
        #expect(TweakRules.isUserWindow(subrole: "AXStandardWindow"))
        #expect(TweakRules.isUserWindow(subrole: "AXDialog"))
        #expect(!TweakRules.isUserWindow(subrole: "AXFloatingWindow"))
        #expect(!TweakRules.isUserWindow(subrole: "AXSystemDialog"))
        #expect(!TweakRules.isUserWindow(subrole: nil))
    }
}
