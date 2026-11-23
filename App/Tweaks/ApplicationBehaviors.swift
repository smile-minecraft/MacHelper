import AppKit
import Foundation
import Tweaks

/// Closes Music as soon as it appears. NSWorkspace's launch notification does not carry launch
/// options, so "automatic" is treated as every launch observed while the tweak is on; it never
/// touches Music that was already running before the tweak was enabled.
@MainActor
final class MusicLaunchBehavior {
    private var settings = TweakSettings()
    private var enabled = false

    func configure(enabled: Bool, settings: TweakSettings) {
        self.enabled = enabled
        self.settings = settings
    }

    func handleLaunch(_ app: NSRunningApplication) {
        guard enabled, TweakRules.shouldTerminateMusic(bundleID: app.bundleIdentifier, enabled: true) else { return }
        guard app.terminate() else { return }
        let replacement = settings.string("replacementBundleID", for: .musicBlockAutolaunch)
        guard !replacement.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: replacement) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}

/// On activation, restores a minimized window only when the app has no ordinary visible window.
@MainActor
final class CmdTabRestoreBehavior {
    private var enabled = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func configure(enabled: Bool) { self.enabled = enabled }

    func handleActivation(_ app: NSRunningApplication) {
        guard enabled, app.processIdentifier != ownPID else { return }
        let pid = app.processIdentifier
        Task { @MainActor in
            // AX windows are not always published on the first notification after Cmd+Tab.
            try? await Task.sleep(for: .milliseconds(120))
            // The person may have moved on during the wait; only restore the app still in front.
            guard self.enabled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            _ = AXWindowTools.restoresLastMinimizedWindow(for: pid)
        }
    }
}
