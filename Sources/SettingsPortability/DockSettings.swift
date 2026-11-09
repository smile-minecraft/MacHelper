import Foundation

/// How MacHelper presents itself in the Dock. This replaces the pre-0.3.0 `showInDock` Boolean.
public enum DockMode: String, Codable, CaseIterable, Sendable {
    /// Always show the Dock icon, including when no window is open.
    case always
    /// Show the Dock icon while at least one ordinary app window is open.
    case whileWindowOpen
    /// Never show the Dock icon; the app lives in the menu bar.
    case never

    /// Migration from the old Boolean: a visible icon becomes "while a window is open", because the
    /// point of the new default is to remove the icon when the last window closes.
    public init(legacyShowInDock: Bool) {
        self = legacyShowInDock ? .whileWindowOpen : .never
    }

    /// Whether the app should use the regular activation policy (Dock icon and app menu).
    public func showsDockIcon(hasOpenWindows: Bool) -> Bool {
        switch self {
        case .always: true
        case .whileWindowOpen: hasOpenWindows
        case .never: false
        }
    }
}

/// Reads and writes the Dock mode, migrating the old Boolean exactly once.
public enum DockPreference {
    public static let modeKey = "dockMode"
    public static let legacyKey = "showInDock"

    /// Returns the stored mode, converting `showInDock` on first use. Safe to call repeatedly.
    @discardableResult
    public static func migrate(_ defaults: UserDefaults) -> DockMode {
        if let raw = defaults.string(forKey: modeKey) {
            // An unknown value can come from a newer version. Keep it for that version and use the
            // current default rather than overwriting it with an older meaning.
            return DockMode(rawValue: raw) ?? .whileWindowOpen
        }
        let legacy = defaults.object(forKey: legacyKey) as? Bool ?? true
        let mode = DockMode(legacyShowInDock: legacy)
        defaults.set(mode.rawValue, forKey: modeKey)
        defaults.removeObject(forKey: legacyKey)
        return mode
    }

    public static func write(_ mode: DockMode, to defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: modeKey)
        defaults.removeObject(forKey: legacyKey)
    }
}

/// The General section's portable payload. Decoding accepts the pre-0.3.0 `showInDock` Boolean so old
/// backups still import; encoding always writes the new `dockMode` string.
public struct GeneralSettingsPayload: Codable, Equatable, Sendable {
    public var dockMode: DockMode
    public var language: String?

    public init(dockMode: DockMode = .whileWindowOpen, language: String? = nil) {
        self.dockMode = dockMode
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case dockMode
        case showInDock
        case language
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let mode = try container.decodeIfPresent(DockMode.self, forKey: .dockMode) {
            dockMode = mode
        } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .showInDock) {
            dockMode = DockMode(legacyShowInDock: legacy)
        } else {
            dockMode = .whileWindowOpen
        }
        language = try container.decodeIfPresent(String.self, forKey: .language)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dockMode, forKey: .dockMode)
        try container.encodeIfPresent(language, forKey: .language)
    }
}
