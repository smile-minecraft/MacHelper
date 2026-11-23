import CoreGraphics
import Foundation

/// Small, side-effect-free rules behind the event-driven behaviours. They live in the shared
/// library so they can be unit-tested on a Mac where Accessibility has not been granted.
public enum TweakRules {
    public static let commandFlag: UInt64 = 1 << 20
    public static let shiftFlag: UInt64 = 1 << 17
    // CGEventFlags: maskControl is bit 18, maskAlternate (Option) bit 19.
    public static let controlFlag: UInt64 = 1 << 18
    public static let alternateFlag: UInt64 = 1 << 19
    public static let keyQ: UInt16 = 12
    public static let keyW: UInt16 = 13

    /// Plain ⌘Q (and ⌘W when opted in) is guarded. Modified variants such as ⌥⌘Q are untouched.
    public static func isGuardedKey(keyCode: UInt16, flags: UInt64, guardCloseWindow: Bool) -> Bool {
        guard flags & commandFlag != 0,
              flags & (shiftFlag | alternateFlag | controlFlag) == 0 else { return false }
        return keyCode == keyQ || (guardCloseWindow && keyCode == keyW)
    }

    public static func isCommandHeld(_ flags: UInt64) -> Bool { flags & commandFlag != 0 }

    /// MacHelper itself is never guarded, so the app can always be quit. Exclusions are bundle ids.
    public static func shouldGuardQuit(bundleID: String?, excludedApps: [String], ownBundleID: String) -> Bool {
        guard let bundleID else { return true }
        let excluded = Set(excludedApps.map { $0.lowercased() } + [ownBundleID.lowercased()])
        return !excluded.contains(bundleID.lowercased())
    }

    public static func holdCompleted(elapsed: TimeInterval, required: TimeInterval) -> Bool {
        required > 0 && elapsed >= required
    }

    public static func doublePressAllowed(previousPressAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let previousPressAt else { return false }
        let elapsed = now.timeIntervalSince(previousPressAt)
        return elapsed >= 0 && elapsed <= interval
    }

    /// AX hit tests return an element with a role and often a subrole; only the application items
    /// in the Dock are relevant, not separators, stacks or running indicators.
    public static func isApplicationDockItem(role: String?, subrole: String?) -> Bool {
        if subrole == "AXApplicationDockItem" { return true }
        return role == "AXApplicationDockItem" || (role == "AXDockItem" && subrole == nil)
    }

    public static func shouldActOnDockItem(dockBundleID: String?, frontmostBundleID: String?) -> Bool {
        guard let dockBundleID, let frontmostBundleID, !dockBundleID.isEmpty else { return false }
        return dockBundleID.caseInsensitiveCompare(frontmostBundleID) == .orderedSame
    }

    /// Windows the window tweaks act on: standard document windows and dialog-style app windows.
    public static func isUserWindow(subrole: String?) -> Bool {
        subrole == "AXStandardWindow" || subrole == "AXDialog"
    }

    /// An app that already has an ordinary visible window does not need ⌘Tab restoration.
    public static func shouldRestoreWindow(visibleWindows: Int, minimizedWindows: Int) -> Bool {
        visibleWindows == 0 && minimizedWindows > 0
    }

    public static func shouldTerminateMusic(bundleID: String?, enabled: Bool) -> Bool {
        enabled && bundleID == "com.apple.Music"
    }

    // MARK: Dock clicks

    /// The Dock lives on the bottom, left or right edge of a display, and a magnified icon reaches at
    /// most this far in. Clicks further from those edges never touch the Dock, so the event tap
    /// passes them on without asking the Dock anything.
    public static let dockEdgeBand: Double = 320

    /// Whether a click (global display coordinates, origin top left, as CGEvent reports it) is close
    /// enough to a Dock edge of one of `displays` to be worth an accessibility hit test.
    public static func isNearDockEdge(_ point: CGPoint, displays: [CGRect], band: Double = dockEdgeBand) -> Bool {
        displays.contains { d in
            guard d.contains(point) else { return false }
            return point.y >= d.maxY - band || point.x <= d.minX + band || point.x >= d.maxX - band
        }
    }

    /// The hint shown when a guarded shortcut was held back.
    public enum GuardHint: Equatable, Sendable {
        case holdToQuit, holdToClose, pressTwiceToQuit, pressTwiceToClose
    }

    public static func guardHint(keyCode: UInt16, doublePress: Bool) -> GuardHint {
        switch (keyCode == keyW, doublePress) {
        case (false, false): .holdToQuit
        case (true, false): .holdToClose
        case (false, true): .pressTwiceToQuit
        case (true, true): .pressTwiceToClose
        }
    }
}
