import CleanEngine
import Foundation

/// Custom cleaning rules, in the same shape as the files under
/// `~/Library/Application Support/MacHelper/rules/`.
///
/// Importing can never make a rule part of a later clean without the user picking it: every rule is
/// written with `selectedByDefault` off, whatever the file says. The rest of the safety net (the
/// protected-path list and the cleaning preview) stays in place because the imported rules go
/// through the same loader as user-written ones.
public struct CleanRulesPayload: Codable, Sendable {
    /// The rule format the app's loader accepts.
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var rules: [CleanRule]

    public init(schemaVersion: Int = Self.supportedSchemaVersion, rules: [CleanRule]) {
        self.schemaVersion = schemaVersion
        self.rules = rules
    }

    /// Decodes and validates a rules payload. Paths must be absolute patterns after `~` expansion,
    /// ids and path lists must be present, and every rule comes back deselected.
    public static func validated(_ data: Data) -> SectionValidation {
        let incoming: CleanRulesPayload
        do {
            incoming = try JSONDecoder().decode(CleanRulesPayload.self, from: data)
        } catch {
            return .invalid(String(describing: error))
        }
        guard incoming.schemaVersion == supportedSchemaVersion else {
            return .invalid("Rules use schemaVersion \(incoming.schemaVersion); this version reads \(supportedSchemaVersion).")
        }
        for rule in incoming.rules {
            if rule.id.isEmpty { return .invalid("A rule is missing an id.") }
            if rule.paths.isEmpty { return .invalid("Rule '\(rule.id)' has no paths.") }
            for pattern in rule.paths + rule.exclude {
                guard (pattern as NSString).expandingTildeInPath.hasPrefix("/") else {
                    return .invalid("Rule '\(rule.id)' has '\(pattern)', which is not an absolute path after expanding ~.")
                }
            }
        }
        // Whatever the file says, a rule that arrived by import is never preselected into a later
        // clean; the user picks it first.
        let rules = incoming.rules.map { rule -> CleanRule in
            var rule = rule
            rule.selectedByDefault = false
            return rule
        }
        let canonical = CleanRulesPayload(schemaVersion: incoming.schemaVersion, rules: rules)
        let bytes: Data
        do { bytes = try CanonicalJSON.encode(canonical) }
        catch { return .invalid(String(describing: error)) }
        let permanent = rules.filter { $0.action == .delete }.count
        let summary = "\(rules.count) rules, \(permanent) delete permanently"
        let details = rules.map { "\($0.title): \($0.paths.joined(separator: ", "))" }
        return .valid(SettingsPayload(data: bytes, summary: summary, details: details))
    }
}
