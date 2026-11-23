import Foundation

/// Only values that differ from the defaults are persisted. Unknown ids, unknown options, values
/// of the wrong type and out-of-range numbers are dropped one by one: one bad entry must never make
/// the whole file unreadable.
public struct TweakSettings: Codable, Equatable, Sendable {
    private struct Entry: Codable, Equatable, Sendable {
        var enabled: Bool?
        var options: [String: TweakValue] = [:]
    }

    private var entries: [String: Entry]

    public init() { entries = [:] }

    public func isEnabled(_ id: TweakID) -> Bool { entries[id.rawValue]?.enabled ?? false }

    /// Returns false when the id is unknown to this build (it has no definition here) or the tweak
    /// is listed as coming soon. Defaults are off, so writing false clears the override.
    @discardableResult
    public mutating func setEnabled(_ id: TweakID, _ enabled: Bool) -> Bool {
        guard TweakCatalog.isAvailable(id) else { return false }
        var entry = entries[id.rawValue] ?? Entry()
        entry.enabled = enabled ? true : nil
        store(entry, for: id)
        return true
    }

    public func value(_ option: String, for id: TweakID) -> TweakValue {
        guard let definition = TweakCatalog.definition(for: id).option(option),
              let stored = entries[id.rawValue]?.options[option],
              definition.isValid(stored) else {
            return TweakCatalog.definition(for: id).option(option)?.defaultValue ?? .string("")
        }
        return stored
    }

    public func bool(_ option: String, for id: TweakID) -> Bool { value(option, for: id).boolValue ?? false }
    public func int(_ option: String, for id: TweakID) -> Int { value(option, for: id).intValue ?? 0 }
    public func double(_ option: String, for id: TweakID) -> Double { value(option, for: id).doubleValue ?? 0 }
    public func string(_ option: String, for id: TweakID) -> String { value(option, for: id).stringValue ?? "" }
    public func stringList(_ option: String, for id: TweakID) -> [String] { value(option, for: id).stringListValue ?? [] }

    @discardableResult
    public mutating func setValue(_ option: String, for id: TweakID, to value: TweakValue) -> Bool {
        guard let definition = TweakCatalog.definition(for: id).option(option) else { return false }
        let value = definition.normalized(value)
        guard definition.isValid(value) else { return false }
        var entry = entries[id.rawValue] ?? Entry()
        if value == definition.defaultValue {
            entry.options.removeValue(forKey: option)
        } else {
            entry.options[option] = value
        }
        store(entry, for: id)
        return true
    }

    public mutating func reset(_ id: TweakID? = nil) {
        if let id { entries.removeValue(forKey: id.rawValue) }
        else { entries = [:] }
    }

    private mutating func store(_ entry: Entry, for id: TweakID) {
        if entry.enabled == nil, entry.options.isEmpty { entries.removeValue(forKey: id.rawValue) }
        else { entries[id.rawValue] = entry }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var decoded: [String: Entry] = [:]
        for key in container.allKeys {
            // Each value is read on its own: a null, an object or any other value this build
            // doesn't understand drops only that one key, never the rest of the tweak.
            guard let id = TweakID(rawValue: key.stringValue),
                  let raw = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: key) else { continue }
            var entry = Entry()
            // A tweak that isn't available in this build is never on, whatever the file says.
            if TweakCatalog.isAvailable(id), let flag = AnyKey(stringValue: "enabled"),
               (try? raw.decode(Bool.self, forKey: flag)) == true {
                entry.enabled = true
            }
            for option in TweakCatalog.definition(for: id).options {
                guard let optionKey = AnyKey(stringValue: option.id),
                      let stored = try? raw.decode(TweakValue.self, forKey: optionKey) else { continue }
                let value = option.normalized(stored)
                guard option.isValid(value), value != option.defaultValue else { continue }
                entry.options[option.id] = value
            }
            if entry.enabled != nil || !entry.options.isEmpty { decoded[id.rawValue] = entry }
        }
        entries = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, entry) in entries where TweakID(rawValue: key) != nil {
            var raw: [String: TweakValue] = entry.options
            if let enabled = entry.enabled { raw["enabled"] = .bool(enabled) }
            guard let anyKey = AnyKey(stringValue: key) else { continue }
            try container.encode(raw, forKey: anyKey)
        }
    }
}
