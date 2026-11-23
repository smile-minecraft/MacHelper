import Foundation

/// A tool page that can be switched off independently. Overview is deliberately not a module:
/// it is the home page and is always available.
public enum FeatureModule: String, Codable, CaseIterable, Sendable {
    case monitor, health, fans, optimize, disk, uninstall, updates, startup, tweaks

    /// New modules can ship turned off by changing only this property.
    public var defaultEnabled: Bool { true }

    /// Simple mode keeps the everyday tools and hides the advanced ones.
    public var hiddenInSimpleMode: Bool {
        switch self {
        case .monitor, .fans, .startup: true
        case .health, .optimize, .disk, .uninstall, .updates, .tweaks: false
        }
    }

    /// The single rule behind the sidebar, the numbered menu, quick bars and overview shortcuts.
    public func isVisible(enabled: Bool, simpleMode: Bool) -> Bool {
        enabled && (!simpleMode || !hiddenInSimpleMode)
    }
}

/// Only the user's deviations from the defaults are stored, so a new module's `defaultEnabled`
/// takes effect for every existing installation without a migration.
public struct FeatureSet: Codable, Equatable, Sendable {
    private var overrides: [String: Bool]

    public init() { overrides = [:] }

    public func isEnabled(_ module: FeatureModule) -> Bool {
        overrides[module.rawValue] ?? module.defaultEnabled
    }

    public mutating func setEnabled(_ module: FeatureModule, _ enabled: Bool) {
        if enabled == module.defaultEnabled {
            overrides.removeValue(forKey: module.rawValue)
        } else {
            overrides[module.rawValue] = enabled
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var decoded: [String: Bool] = [:]
        for key in container.allKeys {
            // A newer version's module or a damaged value must not make the whole backup unreadable.
            guard let module = FeatureModule(rawValue: key.stringValue),
                  let value = try? container.decode(Bool.self, forKey: key),
                  value != module.defaultEnabled else { continue }
            decoded[key.stringValue] = value
        }
        overrides = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in overrides where FeatureModule(rawValue: key) != nil {
            try container.encode(value, forKey: AnyKey(stringValue: key)!)
        }
    }
}
