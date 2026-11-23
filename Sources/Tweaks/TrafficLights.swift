import CoreGraphics
import Foundation

/// The traffic light buttons, named by the accessibility subrole macOS reports for them.
public enum TrafficLightButton: String, CaseIterable, Sendable {
    case close = "AXCloseButton"
    case minimize = "AXMinimizeButton"
    case fullScreen = "AXFullScreenButton"
    case zoom = "AXZoomButton"
}

/// What a click on a traffic light should do. `.system` means the click is passed on untouched, so
/// the default for every button is the macOS behaviour itself; only a setting that changes the
/// behaviour makes the event tap swallow the click.
public enum TrafficLightAction: Equatable, Sendable {
    case system
    case closeWindow(quitIfLast: Bool)
    case hideApp
    case fillScreen
    case zoom
}

/// The three per-button choices, read once per settings change.
public struct TrafficLightOptions: Equatable, Sendable {
    public var closeAction: String
    public var minimizeAction: String
    public var zoomAction: String
    public var excludedApps: [String]

    public init(closeAction: String = "close", minimizeAction: String = "minimize",
                zoomAction: String = "fullScreen", excludedApps: [String] = []) {
        self.closeAction = closeAction
        self.minimizeAction = minimizeAction
        self.zoomAction = zoomAction
        self.excludedApps = excludedApps
    }

    public init(settings: TweakSettings) {
        self.init(closeAction: settings.string("closeAction", for: .windowTrafficLights),
                  minimizeAction: settings.string("minimizeAction", for: .windowTrafficLights),
                  zoomAction: settings.string("zoomAction", for: .windowTrafficLights),
                  excludedApps: settings.stringList("excludedApps", for: .windowTrafficLights))
    }
}

/// The decisions behind the traffic light tweak. They are pure so the behaviour on the event tap's
/// thread stays a lookup, and so the table below can be tested without Accessibility permission.
public enum TrafficLightRules {
    /// Height and width of the strip at the top left of a window where the buttons live. A click
    /// anywhere else never reaches the accessibility hit test.
    public static let titleBarStripHeight: Double = 30
    public static let titleBarStripWidth: Double = 160

    public static func button(forSubrole subrole: String?) -> TrafficLightButton? {
        subrole.flatMap(TrafficLightButton.init(rawValue:))
    }

    /// Whether the click at `point` (global display coordinates, origin top left) can be a traffic
    /// light of the window whose frame is `windowFrame`. Only a cheap pre-filter: the accessibility
    /// hit test decides, this keeps ordinary clicks from ever asking another app anything.
    public static func isTitleBarClick(_ point: CGPoint, windowFrame: CGRect) -> Bool {
        guard windowFrame.width >= 24, windowFrame.height >= 24 else { return false }
        let strip = CGRect(x: windowFrame.minX, y: windowFrame.minY,
                           width: min(windowFrame.width, titleBarStripWidth),
                           height: min(windowFrame.height, titleBarStripHeight))
        return strip.contains(point)
    }

    /// The whole decision for one click. Every modifier (⌥ for the system's alternate green-button
    /// behaviour, ⌘/⌃/⇧ for app-specific click meanings) keeps the system behaviour, and so does an
    /// excluded app or MacHelper itself.
    public static func action(button: TrafficLightButton?, flags: UInt64, bundleID: String?,
                              options: TrafficLightOptions, ownBundleID: String) -> TrafficLightAction {
        guard let button else { return .system }
        let modifiers = TweakRules.commandFlag | TweakRules.shiftFlag | TweakRules.alternateFlag | TweakRules.controlFlag
        guard flags & modifiers == 0 else { return .system }
        if let bundleID, isExcluded(bundleID, apps: options.excludedApps, ownBundleID: ownBundleID) {
            return .system
        }
        switch button {
        case .close:
            return options.closeAction == "quit" ? .closeWindow(quitIfLast: true) : .system
        case .minimize:
            return options.minimizeAction == "hide" ? .hideApp : .system
        case .fullScreen, .zoom:
            switch options.zoomAction {
            case "fill": return .fillScreen
            case "zoom": return .zoom
            default: return .system
            }
        }
    }

    /// Case-insensitive, like the quit guard's list; MacHelper itself is always excluded so its own
    /// windows keep behaving normally.
    public static func isExcluded(_ bundleID: String, apps: [String], ownBundleID: String) -> Bool {
        let excluded = Set((apps + [ownBundleID]).map { $0.lowercased() })
        return excluded.contains(bundleID.lowercased())
    }

    /// "Quit" on the close button only quits when the clicked window is the app's last one;
    /// otherwise the window closes like the red button normally does.
    public static func shouldQuitApp(quitIfLast: Bool, userWindowCount: Int) -> Bool {
        quitIfLast && userWindowCount <= 1
    }
}

/// Pairs a swallowed mouse-down with its mouse-up. macOS acts on the release, so letting the up
/// through after taking the down would make the click land twice (the Dock would activate the app
/// that was just hidden, a window would close and then the button would see a stray release).
public struct MouseClickPairing: Equatable, Sendable {
    private var swallowedDown = false

    public init() {}

    /// Returns whether the mouse-down is swallowed.
    public mutating func mouseDown(matched: Bool) -> Bool {
        swallowedDown = matched
        return matched
    }

    /// Returns whether the mouse-up is swallowed: only the one that ends a swallowed down.
    public mutating func mouseUp() -> Bool {
        defer { swallowedDown = false }
        return swallowedDown
    }
}
