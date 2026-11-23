import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One window thumbnail of Mission Control.
///
/// Mission Control's own interface is not part of the Dock: since macOS 26 the WindowManager agent
/// (com.apple.WindowManager) publishes a `mc.display` accessibility group whose children are one
/// button per window, positioned exactly over the thumbnail. The identifier carries the owning app's
/// bundle id ("com.apple.finder.space.1").
public struct MissionControlThumbnail: Equatable, Sendable {
    public let identifier: String
    public let title: String
    /// The thumbnail's frame in the display space CGWindowList and the accessibility API use.
    public let frame: CGRect

    public init(identifier: String, title: String, frame: CGRect) {
        self.identifier = identifier
        self.title = title
        self.frame = frame
    }

    /// "com.apple.finder.space.1" → "com.apple.finder".
    public var bundleID: String? {
        guard let range = identifier.range(of: ".space.", options: .backwards),
              range.lowerBound > identifier.startIndex else { return nil }
        return String(identifier[identifier.startIndex..<range.lowerBound])
    }

    public var aspectRatio: Double {
        frame.width > 0 && frame.height > 0 ? Double(frame.width / frame.height) : 0
    }
}

/// Reading Mission Control's thumbnails and matching them to the real windows behind them. Only the
/// matching is pure; the rest reads the WindowManager's accessibility tree.
public enum MissionControlModel {
    public static let windowManagerBundleID = "com.apple.WindowManager"

    public static func windowManagerPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: windowManagerBundleID)
            .first?.processIdentifier
    }

    /// The thumbnails on screen right now; empty while Mission Control is closed. The WindowManager
    /// keeps a `mc.display` group only while it is open.
    public static func thumbnails(timeout: Float = 0.4) -> [MissionControlThumbnail] {
        guard let pid = windowManagerPID() else { return [] }
        let app = AccessibilityWindows.appElement(pid, timeout: timeout)
        guard let children = AccessibilityWindows.attribute(app, "AXChildren") as? [AXUIElement] else { return [] }
        var result: [MissionControlThumbnail] = []
        for child in children where AccessibilityWindows.string(child, "AXIdentifier") == "mc.display" {
            AXUIElementSetMessagingTimeout(child, timeout)
            guard let buttons = AccessibilityWindows.attribute(child, "AXChildren") as? [AXUIElement] else { continue }
            for button in buttons {
                AXUIElementSetMessagingTimeout(button, timeout)
                guard AccessibilityWindows.string(button, "AXRole") == "AXButton",
                      let frame = AccessibilityWindows.frame(button) else { continue }
                result.append(MissionControlThumbnail(
                    identifier: AccessibilityWindows.string(button, "AXIdentifier") ?? "",
                    title: AccessibilityWindows.string(button, "AXTitle") ?? "",
                    frame: frame))
            }
        }
        return result
    }

    /// The real window behind a thumbnail.
    ///
    /// The identifier names the app and the title names the window. Windows with the same title are
    /// only told apart by their shape, which the thumbnail keeps; when that is not conclusive this
    /// returns nil rather than acting on a guessed window.
    public static func match(bundleID: String?, title: String, aspectRatio: Double,
                             windows: [WindowSnapshot]) -> WindowIdentity? {
        guard let bundleID else { return nil }
        let candidates = windows.filter {
            $0.bundleID?.caseInsensitiveCompare(bundleID) == .orderedSame && $0.title == title
        }
        guard let only = candidates.first else { return nil }
        if candidates.count == 1 { return only.id }
        guard aspectRatio > 0 else { return nil }
        let scored = candidates.compactMap { window -> (id: WindowIdentity, error: Double)? in
            guard let ratio = window.frame?.aspectRatio, ratio > 0 else { return nil }
            return (window.id, abs(ratio - aspectRatio) / aspectRatio)
        }.sorted { $0.error < $1.error }
        guard let best = scored.first, best.error <= 0.02 else { return nil }
        // Two windows as close in shape as this: the thumbnail does not say which one it is.
        if scored.count > 1, scored[1].error - best.error <= 0.005 { return nil }
        return best.id
    }

    public static func target(for thumbnail: MissionControlThumbnail, windows: [WindowSnapshot]) -> WindowIdentity? {
        match(bundleID: thumbnail.bundleID, title: thumbnail.title,
              aspectRatio: thumbnail.aspectRatio, windows: windows)
    }

    /// Closes or minimizes the window behind a thumbnail. False when the window cannot be identified
    /// or the action did not go through.
    @discardableResult
    public static func perform(_ action: WindowAction, on thumbnail: MissionControlThumbnail) -> Bool {
        guard let identity = target(for: thumbnail, windows: WindowCatalog.snapshots()) else { return false }
        return AccessibilityWindows.perform(action, on: identity)
    }
}
