import AppKit
import CoreGraphics
import Foundation
import Tweaks

/// Handles a click on the Dock icon of the app that is already in the foreground. The Dock item is
/// found with AX hit testing; the event is suppressed only after a confident match.
@MainActor
final class DockClickBehavior {
    private var settings = TweakSettings()
    private var enabled = false
    private var frontmostBundleID: String?

    func configure(enabled: Bool, settings: TweakSettings, frontmostBundleID: String?) {
        self.enabled = enabled
        self.settings = settings
        self.frontmostBundleID = frontmostBundleID
    }

    func updateFrontmost(_ bundleID: String?) { frontmostBundleID = bundleID }

    func handle(_ event: CGEvent) -> EventTapService.Outcome? {
        guard enabled, event.type == .leftMouseDown,
              event.getIntegerValueField(.mouseEventClickState) == 1 else { return nil }
        guard let hit = AXWindowTools.dockItem(at: event.location),
              TweakRules.isApplicationDockItem(role: hit.role, subrole: hit.subrole),
              TweakRules.shouldActOnDockItem(dockBundleID: hit.bundleID,
                                             frontmostBundleID: frontmostBundleID) else { return nil }

        let action = settings.string("action", for: .dockClickAction)
        let cycle = settings.bool("cycleWindows", for: .dockClickAction)
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return .suppressThen { [weak self] in
            guard let pid else { return }
            if cycle && AXWindowTools.cycleWindows(for: pid) { return }
            if action == "minimize" {
                _ = AXWindowTools.minimizeAllWindows(for: pid)
            } else {
                NSWorkspace.shared.frontmostApplication?.hide()
            }
        }
    }
}
