import Foundation

/// Builds a portable file from the categories the user selected.
public struct SettingsExporter: Sendable {
    public var appVersion: String
    public var machineIdentifier: String
    /// Injectable clock so tests get a fixed date.
    public var now: @Sendable () -> Date

    public init(appVersion: String, machineIdentifier: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.appVersion = appVersion
        self.machineIdentifier = machineIdentifier
        self.now = now
    }

    /// Encodes the selected categories. Selection is by `SettingsSection.id`; ids that match no
    /// section are ignored, and categories keep their payload bytes unchanged.
    public func export(_ ids: [String], from sections: [any SettingsSection]) throws -> Data {
        let byID = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        var payloadByCategory: [String: Data] = [:]
        for id in ids {
            if let section = byID[id] { payloadByCategory[id] = try section.snapshot() }
        }
        return try SettingsArchive(appVersion: appVersion, machineIdentifier: machineIdentifier,
                                   exportedAt: now(), sections: payloadByCategory).encoded()
    }
}
