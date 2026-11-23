import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Tweaks

/// Handles clicks on a window's close, minimize and zoom buttons when a setting changes what they
/// do.
///
/// It runs on the event tap's thread for every left click, so it stays cheap: the click must first
/// land in the title bar strip of the frontmost window at that point (a window server query), and
/// the one accessibility hit test against the owning app has a short timeout. Only a button whose
/// configured action differs from the system behaviour is swallowed; everything else, including
/// every modifier-click, is passed on untouched. The action itself runs on the main queue.
final class TrafficLightBehavior: @unchecked Sendable {
    /// Everything the main queue needs after the tap already decided to swallow the click. The
    /// element is an accessibility object, which is safe to keep across threads.
    private final class Request: @unchecked Sendable {
        let action: TrafficLightAction
        let pid: pid_t
        let element: AXUIElement
        let windowFrame: CGRect

        init(action: TrafficLightAction, pid: pid_t, element: AXUIElement, windowFrame: CGRect) {
            self.action = action
            self.pid = pid
            self.element = element
            self.windowFrame = windowFrame
        }
    }

    private struct Config {
        var enabled = false
        var options = TrafficLightOptions()
        var ownBundleID = "com.machelper.MacHelper"
    }

    private struct Target {
        let pid: pid_t
        let frame: CGRect
    }

    private let lock = NSLock()
    private var config = Config()
    private var pairing = MouseClickPairing()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Set MACHELPER_TWEAKS_TRACE=1 to see every decision on stderr. Only used while developing the
    /// behaviour: a GUI launch discards stderr anyway.
    private static let trace = ProcessInfo.processInfo.environment["MACHELPER_TWEAKS_TRACE"] != nil

    func configure(enabled: Bool, settings: TweakSettings, ownBundleID: String) {
        let options = TrafficLightOptions(settings: settings)
        lock.withLock {
            config = Config(enabled: enabled, options: options, ownBundleID: ownBundleID)
            if !enabled { pairing = MouseClickPairing() }
        }
        if Self.trace {
            Self.log("configure enabled=\(enabled) close=\(options.closeAction) minimize=\(options.minimizeAction) "
                + "zoom=\(options.zoomAction) excluded=\(options.excludedApps)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("traffic-lights: \(message)\n".utf8))
    }

    func reset() { lock.withLock { pairing = MouseClickPairing() } }

    /// Nil: not a click this behaviour acts on.
    func handle(_ type: CGEventType, _ event: CGEvent) -> EventTapService.Outcome? {
        if type == .leftMouseUp {
            return lock.withLock { pairing.mouseUp() } ? .suppress : nil
        }
        guard type == .leftMouseDown else { return nil }
        let request = leftMouseDown(event)
        let swallowed = lock.withLock { pairing.mouseDown(matched: request != nil) }
        guard swallowed, let request else { return nil }
        DispatchQueue.main.async { Self.perform(request) }
        return .suppress
    }

    /// The click this behaviour takes over, if any. Every early return means "pass the click on".
    private func leftMouseDown(_ event: CGEvent) -> Request? {
        let config = lock.withLock { self.config }
        guard config.enabled, event.getIntegerValueField(.mouseEventClickState) == 1 else { return nil }
        let point = event.location
        guard let target = Self.frontmostWindow(at: point),
              target.pid != ownPID,
              TrafficLightRules.isTitleBarClick(point, windowFrame: target.frame),
              let hit = Self.button(at: point, pid: target.pid) else { return nil }
        let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
        let action = TrafficLightRules.action(button: hit.button, flags: event.flags.rawValue, bundleID: bundleID,
                                              options: config.options, ownBundleID: config.ownBundleID)
        if Self.trace {
            Self.log("click pid=\(target.pid) button=\(hit.button.rawValue) flags=\(event.flags.rawValue) action=\(action)")
        }
        guard action != .system else { return nil }
        return Request(action: action, pid: target.pid, element: hit.element, windowFrame: target.frame)
    }

    // MARK: - Event tap thread

    /// The frontmost ordinary window under the point. Window server data only, no IPC with the app.
    private static func frontmostWindow(at point: CGPoint) -> Target? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(point) else { continue }
            return Target(pid: pid, frame: frame)
        }
        return nil
    }

    /// The traffic light under the point, from the app's own accessibility tree. A short timeout is
    /// set on every element: an app that stops answering means the click is passed on instead of
    /// waiting the six-second default on the tap's thread.
    private static func button(at point: CGPoint, pid: pid_t) -> (button: TrafficLightButton, element: AXUIElement)? {
        let app = AccessibilityWindows.appElement(pid, timeout: 0.1)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success,
              var current = element else { return nil }
        // Some apps wrap the button in a group; walk up a few levels instead of insisting the hit
        // test returned the button itself.
        for _ in 0..<3 {
            AXUIElementSetMessagingTimeout(current, 0.1)
            if AccessibilityWindows.string(current, "AXRole") == "AXButton",
               let button = TrafficLightRules.button(forSubrole: AccessibilityWindows.string(current, "AXSubrole")) {
                return (button, current)
            }
            guard let parent = AccessibilityWindows.attribute(current, "AXParent"),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    // MARK: - Main queue

    private static func perform(_ request: Request) {
        let pid = request.pid
        if trace { log("perform action=\(request.action) pid=\(pid) frame=\(request.windowFrame)") }
        switch request.action {
        case .system:
            break
        case .closeWindow(let quitIfLast):
            let windowCount = AccessibilityWindows.userWindows(of: pid).count
            if TrafficLightRules.shouldQuitApp(quitIfLast: quitIfLast, userWindowCount: windowCount) {
                NSRunningApplication(processIdentifier: pid)?.terminate()
            } else if let window = window(for: request) {
                AccessibilityWindows.close(window)
            }
        case .hideApp:
            NSRunningApplication(processIdentifier: pid)?.hide()
        case .fillScreen:
            if let window = window(for: request) { AccessibilityWindows.fillToVisibleFrame(window) }
        case .zoom:
            if let window = window(for: request) { AccessibilityWindows.zoom(window) }
        }
    }

    /// The clicked window: the button's accessibility parent, or, when the app does not publish
    /// that chain, the window whose frame is the one the click landed in.
    private static func window(for request: Request) -> AXUIElement? {
        if let window = AccessibilityWindows.window(containing: request.element) { return window }
        return AccessibilityWindows.userWindows(of: request.pid).first { window in
            guard let frame = AccessibilityWindows.frame(window) else { return false }
            return abs(frame.origin.x - request.windowFrame.origin.x) < 2
                && abs(frame.origin.y - request.windowFrame.origin.y) < 2
                && abs(frame.width - request.windowFrame.width) < 2
                && abs(frame.height - request.windowFrame.height) < 2
        }
    }
}
