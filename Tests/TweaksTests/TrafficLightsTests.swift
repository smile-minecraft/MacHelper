import CoreGraphics
import Testing
@testable import Tweaks

/// The table behind the traffic light tweak: which click is taken over, and what it does.
@Suite struct TrafficLightRuleTests {
    private let window = CGRect(x: 100, y: 200, width: 800, height: 600)
    private let defaults = TrafficLightOptions()

    @Test func subrolesMapToTheThreeButtonsAndZoom() {
        #expect(TrafficLightRules.button(forSubrole: "AXCloseButton") == .close)
        #expect(TrafficLightRules.button(forSubrole: "AXMinimizeButton") == .minimize)
        #expect(TrafficLightRules.button(forSubrole: "AXFullScreenButton") == .fullScreen)
        #expect(TrafficLightRules.button(forSubrole: "AXZoomButton") == .zoom)
        #expect(TrafficLightRules.button(forSubrole: "AXToolbarButton") == nil)
        #expect(TrafficLightRules.button(forSubrole: nil) == nil)
    }

    @Test func theDefaultsLeaveEveryClickToMacOS() {
        for button in TrafficLightButton.allCases {
            let action = TrafficLightRules.action(button: button, flags: 0, bundleID: "com.apple.Safari",
                                                  options: defaults, ownBundleID: "com.machelper.MacHelper")
            #expect(action == .system)
        }
    }

    @Test func closeCanQuitAndMinimizeCanHideAndTheGreenButtonCanFillOrZoom() {
        var quit = defaults
        quit.closeAction = "quit"
        #expect(TrafficLightRules.action(button: .close, flags: 0, bundleID: "com.apple.Safari",
                                         options: quit, ownBundleID: "x") == .closeWindow(quitIfLast: true))
        #expect(TrafficLightRules.action(button: .minimize, flags: 0, bundleID: "com.apple.Safari",
                                         options: quit, ownBundleID: "x") == .system)

        var hide = defaults
        hide.minimizeAction = "hide"
        #expect(TrafficLightRules.action(button: .minimize, flags: 0, bundleID: "com.apple.Safari",
                                         options: hide, ownBundleID: "x") == .hideApp)

        var fill = defaults
        fill.zoomAction = "fill"
        #expect(TrafficLightRules.action(button: .fullScreen, flags: 0, bundleID: "com.apple.Safari",
                                         options: fill, ownBundleID: "x") == .fillScreen)
        #expect(TrafficLightRules.action(button: .zoom, flags: 0, bundleID: "com.apple.Safari",
                                         options: fill, ownBundleID: "x") == .fillScreen)

        var zoom = defaults
        zoom.zoomAction = "zoom"
        #expect(TrafficLightRules.action(button: .fullScreen, flags: 0, bundleID: "com.apple.Safari",
                                         options: zoom, ownBundleID: "x") == .zoom)
    }

    @Test func everyModifierKeepsTheSystemBehaviour() {
        var quit = defaults
        quit.closeAction = "quit"
        for flag in [TweakRules.commandFlag, TweakRules.shiftFlag, TweakRules.alternateFlag, TweakRules.controlFlag] {
            let action = TrafficLightRules.action(button: .close, flags: flag, bundleID: "com.apple.Safari",
                                                  options: quit, ownBundleID: "x")
            #expect(action == .system)
        }
        let optionClick = TrafficLightRules.action(button: .fullScreen, flags: TweakRules.alternateFlag,
                                                   bundleID: "com.apple.Safari", options: defaults, ownBundleID: "x")
        #expect(optionClick == .system)
    }

    @Test func excludedAppsAndMacHelperItselfKeepTheSystemBehaviour() {
        var quit = defaults
        quit.closeAction = "quit"
        quit.excludedApps = ["com.apple.Safari", "COM.APPLE.FINDER"]
        #expect(TrafficLightRules.action(button: .close, flags: 0, bundleID: "com.apple.safari",
                                         options: quit, ownBundleID: "x") == .system)
        #expect(TrafficLightRules.action(button: .close, flags: 0, bundleID: "com.apple.Finder",
                                         options: quit, ownBundleID: "x") == .system)
        // MacHelper never intercepts its own windows, whatever the list says.
        #expect(TrafficLightRules.action(button: .close, flags: 0, bundleID: "com.machelper.MacHelper",
                                         options: quit, ownBundleID: "com.machelper.MacHelper") == .system)
        // An unknown bundle id is not excluded.
        #expect(TrafficLightRules.action(button: .close, flags: 0, bundleID: nil,
                                         options: quit, ownBundleID: "x") == .closeWindow(quitIfLast: true))
    }

    @Test func quitOnlyHappensForTheAppsLastWindow() {
        #expect(TrafficLightRules.shouldQuitApp(quitIfLast: true, userWindowCount: 1, serverWindowCount: 1))
        #expect(!TrafficLightRules.shouldQuitApp(quitIfLast: true, userWindowCount: 2, serverWindowCount: 2))
        #expect(!TrafficLightRules.shouldQuitApp(quitIfLast: false, userWindowCount: 1, serverWindowCount: 1))
        // An app that did not answer is not an app without windows.
        #expect(!TrafficLightRules.shouldQuitApp(quitIfLast: true, userWindowCount: 0, serverWindowCount: 0))
        // Another window on a different desktop: Accessibility misses it, the window server does not.
        #expect(!TrafficLightRules.shouldQuitApp(quitIfLast: true, userWindowCount: 1, serverWindowCount: 2))
    }

    /// Measured on macOS 27: System Settings draws its 16 pt buttons 18–34 pt below the window's
    /// top. The old 30 pt strip passed the bottom of every button through untouched.
    @Test func theStripCoversButtonsCentredInAToolbar() {
        let window = CGRect(x: 0, y: 30, width: 754, height: 1410)
        for dy in stride(from: 18.0, through: 34.0, by: 2) {
            #expect(TrafficLightRules.isTitleBarClick(CGPoint(x: 26, y: 30 + dy), windowFrame: window))
        }
        // A taller unified toolbar centres the buttons lower still.
        #expect(TrafficLightRules.isTitleBarClick(CGPoint(x: 26, y: 30 + 50), windowFrame: window))
        #expect(!TrafficLightRules.isTitleBarClick(CGPoint(x: 26, y: 30 + 80), windowFrame: window))
    }

    @Test func onlyClicksInTheTitleBarStripReachTheHitTest() {
        #expect(TrafficLightRules.isTitleBarClick(CGPoint(x: 120, y: 215), windowFrame: window))
        #expect(TrafficLightRules.isTitleBarClick(CGPoint(x: 100, y: 200), windowFrame: window))
        #expect(!TrafficLightRules.isTitleBarClick(CGPoint(x: 120, y: 260), windowFrame: window))   // content
        #expect(!TrafficLightRules.isTitleBarClick(CGPoint(x: 500, y: 215), windowFrame: window))   // too far right
        #expect(!TrafficLightRules.isTitleBarClick(CGPoint(x: 90, y: 215), windowFrame: window))    // left of the window
        #expect(!TrafficLightRules.isTitleBarClick(CGPoint(x: 120, y: 195), windowFrame: window))   // above the window
        #expect(!TrafficLightRules.isTitleBarClick(CGPoint(x: 100, y: 200), windowFrame: .zero))
    }

    @Test func settingsBecomeTheOptionsTheTapReads() {
        var settings = TweakSettings()
        settings.setValue("closeAction", for: .windowTrafficLights, to: .string("quit"))
        settings.setValue("zoomAction", for: .windowTrafficLights, to: .string("fill"))
        settings.setValue("excludedApps", for: .windowTrafficLights, to: .stringList(["com.apple.Terminal"]))
        let options = TrafficLightOptions(settings: settings)
        #expect(options.closeAction == "quit")
        #expect(options.minimizeAction == "minimize")
        #expect(options.zoomAction == "fill")
        #expect(options.excludedApps == ["com.apple.Terminal"])
    }
}
