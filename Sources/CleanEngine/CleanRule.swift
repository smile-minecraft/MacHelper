import Foundation

public enum RiskLevel: String, Codable, Sendable, CaseIterable, Comparable {
    /// Regenerated automatically, no user data (caches, logs). Eligible for scheduled cleaning.
    case low
    /// Regenerable but costly, or user-visible (Trash, old downloads, archives).
    case medium
    /// May hold data the user wants (iOS backups, leftovers of removed apps). Never preselected.
    case high

    private var order: Int { [.low: 0, .medium: 1, .high: 2][self]! }
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.order < b.order }
}

public enum CleanAction: String, Codable, Sendable {
    /// Move to the user's Trash (default; recoverable).
    case trash
    /// Delete permanently. Only for rules whose items are already "deleted" (emptying the Trash).
    case delete
}

/// A declarative cleaning rule. Rules only describe *paths*; they can never run commands.
public struct CleanRule: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var description: String
    public var category: String
    public var risk: RiskLevel
    /// Glob patterns (`~` expanded, `*` and `?` per path component). Each match is one removable item.
    public var paths: [String]
    /// Glob patterns of matches to skip.
    public var exclude: [String]
    /// Only items not modified for at least this many days.
    public var minAgeDays: Int
    /// Skip the whole rule while any of these apps (bundle identifiers) is running.
    public var skipIfRunning: [String]
    public var selectedByDefault: Bool
    public var action: CleanAction
    /// Rule needs Full Disk Access to see its paths (shown as a hint in the UI).
    public var needsFullDiskAccess: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, description, category, risk, paths, exclude, minAgeDays, skipIfRunning,
             selectedByDefault, action, needsFullDiskAccess
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = RuleText.localized("rule.\(id).title", try c.decode(String.self, forKey: .title))
        description = RuleText.localized("rule.\(id).description", try c.decodeIfPresent(String.self, forKey: .description) ?? "")
        category = try c.decode(String.self, forKey: .category)
        risk = try c.decode(RiskLevel.self, forKey: .risk)
        paths = try c.decode([String].self, forKey: .paths)
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays) ?? 0
        skipIfRunning = try c.decodeIfPresent([String].self, forKey: .skipIfRunning) ?? []
        selectedByDefault = try c.decodeIfPresent(Bool.self, forKey: .selectedByDefault) ?? (risk == .low)
        action = try c.decodeIfPresent(CleanAction.self, forKey: .action) ?? .trash
        needsFullDiskAccess = try c.decodeIfPresent(Bool.self, forKey: .needsFullDiskAccess) ?? false
    }
}

public struct RuleFile: Codable, Sendable {
    public var schemaVersion: Int
    public var rules: [CleanRule]
}

public enum RuleLoadError: Error, CustomStringConvertible {
    case unsupportedSchema(URL, Int)
    case invalid(URL, String)
    public var description: String {
        switch self {
        case .unsupportedSchema(let u, let v): "\(u.lastPathComponent): unsupported schemaVersion \(v)"
        case .invalid(let u, let m): "\(u.lastPathComponent): \(m)"
        }
    }
}

public enum RuleSet {
    /// Built-in rules, then user rules from `~/Library/Application Support/MacHelper/rules/*.json`.
    /// A user rule with the same id replaces the built-in one.
    public static func load(includeUserRules: Bool = true) throws -> [CleanRule] {
        var rules: [CleanRule] = []
        var urls: [URL] = []
        if let builtin = Bundle.module.url(forResource: "Rules", withExtension: nil) {
            urls += jsonFiles(in: builtin)
        }
        if includeUserRules { urls += jsonFiles(in: MacHelperPaths.userRulesDirectory) }
        for url in urls {
            let file = try decode(url)
            for rule in file.rules {
                if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule } else { rules.append(rule) }
            }
        }
        return rules
    }

    public static func decode(_ url: URL) throws -> RuleFile {
        let file: RuleFile
        do {
            file = try JSONDecoder().decode(RuleFile.self, from: Data(contentsOf: url))
        } catch {
            throw RuleLoadError.invalid(url, String(describing: error))
        }
        guard file.schemaVersion == 1 else { throw RuleLoadError.unsupportedSchema(url, file.schemaVersion) }
        for r in file.rules where r.paths.isEmpty { throw RuleLoadError.invalid(url, "rule \(r.id) has no paths") }
        return file
    }

    private static func jsonFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

public enum MacHelperPaths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    public static let supportDirectory = home.appending(path: "Library/Application Support/MacHelper")
    public static let userRulesDirectory = supportDirectory.appending(path: "rules")
    public static let whitelistFile = supportDirectory.appending(path: "clean-whitelist.txt")
    public static let purgePathsFile = supportDirectory.appending(path: "purge-paths.txt")
    public static let logDirectory = home.appending(path: "Library/Logs/MacHelper")
    public static let operationLog = logDirectory.appending(path: "operations.jsonl")
}

/// Translations of built-in rule text live in Rules.xcstrings, keyed by rule ID; rules without a
/// translation (including user rules) show the text from their JSON file.
enum RuleText {
    static func localized(_ key: String, _ fallback: String) -> String {
        guard !fallback.isEmpty else { return fallback }
        return Bundle.module.localizedString(forKey: key, value: fallback, table: "Rules")
    }
}
