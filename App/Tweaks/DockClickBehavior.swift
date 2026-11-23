import AppKit
import CoreGraphics
import Foundation
import Tweaks

/// Handles a click on the Dock icon of the app that is already in the foreground.
///
/// It runs on the event tap's thread for every left click, so it stays cheap: a click away from the
/// Dock edges is passed on without any IPC, and the one accessibility hit test against the Dock has
/// a short messaging timeout. The click is swallowed (down and up together) only after the Dock
/// itself confirmed it is the frontmost app's icon; hiding or minimizing then runs on the main queue.
final class DockClickBehavior: @unchecked Sendable {
    private struct Config {
        var enabled = false
        var minimize = false
        var cycleWindows = false
        var frontmostBundleID: String?
        var frontmostPID: pid_t?
        var dockPID: pid_t?
    }

    private let lock = NSLock()
    private var config = Config()
    private var pairing = MouseClickPairing()

    func configure(enabled: Bool, settings: TweakSettings, frontmost: NSRunningApplication?) {
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        lock.withLock {
            config = Config(enabled: enabled,
                            minimize: settings.string("action", for: .dockClickAction) == "minimize",
                            cycleWindows: settings.bool("cycleWindows", for: .dockClickAction),
                            frontmostBundleID: frontmost?.bundleIdentifier,
                            frontmostPID: frontmost?.processIdentifier,
                            dockPID: dockPID)
            if !enabled { pairing = MouseClickPairing() }
        }
    }

    func updateFrontmost(_ app: NSRunningApplication) {
        lock.withLock {
            config.frontmostBundleID = app.bundleIdentifier
            config.frontmostPID = app.processIdentifier
        }
    }

    /// The Dock restarts (and gets a new pid) after a crash or a `killall Dock`.
    func updateDock(pid: pid_t?) { lock.withLock { config.dockPID = pid } }

    /// Nil: not a Dock click this behaviour acts on.
    func handle(_ type: CGEventType, _ event: CGEvent) -> EventTapService.Outcome? {
        if type == .leftMouseUp {
            return lock.withLock { pairing.mouseUp() } ? .suppress : nil
        }
        guard type == .leftMouseDown else { return nil }
        let config = lock.withLock { self.config }
        // ⌃-click (menu), ⌘-click (show in Finder), ⌥-click (hide others) and ⇧-click keep
        // their Dock meaning.
        let modifiers = TweakRules.commandFlag | TweakRules.shiftFlag | TweakRules.alternateFlag | TweakRules.controlFlag
        guard config.enabled, let dockPID = config.dockPID, let frontmostPID = config.frontmostPID,
              event.flags.rawValue & modifiers == 0,
              event.getIntegerValueField(.mouseEventClickState) == 1 else {
            lock.withLock { _ = pairing.mouseDown(matched: false) }
            return nil
        }
        let point = event.location
        var matched = false
        if TweakRules.isNearDockEdge(point, displays: Self.displayBounds()),
           let hit = AXWindowTools.dockItem(at: point, dockPID: dockPID) {
            matched = TweakRules.isApplicationDockItem(role: hit.role, subrole: hit.subrole)
                && TweakRules.shouldActOnDockItem(dockBundleID: hit.bundleID, frontmostBundleID: config.frontmostBundleID)
                // With nothing on screen (all minimized, or no window at all) the click is the
                // way back: let the Dock restore or reopen a window.
                && AXWindowTools.hasVisibleWindow(for: frontmostPID, timeout: 0.1)
        }
        guard lock.withLock({ pairing.mouseDown(matched: matched) }) else { return nil }

        let minimize = config.minimize, cycle = config.cycleWindows
        DispatchQueue.main.async {
            if cycle && AXWindowTools.cycleWindows(for: frontmostPID) { return }
            if minimize {
                _ = AXWindowTools.minimizeAllWindows(for: frontmostPID)
            } else {
                NSRunningApplication(processIdentifier: frontmostPID)?.hide()
            }
        }
        return .suppress
    }

    /// Display frames in the same global, top-left-origin space as `CGEvent.location`. A cheap
    /// window server query, safe on any thread.
    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}
