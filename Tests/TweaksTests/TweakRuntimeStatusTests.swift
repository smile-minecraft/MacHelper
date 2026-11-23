import Foundation
import Testing
import Tweaks

@Suite struct TweakRuntimeStatusTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "TweakStatus-\(UUID().uuidString)")
    }

    @Test func stalePIDMeansTheAppIsNotRunning() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "tweaks-status.json")
        var status = TweakRuntimeStatus(appPID: 999_999, accessibilityGranted: true,
                                        tweaks: ["input.quit-guard": .active])
        try status.write(to: url)

        let loaded = try #require(TweakRuntimeStatus.load(from: url))
        #expect(loaded.tweaks["input.quit-guard"]?.kind == .active)
        #expect(!loaded.isAppRunning)
        #expect(!TweakRuntimeStatus.processExists(-1))
        #expect(TweakRuntimeStatus.processExists(Int32(getpid())))

        status.appPID = Int32(getpid())
        try status.write(to: url)
        #expect(try #require(TweakRuntimeStatus.load(from: url)).isAppRunning)
    }

    @Test func olderStatusFilesStillDecode() throws {
        let json = #"{"appPID":123,"updatedAt":"2026-01-01T00:00:00Z","accessibilityGranted":false,"tweaks":{"dock.click-action":{"kind":"needsPermission","reason":null}}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(TweakRuntimeStatus.self, from: Data(json.utf8))
        #expect(status.schemaVersion == 1)
        #expect(!status.eventTapInstalled)
        #expect(status.tweaks["dock.click-action"]?.kind == .needsPermission)
    }

    @Test func storeWritesSettingsToAnInjectableFile() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TweakStore(directory: dir)
        var settings = TweakSettings()
        #expect(store.load() == TweakSettings())
        settings.setEnabled(.musicBlockAutolaunch, true)
        try store.save(settings)
        #expect(store.load().isEnabled(.musicBlockAutolaunch))
        #expect(FileManager.default.fileExists(atPath: store.settingsURL.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: ".tweaks.json.final").path))
    }
}

@Suite struct TweakRulesTests {
    @Test func quitGuardUsesDurationAndIgnoresModifiedShortcuts() {
        let command = TweakRules.commandFlag
        #expect(TweakRules.isGuardedKey(keyCode: TweakRules.keyQ, flags: command, guardCloseWindow: false))
        #expect(!TweakRules.isGuardedKey(keyCode: TweakRules.keyW, flags: command, guardCloseWindow: false))
        #expect(TweakRules.isGuardedKey(keyCode: TweakRules.keyW, flags: command, guardCloseWindow: true))
        #expect(!TweakRules.isGuardedKey(keyCode: TweakRules.keyQ, flags: command | TweakRules.alternateFlag, guardCloseWindow: false))
        #expect(!TweakRules.isGuardedKey(keyCode: TweakRules.keyQ, flags: 0, guardCloseWindow: true))
        #expect(TweakRules.isCommandHeld(TweakRules.commandFlag))
        #expect(!TweakRules.isCommandHeld(TweakRules.alternateFlag))
        #expect(!TweakRules.holdCompleted(elapsed: 0.59, required: 0.6))
        #expect(TweakRules.holdCompleted(elapsed: 0.6, required: 0.6))
    }

    @Test func doublePressAndExcludedApps() {
        let now = Date()
        #expect(!TweakRules.doublePressAllowed(previousPressAt: nil, now: now, interval: 0.4))
        #expect(TweakRules.doublePressAllowed(previousPressAt: now.addingTimeInterval(-0.2), now: now, interval: 0.4))
        #expect(!TweakRules.doublePressAllowed(previousPressAt: now.addingTimeInterval(-0.5), now: now, interval: 0.4))
        #expect(!TweakRules.shouldGuardQuit(bundleID: "com.machelper.MacHelper", excludedApps: [], ownBundleID: "com.machelper.MacHelper"))
        #expect(!TweakRules.shouldGuardQuit(bundleID: "com.apple.Terminal", excludedApps: ["COM.APPLE.TERMINAL"], ownBundleID: "com.machelper.MacHelper"))
        #expect(TweakRules.shouldGuardQuit(bundleID: "com.apple.Safari", excludedApps: ["com.apple.Terminal"], ownBundleID: "com.machelper.MacHelper"))
        #expect(TweakRules.shouldGuardQuit(bundleID: nil, excludedApps: [], ownBundleID: "com.machelper.MacHelper"))
    }

    @Test func dockHitTestAndWindowRules() {
        #expect(TweakRules.isApplicationDockItem(role: "AXDockItem", subrole: "AXApplicationDockItem"))
        #expect(TweakRules.isApplicationDockItem(role: "AXApplicationDockItem", subrole: nil))
        #expect(!TweakRules.isApplicationDockItem(role: "AXDockItem", subrole: "AXDockSeparatorItem"))
        #expect(!TweakRules.isApplicationDockItem(role: nil, subrole: nil))
        #expect(TweakRules.shouldActOnDockItem(dockBundleID: "com.apple.Safari", frontmostBundleID: "com.apple.Safari"))
        #expect(!TweakRules.shouldActOnDockItem(dockBundleID: "com.apple.Safari", frontmostBundleID: "com.apple.Mail"))
        #expect(!TweakRules.shouldActOnDockItem(dockBundleID: nil, frontmostBundleID: "com.apple.Mail"))
        #expect(TweakRules.shouldRestoreWindow(visibleWindows: 0, minimizedWindows: 1))
        #expect(!TweakRules.shouldRestoreWindow(visibleWindows: 1, minimizedWindows: 1))
        #expect(!TweakRules.shouldRestoreWindow(visibleWindows: 0, minimizedWindows: 0))
    }

    @Test func musicFilterOnlyTargetsMusicWhenEnabled() {
        #expect(TweakRules.shouldTerminateMusic(bundleID: "com.apple.Music", enabled: true))
        #expect(!TweakRules.shouldTerminateMusic(bundleID: "com.apple.Music", enabled: false))
        #expect(!TweakRules.shouldTerminateMusic(bundleID: "com.apple.iTunes", enabled: true))
    }
}
