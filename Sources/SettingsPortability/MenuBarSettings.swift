import Foundation

/// Whether MacHelper shows its menu bar item. The item stays on unless the user turns it off, so a
/// missing value reads as "shown": that keeps every existing install and every older backup on the
/// behaviour it had before the switch existed.
public enum MenuBarPreference {
    public static let visibleKey = "menuBarVisible"

    public static func isVisible(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: visibleKey) as? Bool ?? true
    }

    public static func write(visible: Bool, to defaults: UserDefaults) {
        defaults.set(visible, forKey: visibleKey)
    }
}

/// Ties the menu bar item to the Dock icon.
///
/// The Dock menu carries the same destinations as the app's menu, so a hidden menu bar item only
/// works while the Dock icon stays. A MacHelper with neither one would be unreachable. Both the
/// Settings controls and a settings import resolve the two preferences through this rule, so the
/// stored Dock mode can never contradict the hidden item.
public enum DockPolicy {
    /// The Dock mode that actually applies: a hidden menu bar item always keeps the Dock icon.
    public static func effectiveMode(requested: DockMode, menuBarVisible: Bool) -> DockMode {
        menuBarVisible ? requested : .always
    }

    /// Whether `mode` can be chosen while the menu bar item is in that state.
    public static func allows(_ mode: DockMode, menuBarVisible: Bool) -> Bool {
        effectiveMode(requested: mode, menuBarVisible: menuBarVisible) == mode
    }
}
