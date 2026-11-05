import Foundation

/// A portable settings file: one JSON document with a version, where it came from, and one encoded
/// payload per settings category. History, caches and logs are deliberately never part of it.
public struct SettingsArchive: Codable, Equatable, Sendable {
    /// Increment when the container or any payload format changes in a way older readers cannot
    /// interpret. A reader accepts everything up to its own version.
    public static let currentSchemaVersion = 1

    /// Identifies the file so an unrelated JSON document is not mistaken for settings.
    public static let formatIdentifier = "com.machelper.settings"

    /// Data that is deliberately left out. Written into every file so a reader can see what it holds.
    public static let defaultExcludedContents = [
        "history", "scanCache", "operationLog", "backgroundRecording", "helperRegistration",
    ]

    public var format: String
    public var schemaVersion: Int
    /// `CFBundleShortVersionString` of the exporting app.
    public var appVersion: String
    /// Hardware model identifier of the exporting Mac, for display and diagnostics. Settings stay
    /// portable between models; a category that depends on hardware checks itself on import.
    public var machineIdentifier: String
    public var exportedAt: Date
    public var excludedContents: [String]
    /// Category key → canonical payload. The payload format belongs to the category.
    public var sections: [String: Data]

    public init(format: String = Self.formatIdentifier,
                schemaVersion: Int = Self.currentSchemaVersion,
                appVersion: String,
                machineIdentifier: String,
                exportedAt: Date,
                excludedContents: [String] = Self.defaultExcludedContents,
                sections: [String: Data]) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.machineIdentifier = machineIdentifier
        self.exportedAt = exportedAt
        self.excludedContents = excludedContents
        self.sections = sections
    }

    /// The two fields every version of the container keeps in the same place. A newer writer may
    /// reshape everything else, so the rest is decoded only after the version check passes.
    private struct Envelope: Decodable {
        var format: String
        var schemaVersion: Int
    }

    /// Decodes and checks the container. Payloads are validated by their category.
    public static func decode(_ data: Data) throws -> SettingsArchive {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw SettingsArchiveError.unreadableArchive(String(describing: error))
        }
        guard envelope.format == formatIdentifier else {
            throw SettingsArchiveError.unreadableArchive("format is \(envelope.format), expected \(formatIdentifier)")
        }
        guard envelope.schemaVersion >= 1 else {
            throw SettingsArchiveError.unreadableArchive(
                "schemaVersion \(envelope.schemaVersion) is not 1…\(currentSchemaVersion)")
        }
        guard envelope.schemaVersion <= currentSchemaVersion else {
            throw SettingsArchiveError.unsupportedVersion(envelope.schemaVersion)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SettingsArchive.self, from: data)
        } catch {
            throw SettingsArchiveError.unreadableArchive(String(describing: error))
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public enum SettingsArchiveError: Error, Equatable, CustomStringConvertible {
    /// The bytes are not a settings file this version can read.
    case unreadableArchive(String)
    /// The file was written by a newer version of the app.
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .unreadableArchive(let detail):
            "Not a MacHelper settings file: \(detail)"
        case .unsupportedVersion(let version):
            "The file uses settings format \(version); this version reads up to \(SettingsArchive.currentSchemaVersion)."
        }
    }
}

/// Stable keys for the categories that can travel in an archive.
public enum SettingsCategory: String, CaseIterable, Sendable {
    case general
    case monitor
    case alerts
    case fans
    case cleanRules
    case cleanWhitelist
    case cleanPurgePaths
    case optimizeRoots
}
