import CoreGraphics
import Foundation
import Testing
@testable import Tweaks

@Suite struct MissionControlThumbnailTests {
    @Test func theIdentifierNamesTheOwningApp() {
        let finder = MissionControlThumbnail(identifier: "com.apple.finder.space.1", title: "MainData",
                                             frame: CGRect(x: 0, y: 0, width: 533, height: 376))
        #expect(finder.bundleID == "com.apple.finder")
        #expect(abs(finder.aspectRatio - 533.0 / 376.0) < 0.0001)

        let zen = MissionControlThumbnail(identifier: "app.zen-browser.zen.space.2", title: "X",
                                          frame: .zero)
        #expect(zen.bundleID == "app.zen-browser.zen")
        #expect(zen.aspectRatio == 0)

        let unknown = MissionControlThumbnail(identifier: "no-space-suffix", title: "", frame: .zero)
        #expect(unknown.bundleID == nil)
        #expect(MissionControlThumbnail(identifier: ".space.1", title: "", frame: .zero).bundleID == nil)
    }
}

@Suite struct MissionControlMatchingTests {
    private func window(_ index: Int, title: String, width: Double, height: Double,
                        bundleID: String? = "com.apple.TextEdit") -> WindowSnapshot {
        WindowSnapshot(id: WindowIdentity(pid: 77, window: UInt32(index + 1)), app: "TextEdit", bundleID: bundleID,
                       title: title, minimized: false, visible: true,
                       frame: WindowFrame(CGRect(x: 0, y: 0, width: width, height: height)))
    }

    @Test func aUniqueTitleIsEnough() {
        let windows = [window(0, title: "notes.txt", width: 600, height: 400),
                       window(1, title: "other.txt", width: 300, height: 300)]
        let match = MissionControlModel.match(bundleID: "com.apple.TextEdit", title: "notes.txt",
                                              aspectRatio: 1.5, windows: windows)
        #expect(match == WindowIdentity(pid: 77, window: 1))
    }

    @Test func nothingIsActedOnWithoutAnAppOrATitle() {
        let windows = [window(0, title: "notes.txt", width: 600, height: 400)]
        #expect(MissionControlModel.match(bundleID: nil, title: "notes.txt", aspectRatio: 1.5, windows: windows) == nil)
        #expect(MissionControlModel.match(bundleID: "com.apple.TextEdit", title: "", aspectRatio: 1.5, windows: windows) == nil)
        #expect(MissionControlModel.match(bundleID: "com.apple.Safari", title: "notes.txt", aspectRatio: 1.5, windows: windows) == nil)
        #expect(MissionControlModel.match(bundleID: "COM.APPLE.TEXTEDIT", title: "notes.txt",
                                          aspectRatio: 1.5, windows: windows) == WindowIdentity(pid: 77, window: 1))
    }

    @Test func windowsWithTheSameTitleAreToldApartByShape() {
        // Two "Untitled" windows: one landscape, one portrait.
        let windows = [window(0, title: "Untitled", width: 800, height: 500),   // 1.6
                       window(1, title: "Untitled", width: 400, height: 700)]   // 0.57
        #expect(MissionControlModel.match(bundleID: "com.apple.TextEdit", title: "Untitled",
                                          aspectRatio: 1.6, windows: windows) == WindowIdentity(pid: 77, window: 1))
        #expect(MissionControlModel.match(bundleID: "com.apple.TextEdit", title: "Untitled",
                                          aspectRatio: 0.57, windows: windows) == WindowIdentity(pid: 77, window: 2))
    }

    @Test func anAmbiguousShapeMatchIsSkippedRatherThanGuessed() {
        let windows = [window(0, title: "Document", width: 600, height: 400),
                       window(1, title: "Document", width: 600, height: 400)]
        #expect(MissionControlModel.match(bundleID: "com.apple.TextEdit", title: "Document",
                                          aspectRatio: 1.5, windows: windows) == nil)
        // A thumbnail that matches neither window's shape is not assumed to be one of them either.
        #expect(MissionControlModel.match(bundleID: "com.apple.TextEdit", title: "Document",
                                          aspectRatio: 0.4, windows: windows) == nil)
    }
}

@Suite struct HotKeyShortcutTests {
    @Test func shortcutsParseFromTheWayPeopleWriteThem() {
        let plain = HotKeyShortcut.parse("ctrl+opt+w")
        #expect(plain?.keyCode == 13)
        #expect(plain?.carbonModifiers == HotKeyShortcut.controlMask | HotKeyShortcut.optionMask)
        #expect(plain?.description == "ctrl+opt+w")

        let symbols = HotKeyShortcut.parse("⌃⌥⌘W")
        #expect(symbols?.keyCode == 13)
        #expect(symbols?.carbonModifiers == HotKeyShortcut.controlMask | HotKeyShortcut.optionMask
            | HotKeyShortcut.commandMask)
        #expect(symbols?.description == "ctrl+opt+cmd+w")

        let digits = HotKeyShortcut.parse("cmd+shift+1")
        #expect(digits?.keyCode == 18)
        #expect(digits == HotKeyShortcut.parse("⌘⇧1"))
    }

    @Test func shortcutsThatWouldStealTypingAreRejected() {
        #expect(HotKeyShortcut.parse("") == nil)
        #expect(HotKeyShortcut.parse("   ") == nil)
        #expect(HotKeyShortcut.parse("w") == nil)          // no modifier
        #expect(HotKeyShortcut.parse("shift+w") == nil)    // shift alone
        #expect(HotKeyShortcut.parse("hyper+w") == nil)    // unknown modifier
        #expect(HotKeyShortcut.parse("ctrl+f13") == nil)   // key outside the table
        #expect(HotKeyShortcut.parse("ctrl") == nil)       // modifier without a key
    }
}
