import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Tweaks

/// The AX helpers shared by the window-related tweaks. Everything that can be decided from plain
/// values lives in TweakRules; this file only talks to the accessibility API.
enum AXWindowTools {
    static func windows(for pid: pid_t, timeout: Float = 0.5) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        // A hung app must not freeze MacHelper for the default six seconds. Elements obtained
        // from it inherit the application's timeout.
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    /// A window the person minimizes and brings back: document windows and dialog-style app windows
    /// (Calculator's only window is an AXDialog). Floating palettes and sheets don't count.
    /// Whether the app shows at least one ordinary window that isn't minimized.
    static func hasVisibleWindow(for pid: pid_t, timeout: Float) -> Bool {
        windows(for: pid, timeout: timeout).contains { isStandardWindow($0) && isVisible($0) }
    }

    static func isStandardWindow(_ window: AXUIElement) -> Bool {
        TweakRules.isUserWindow(subrole: string(window, "AXSubrole"))
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        bool(window, "AXMinimized") == true
    }

    static func isVisible(_ window: AXUIElement) -> Bool {
        !isMinimized(window) && bool(window, "AXHidden") != true
    }

    /// An app with an ordinary visible window does not need help from ⌘Tab.
    static func restoresLastMinimizedWindow(for pid: pid_t) -> Bool {
        let windows = windows(for: pid).filter(isStandardWindow)
        let visible = windows.filter(isVisible).count
        let minimized = windows.filter(isMinimized).count
        guard TweakRules.shouldRestoreWindow(visibleWindows: visible, minimizedWindows: minimized) else { return false }
        guard let target = windows.first(where: isMinimized) else { return false }
        AXUIElementSetAttributeValue(target, "AXMinimized" as CFString, false as CFBoolean)
        AXUIElementPerformAction(target, "AXRaise" as CFString)
        return true
    }

    static func minimizeAllWindows(for pid: pid_t) -> Int {
        var count = 0
        for window in windows(for: pid).filter(isStandardWindow) where !isMinimized(window) {
            AXUIElementSetAttributeValue(window, "AXMinimized" as CFString, true as CFBoolean)
            count += 1
        }
        return count
    }

    /// Brings the next window forward when a foreground app has more than one.
    static func cycleWindows(for pid: pid_t) -> Bool {
        let windows = windows(for: pid).filter(isStandardWindow)
        guard windows.count > 1 else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var mainValue: CFTypeRef?
        let main: AXUIElement? = AXUIElementCopyAttributeValue(app, "AXMainWindow" as CFString, &mainValue) == .success
            && mainValue.map({ CFGetTypeID($0) == AXUIElementGetTypeID() }) == true ? (mainValue as! AXUIElement) : nil
        let index = main.flatMap { m in windows.firstIndex { CFEqual($0, m) } } ?? -1
        let next = windows[(index + 1) % windows.count]
        if isMinimized(next) { AXUIElementSetAttributeValue(next, "AXMinimized" as CFString, false as CFBoolean) }
        AXUIElementPerformAction(next, "AXRaise" as CFString)
        return true
    }

    /// Hit tests the Dock itself instead of guessing from icon coordinates. Called from the event
    /// tap's thread, so the Dock gets a short timeout: a Dock that doesn't answer quickly means the
    /// click is passed on untouched rather than held up.
    static func dockItem(at point: CGPoint, dockPID: pid_t) -> (bundleID: String?, role: String?, subrole: String?)? {
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.1)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.1)
        let role = string(element, "AXRole")
        let subrole = string(element, "AXSubrole")
        guard TweakRules.isApplicationDockItem(role: role, subrole: subrole) else { return nil }
        // An application Dock item carries the app's URL; the title is only a fallback.
        var urlValue: CFTypeRef?
        let url = AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlValue) == .success ? urlValue as? URL : nil
        let bundleID = url.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? runningAppID(for: string(element, "AXTitle"))
        return (bundleID, role, subrole)
    }

    private static func runningAppID(for title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { app in
            app.localizedName == title
                || app.bundleURL?.deletingPathExtension().lastPathComponent == title
        }?.bundleIdentifier
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}
