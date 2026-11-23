import AppKit
import Darwin
import ApplicationServices
import Foundation

/// A window's identity that survives the trip from `windows list` to `windows close`: the owning
/// process and the window server's number for the window (`CGWindowID`).
///
/// The position in the app's accessibility window list is not an identity: most apps list their
/// windows front to back, so focusing one window renumbers the others and an id printed by `list`
/// would then close a different window. The window number never changes while the window exists,
/// and an id whose window is gone resolves to nothing instead of to a neighbour.
public struct WindowIdentity: Hashable, Sendable, CustomStringConvertible {
    public let pid: Int32
    public let window: UInt32

    public init(pid: Int32, window: UInt32) {
        self.pid = pid
        self.window = window
    }

    /// "1234:5678" — the form printed by `machelper windows list` and accepted by every action.
    public init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let pid = Int32(parts[0]), pid > 0,
              let window = UInt32(parts[1]), window > 0 else { return nil }
        self.init(pid: pid, window: window)
    }

    public var description: String { "\(pid):\(window)" }
}

extension WindowIdentity: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let identity = WindowIdentity(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad window id \(text)"))
        }
        self = identity
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A window frame in the display space CGEvent and CGWindowList use: origin at the top left of the
/// main display, y growing down. `CGRect` is not Codable, and the CLI prints frames.
public struct WindowFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var aspectRatio: Double { width > 0 && height > 0 ? width / height : 0 }
}

/// One ordinary window as the switcher menu, the overlay and the CLI see it.
public struct WindowSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: WindowIdentity
    public let app: String
    public let bundleID: String?
    public let title: String
    public let minimized: Bool
    public let visible: Bool
    public let frame: WindowFrame?

    public init(id: WindowIdentity, app: String, bundleID: String?, title: String,
                minimized: Bool, visible: Bool, frame: WindowFrame?) {
        self.id = id
        self.app = app
        self.bundleID = bundleID
        self.title = title
        self.minimized = minimized
        self.visible = visible
        self.frame = frame
    }
}

public enum WindowAction: String, Codable, Sendable, CaseIterable {
    case focus, minimize, restore, close
}

/// Thin, timeout-guarded wrappers around the window attributes every window tweak needs. Reads on
/// another app block for as long as that app takes to answer, so each element gets its own short
/// messaging timeout before anything is read from it.
public enum AccessibilityWindows {
    /// Long enough for a healthy app on a loaded Mac, short enough that a hung one cannot freeze the
    /// menu or the CLI for the six-second default.
    public static let defaultTimeout: Float = 0.25

    public static func appElement(_ pid: pid_t, timeout: Float = defaultTimeout) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    public static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    public static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    public static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name) as? Bool
    }

    public static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, "AXPosition"), let sizeValue = attribute(element, "AXSize"),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Every window of the app, each with the timeout set on the element itself (the setting is per
    /// element, so windows read from the app do not inherit it).
    public static func windows(of pid: pid_t, timeout: Float = defaultTimeout) -> [AXUIElement] {
        let app = appElement(pid, timeout: timeout)
        guard let value = attribute(app, "AXWindows") as? [AXUIElement] else { return [] }
        for window in value { AXUIElementSetMessagingTimeout(window, timeout) }
        return value
    }

    /// The windows a person thinks of as windows: standard document windows and dialog-style app
    /// windows. Floating palettes, sheets and system panels are left out.
    public static func userWindows(of pid: pid_t, timeout: Float = defaultTimeout) -> [AXUIElement] {
        windows(of: pid, timeout: timeout).filter {
            TweakRules.isUserWindow(subrole: string($0, "AXSubrole"))
        }
    }

    public static func isMinimized(_ window: AXUIElement) -> Bool {
        bool(window, "AXMinimized") == true
    }

    public static func isVisible(_ window: AXUIElement) -> Bool {
        !isMinimized(window) && bool(window, "AXHidden") != true
    }

    public static func title(of window: AXUIElement) -> String {
        string(window, "AXTitle") ?? ""
    }

    /// The window an element belongs to, walking accessibility parents. A traffic light button is a
    /// child of the window's title bar group, two or three levels down.
    public static func window(containing element: AXUIElement, timeout: Float = defaultTimeout, depth: Int = 4) -> AXUIElement? {
        var current = element
        for _ in 0..<depth {
            guard let parent = attribute(current, "AXParent") else { return nil }
            guard CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            let next = parent as! AXUIElement
            AXUIElementSetMessagingTimeout(next, timeout)
            if string(next, "AXRole") == "AXWindow" { return next }
            current = next
        }
        return nil
    }

    /// `_AXUIElementGetWindow`: the window server number behind an accessibility window. It is not
    /// in the public headers, but it is the only link between the two APIs and window managers have
    /// relied on it for years. It is looked up at run time, so a macOS without it leaves every window
    /// unaddressable (nothing is listed or acted on) instead of failing to launch.
    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindowFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    public static func windowNumber(_ window: AXUIElement) -> UInt32? {
        guard let getWindow else { return nil }
        var number: CGWindowID = 0
        guard getWindow(window, &number) == .success, number != 0 else { return nil }
        return number
    }

    // MARK: - Actions

    /// The window with this number in the app, or nil when it closed in the meantime.
    public static func resolve(_ identity: WindowIdentity, timeout: Float = defaultTimeout) -> AXUIElement? {
        userWindows(of: identity.pid, timeout: timeout).first { windowNumber($0) == identity.window }
    }

    @discardableResult
    public static func perform(_ action: WindowAction, on identity: WindowIdentity,
                               timeout: Float = defaultTimeout) -> Bool {
        guard let window = resolve(identity, timeout: timeout) else { return false }
        switch action {
        case .focus: return focus(window, pid: identity.pid)
        case .minimize: return setMinimized(window, true)
        case .restore: return setMinimized(window, false)
        case .close: return close(window)
        }
    }

    /// Brings a window back and in front: undo minimize, raise it, then activate the app so the
    /// raised window becomes the key window rather than one behind another app.
    @discardableResult
    public static func focus(_ window: AXUIElement, pid: pid_t) -> Bool {
        var worked = true
        if isMinimized(window) {
            worked = AXUIElementSetAttributeValue(window, "AXMinimized" as CFString, false as CFBoolean) == .success
        }
        AXUIElementPerformAction(window, "AXRaise" as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
        return worked
    }

    @discardableResult
    public static func setMinimized(_ window: AXUIElement, _ minimized: Bool) -> Bool {
        AXUIElementSetAttributeValue(window, "AXMinimized" as CFString, minimized as CFBoolean) == .success
    }

    /// Presses the window's own close button: the same path the red traffic light uses, so apps see
    /// an ordinary close instead of a termination.
    @discardableResult
    public static func close(_ window: AXUIElement) -> Bool {
        guard let button = attribute(window, "AXCloseButton") else { return false }
        guard CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, "AXPress" as CFString) == .success
    }

    /// Fills the screen the window is on without entering full screen: the zoomed frame is the
    /// screen's visible area (menu bar and Dock excluded).
    @discardableResult
    public static func fillToVisibleFrame(_ window: AXUIElement) -> Bool {
        guard let windowFrame = frame(window) else { return false }
        func overlap(_ frame: CGRect) -> CGFloat {
            let common = frame.intersection(windowFrame)
            return common.isNull ? 0 : common.width * common.height
        }
        let screen = NSScreen.screens.max { overlap($0.frame) < overlap($1.frame) } ?? NSScreen.main
        guard let screen else { return false }
        // NSScreen is AppKit's bottom-left space; AX and CGWindowList use top-left from the primary.
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
        let visible = screen.visibleFrame
        let topLeft = CGRect(x: visible.minX, y: primaryHeight - visible.maxY,
                             width: visible.width, height: visible.height)
        var sizeValue = CGSize(width: topLeft.width, height: topLeft.height)
        var positionValue = CGPoint(x: topLeft.minX, y: topLeft.minY)
        guard let size = AXValueCreate(.cgSize, &sizeValue),
              let position = AXValueCreate(.cgPoint, &positionValue) else { return false }
        let positioned = AXUIElementSetAttributeValue(window, "AXPosition" as CFString, position) == .success
        let sized = AXUIElementSetAttributeValue(window, "AXSize" as CFString, size) == .success
        return positioned && sized
    }

    /// The system's zoom (the old "maximize"), not full screen. Since macOS 14 the green button of
    /// most windows only has the full-screen behaviour, and the window's "AXZoomButton" attribute
    /// points at that same button; pressing it would enter full screen. So only press a button that
    /// really is the zoom button, and otherwise fill the screen without going full screen.
    @discardableResult
    public static func zoom(_ window: AXUIElement) -> Bool {
        if let button = attribute(window, "AXZoomButton"), CFGetTypeID(button) == AXUIElementGetTypeID() {
            let zoomButton = button as! AXUIElement
            if string(zoomButton, "AXSubrole") == "AXZoomButton",
               AXUIElementPerformAction(zoomButton, "AXPress" as CFString) == .success {
                return true
            }
        }
        return fillToVisibleFrame(window)
    }
}

/// Lists the windows the tweaks work on, grouped the way the menu shows them.
public enum WindowCatalog {
    /// Ordinary apps with a Dock presence. Accessory and background agents have no windows a person
    /// switches between, and their AX trees are often empty.
    public static func applications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    /// Every ordinary window of every ordinary app that Accessibility reports, minimized ones
    /// included. Most apps only report the windows of the current desktop.
    /// Apps are listed by name, and inside an app in the accessibility order (front to
    /// back for most apps). A window without a window server number cannot be addressed later, so
    /// it is left out rather than listed with an id that would not resolve.
    public static func snapshots(timeout: Float = AccessibilityWindows.defaultTimeout) -> [WindowSnapshot] {
        var result: [WindowSnapshot] = []
        for app in applications() {
            let pid = app.processIdentifier
            let windows = AccessibilityWindows.userWindows(of: pid, timeout: timeout)
            for window in windows {
                guard let number = AccessibilityWindows.windowNumber(window) else { continue }
                result.append(WindowSnapshot(
                    id: WindowIdentity(pid: pid, window: number),
                    app: app.localizedName ?? "",
                    bundleID: app.bundleIdentifier,
                    title: AccessibilityWindows.title(of: window),
                    minimized: AccessibilityWindows.isMinimized(window),
                    visible: AccessibilityWindows.isVisible(window),
                    frame: AccessibilityWindows.frame(window).map(WindowFrame.init)))
            }
        }
        return result
    }

    /// Windows grouped by app for the menu and the overlay: apps in name order, empty apps dropped.
    public struct AppGroup: Sendable, Identifiable {
        public let app: NSRunningApplication
        public let windows: [WindowSnapshot]

        public init(app: NSRunningApplication, windows: [WindowSnapshot]) {
            self.app = app
            self.windows = windows
        }

        public var id: pid_t { app.processIdentifier }
    }

    public static func groups(_ snapshots: [WindowSnapshot], apps: [NSRunningApplication]) -> [AppGroup] {
        apps.compactMap { app in
            let windows = snapshots.filter { $0.id.pid == app.processIdentifier }
            return windows.isEmpty ? nil : AppGroup(app: app, windows: windows)
        }
    }
}

