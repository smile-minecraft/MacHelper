import CleanEngine
import FanControl
import Foundation
import HelperProtocol
import SettingsPortability

/// Whether the Helper can actually drive this Mac's fans. A Mac can report fan speeds while the
/// Helper cannot control them, so a non-empty fan list alone is not enough.
func canControlFans(_ status: FanControlStatus?) -> Bool {
    status?.canControl == true
}

/// Canonical payload bytes for the categories the app owns. Validation returns the same bytes, so
/// re-importing an unchanged file reports "no change".
enum SettingsBackupJSON {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

struct SettingsBackupError: LocalizedError, CustomStringConvertible {
    let message: String
    var errorDescription: String? { message }
    var description: String { message }
}

struct GeneralSettingsPayload: Codable, Equatable {
    var showInDock: Bool
    var language: String?
}

/// Dock and app language. "Open at login" registers a login item, so it stays out of the file.
struct GeneralSettingsSection: SettingsSection {
    var defaults: UserDefaults = .standard
    var domainName: String? = Bundle.main.bundleIdentifier

    var id: String { SettingsCategory.general.rawValue }

    static func currentLanguage(defaults: UserDefaults = .standard,
                                domainName: String? = Bundle.main.bundleIdentifier) -> String? {
        let domain = domainName.flatMap { defaults.persistentDomain(forName: $0) }
        guard let first = (domain?["AppleLanguages"] as? [String])?.first else { return nil }
        return AppLanguage.match(first)
    }

    private var payload: GeneralSettingsPayload {
        GeneralSettingsPayload(showInDock: defaults.object(forKey: "showInDock") as? Bool ?? true,
                               language: Self.currentLanguage(defaults: defaults, domainName: domainName))
    }

    func snapshot() throws -> Data {
        try SettingsBackupJSON.encode(payload)
    }

    func validate(_ data: Data) -> SectionValidation {
        let incoming: GeneralSettingsPayload
        do { incoming = try SettingsBackupJSON.decode(GeneralSettingsPayload.self, from: data) }
        catch { return .invalid(String(describing: error)) }

        if let language = incoming.language, !AppLanguage.codes.contains(language) {
            return .invalid(String(localized: "The language must be one of \(AppLanguage.codes.joined(separator: ", ")), or null."))
        }
        do {
            return .valid(SettingsPayload(data: try SettingsBackupJSON.encode(incoming),
                                          summary: String(localized: "Dock and language settings")))
        } catch {
            return .invalid(String(describing: error))
        }
    }

    func apply(_ data: Data) throws {
        let payload = try SettingsBackupJSON.decode(GeneralSettingsPayload.self, from: data)
        defaults.set(payload.showInDock, forKey: "showInDock")
        if let language = payload.language {
            defaults.set([language], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    func restore(_ snapshot: Data) throws {
        try apply(snapshot)
    }
}

/// Portable menu bar layout. Module names are string keys so the payload bytes are stable; the
/// stored preference keeps its own dictionary encoding.
struct MonitorSettingsPayload: Codable, Equatable {
    var compact: Bool
    var modules: [String: ModuleConfig]

    init(configuration: MonitorConfiguration) {
        compact = configuration.compact
        modules = Dictionary(uniqueKeysWithValues: MonitorModule.allCases.map {
            ($0.rawValue, configuration.config($0))
        })
    }

    func configuration() -> MonitorConfiguration? {
        var byModule: [MonitorModule: ModuleConfig] = [:]
        for (key, config) in modules {
            guard let module = MonitorModule(rawValue: key) else { return nil }
            byModule[module] = config
        }
        for module in MonitorModule.allCases where byModule[module] == nil {
            byModule[module] = MonitorConfiguration.default.config(module)
        }
        return MonitorConfiguration(modules: byModule, compact: compact)
    }
}

/// Menu bar modules, styles and sampling intervals.
struct MonitorSettingsSection: SettingsSection {
    var defaults: UserDefaults = .standard

    var id: String { SettingsCategory.monitor.rawValue }

    private static let intervals: Set<Double> = [1, 2, 5, 10, 30]

    private var current: MonitorConfiguration {
        guard let data = defaults.data(forKey: MonitorSettingsStore.key),
              let saved = try? JSONDecoder().decode(MonitorConfiguration.self, from: data)
        else { return .default }
        return saved
    }

    func snapshot() throws -> Data {
        try SettingsBackupJSON.encode(MonitorSettingsPayload(configuration: current))
    }

    func validate(_ data: Data) -> SectionValidation {
        let payload: MonitorSettingsPayload
        do { payload = try SettingsBackupJSON.decode(MonitorSettingsPayload.self, from: data) }
        catch { return .invalid(String(describing: error)) }

        guard let config = payload.configuration() else {
            return .invalid(String(localized: "The file contains an unknown menu bar module."))
        }
        for module in MonitorModule.allCases where !Self.intervals.contains(config.config(module).interval) {
            return .invalid(String(localized: "The menu bar interval must be 1, 2, 5, 10, or 30 seconds."))
        }
        do {
            // Missing modules get their defaults, so the payload written by apply carries the
            // same complete set that the next snapshot returns.
            let normalized = MonitorSettingsPayload(configuration: config)
            return .valid(SettingsPayload(data: try SettingsBackupJSON.encode(normalized),
                                          summary: String(localized: "Menu bar modules and update intervals")))
        } catch {
            return .invalid(String(describing: error))
        }
    }

    func apply(_ data: Data) throws {
        let payload = try SettingsBackupJSON.decode(MonitorSettingsPayload.self, from: data)
        guard let config = payload.configuration() else {
            throw SettingsBackupError(message: String(localized: "The file contains an unknown menu bar module."))
        }
        defaults.set(try JSONEncoder().encode(config), forKey: MonitorSettingsStore.key)
    }

    func restore(_ snapshot: Data) throws {
        try apply(snapshot)
    }
}

/// Notification thresholds. Temperature and free-space limits match the alert controls.
struct AlertsSettingsSection: SettingsSection {
    var defaults: UserDefaults = .standard

    var id: String { SettingsCategory.alerts.rawValue }

    private var current: AlertSettings {
        defaults.data(forKey: AlertCenter.key)
            .flatMap { try? JSONDecoder().decode(AlertSettings.self, from: $0) } ?? AlertSettings()
    }

    func snapshot() throws -> Data {
        try SettingsBackupJSON.encode(current)
    }

    func validate(_ data: Data) -> SectionValidation {
        let settings: AlertSettings
        do { settings = try SettingsBackupJSON.decode(AlertSettings.self, from: data) }
        catch { return .invalid(String(describing: error)) }

        guard settings.temperatureCelsius.isFinite, (70...105).contains(settings.temperatureCelsius) else {
            return .invalid(String(localized: "The temperature threshold must be between 70 and 105 °C."))
        }
        guard settings.diskFreeGB.isFinite, (5...200).contains(settings.diskFreeGB) else {
            return .invalid(String(localized: "The disk threshold must be between 5 and 200 GB."))
        }
        guard settings.cooldownMinutes.isFinite, settings.cooldownMinutes > 0 else {
            return .invalid(String(localized: "The cooldown must be a positive number."))
        }
        do {
            return .valid(SettingsPayload(data: try SettingsBackupJSON.encode(settings),
                                          summary: String(localized: "Alert thresholds and cooldown")))
        } catch {
            return .invalid(String(describing: error))
        }
    }

    func apply(_ data: Data) throws {
        defaults.set(data, forKey: AlertCenter.key)
    }

    func restore(_ snapshot: Data) throws {
        try apply(snapshot)
    }
}

/// The app-side fan preferences only: automatic switching rules, the base policy and the saved
/// custom curve. The Helper's own policy file is never part of the archive.
struct FansSettingsSection: SettingsSection {
    var defaults: UserDefaults = .standard
    var hasFans: Bool

    var id: String { SettingsCategory.fans.rawValue }

    private var current: FanSettingsPayload {
        FanSettingsPayload(
            autoEnabled: defaults.bool(forKey: FanAutoSwitcher.enabledKey),
            autoRules: defaults.data(forKey: FanAutoSwitcher.rulesKey)
                .flatMap { try? JSONDecoder().decode([FanAutoRule].self, from: $0) } ?? [],
            basePolicy: defaults.data(forKey: FanAutoSwitcher.baseKey)
                .flatMap { try? JSONDecoder().decode(FanPolicy.self, from: $0) } ?? .automatic,
            customCurve: defaults.data(forKey: FanControlModel.customCurveKey)
                .flatMap { try? JSONDecoder().decode([FanCurve.Point].self, from: $0) }
        )
    }

    func snapshot() throws -> Data {
        let encoded = try SettingsBackupJSON.encode(current)
        // Normalising through the same validation guarantees that a repeat import is unchanged.
        switch FanSettingsPayload.validated(encoded, hasFans: true) {
        case .valid(let payload):
            return payload.data
        case .invalid(let reason), .incompatible(let reason):
            throw SettingsBackupError(message: reason)
        }
    }

    func validate(_ data: Data) -> SectionValidation {
        switch FanSettingsPayload.validated(data, hasFans: hasFans) {
        case .valid(let payload):
            return .valid(SettingsPayload(data: payload.data,
                                          summary: String(localized: "Fan profiles and curve")))
        case .invalid(let reason):
            return .invalid(reason)
        case .incompatible(let reason):
            return .incompatible(reason)
        }
    }

    func apply(_ data: Data) throws {
        let payload = try SettingsBackupJSON.decode(FanSettingsPayload.self, from: data)
        defaults.set(payload.autoEnabled, forKey: FanAutoSwitcher.enabledKey)
        defaults.set(try SettingsBackupJSON.encode(payload.autoRules), forKey: FanAutoSwitcher.rulesKey)
        defaults.set(try SettingsBackupJSON.encode(payload.basePolicy), forKey: FanAutoSwitcher.baseKey)
        if let curve = payload.customCurve {
            defaults.set(try SettingsBackupJSON.encode(curve), forKey: FanControlModel.customCurveKey)
        } else {
            defaults.removeObject(forKey: FanControlModel.customCurveKey)
        }
    }

    func restore(_ snapshot: Data) throws {
        try apply(snapshot)
    }
}

/// User rules from `rules/*.json`, merged by id in file-name order like `RuleSet.load`.
struct CleanRulesSettingsSection: SettingsSection {
    var supportDirectory: URL = MacHelperPaths.supportDirectory

    var id: String { SettingsCategory.cleanRules.rawValue }

    private var rulesDirectory: URL {
        supportDirectory.appending(path: "rules")
    }

    private func ruleFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: rulesDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: rulesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func mergedRules() throws -> [CleanRule] {
        var rules: [CleanRule] = []
        for url in try ruleFiles() {
            let file = try RuleSet.decode(url)
            for rule in file.rules {
                if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                    rules[index] = rule
                } else {
                    rules.append(rule)
                }
            }
        }
        return rules
    }

    private var importedRulesURL: URL {
        rulesDirectory.appending(path: "imported-rules.json")
    }

    /// Writes the merged value the app loads from the rules directory. Both a normal import and the
    /// rollback of a failed import end up here, so the write lives in one place.
    private func writeImportedRules(_ payload: CleanRulesPayload) throws {
        try FileManager.default.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
        try SettingsBackupJSON.encode(payload).write(to: importedRulesURL, options: .atomic)
    }

    /// Moves every rule file except the merged import file to the Trash. `RuleSet.load` merges files
    /// in name order, so a file left behind can override the restored rules; a failure has to reach
    /// the importer instead of leaving that change in place.
    private func trashOtherRuleFiles() throws {
        for url in try ruleFiles() where url.lastPathComponent != importedRulesURL.lastPathComponent {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// A rule that arrives by import is never preselected by the file. It keeps a selection only
    /// when this Mac already has the identical rule and the user had it preselected here.
    private func keepingLocalSelection(_ rules: [CleanRule]) -> [CleanRule] {
        let local = Dictionary(((try? mergedRules()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        return rules.map { rule in
            var incoming = rule
            incoming.selectedByDefault = false
            guard var existing = local[rule.id], existing.selectedByDefault else { return incoming }
            existing.selectedByDefault = false
            if existing == incoming { incoming.selectedByDefault = true }
            return incoming
        }
    }

    func snapshot() throws -> Data {
        let encoded: Data
        do {
            // A snapshot must reproduce the current selection on rollback, so it keeps each rule's
            // own `selectedByDefault` instead of normalising it like an imported file.
            encoded = try SettingsBackupJSON.encode(CleanRulesPayload(rules: try mergedRules()))
        } catch {
            throw SettingsBackupError(message: String(
                format: String(localized: "Couldn’t read the custom rules: %@"), String(describing: error)))
        }
        // `RuleSet.decode` accepts a file that the import validator rejects (a relative path or an
        // empty id). Exporting it would produce a backup that can never be imported again, so the
        // snapshot fails where the user can still fix the rule file.
        switch CleanRulesPayload.validated(encoded) {
        case .valid:
            // Validation normalises every rule to unselected; the snapshot keeps the original bytes
            // so a rollback brings back the selection the app was using.
            return encoded
        case .invalid(let reason), .incompatible(let reason):
            throw SettingsBackupError(message: String(
                format: String(localized: "The current value is invalid: %@"), reason))
        }
    }

    func validate(_ data: Data) -> SectionValidation {
        switch CleanRulesPayload.validated(data) {
        case .valid(let payload):
            var data = payload.data
            if let decoded = try? JSONDecoder().decode(CleanRulesPayload.self, from: payload.data) {
                var ids = Set<String>()
                if decoded.rules.contains(where: { !ids.insert($0.id).inserted }) {
                    return .invalid(String(localized: "The rules file contains duplicate rule ids."))
                }
                // Carry over this Mac's own selection for rules that are already here unchanged,
                // so an unchanged backup compares equal to the snapshot and a round trip keeps
                // the selection.
                let merged = CleanRulesPayload(schemaVersion: decoded.schemaVersion,
                                               rules: keepingLocalSelection(decoded.rules))
                if let encoded = try? SettingsBackupJSON.encode(merged) { data = encoded }
            }
            return .valid(SettingsPayload(data: data,
                                          summary: payload.summary,
                                          details: payload.details))
        case .invalid(let reason):
            return .invalid(reason)
        case .incompatible(let reason):
            return .incompatible(reason)
        }
    }

    func apply(_ data: Data) throws {
        let payload = try SettingsBackupJSON.decode(CleanRulesPayload.self, from: data)
        let rules = keepingLocalSelection(payload.rules)
        try writeImportedRules(CleanRulesPayload(schemaVersion: payload.schemaVersion, rules: rules))
        try trashOtherRuleFiles()
    }

    func restore(_ snapshot: Data) throws {
        // The snapshot already contains the merged state, so writing it back as the imported file
        // restores the values. Other rule files must go too: `RuleSet.load` merges by file name, so
        // a file that stayed behind could come before `imported-rules.json` and change which rule
        // wins for overlapping paths.
        try writeImportedRules(try SettingsBackupJSON.decode(CleanRulesPayload.self, from: snapshot))
        try trashOtherRuleFiles()
    }
}

/// One absolute-path list stored as a text file: the cleaning whitelist and the extra purge roots.
struct PathListSettingsSection: SettingsSection {
    let id: String
    let fileURL: URL
    let summary: String

    private func readPaths() throws -> [String] {
        let data: Data
        if FileManager.default.fileExists(atPath: fileURL.path) {
            data = try Data(contentsOf: fileURL)
        } else {
            data = Data()
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SettingsBackupError(message: String(
                format: String(localized: "Couldn’t read %@."), fileURL.lastPathComponent))
        }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func snapshot() throws -> Data {
        let encoded = try SettingsBackupJSON.encode(PathListPayload(paths: try readPaths()))
        switch PathListPayload.validated(encoded) {
        case .valid(let payload):
            return payload.data
        case .invalid(let reason), .incompatible(let reason):
            throw SettingsBackupError(message: String(
                format: String(localized: "The current value is invalid: %@"), reason))
        }
    }

    func validate(_ data: Data) -> SectionValidation {
        switch PathListPayload.validated(data) {
        case .valid(let payload):
            return .valid(SettingsPayload(data: payload.data, summary: summary))
        case .invalid(let reason):
            return .invalid(reason)
        case .incompatible(let reason):
            return .incompatible(reason)
        }
    }

    func apply(_ data: Data) throws {
        let payload = try SettingsBackupJSON.decode(PathListPayload.self, from: data)
        let text = payload.paths.map { $0 + "\n" }.joined()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL, options: .atomic)
    }

    func restore(_ snapshot: Data) throws {
        try apply(snapshot)
    }
}

/// Folders scanned for rebuildable artifacts in Optimize.
struct OptimizeRootsSettingsSection: SettingsSection {
    var defaults: UserDefaults = .standard
    var defaultRoots: () -> [String] = { ArtifactScanner.defaultRoots() }

    var id: String { SettingsCategory.optimizeRoots.rawValue }

    private var current: [String] {
        defaults.stringArray(forKey: OptimizeModel.rootsKey) ?? defaultRoots()
    }

    func snapshot() throws -> Data {
        let encoded = try SettingsBackupJSON.encode(PathListPayload(paths: current))
        switch PathListPayload.validated(encoded) {
        case .valid(let payload):
            return payload.data
        case .invalid(let reason), .incompatible(let reason):
            throw SettingsBackupError(message: String(
                format: String(localized: "The current value is invalid: %@"), reason))
        }
    }

    func validate(_ data: Data) -> SectionValidation {
        switch PathListPayload.validated(data) {
        case .valid(let payload):
            return .valid(SettingsPayload(data: payload.data,
                                          summary: String(localized: "Optimize Scan Folders")))
        case .invalid(let reason):
            return .invalid(reason)
        case .incompatible(let reason):
            return .incompatible(reason)
        }
    }

    func apply(_ data: Data) throws {
        let payload = try SettingsBackupJSON.decode(PathListPayload.self, from: data)
        defaults.set(payload.paths, forKey: OptimizeModel.rootsKey)
    }

    func restore(_ snapshot: Data) throws {
        try apply(snapshot)
    }
}

enum SettingsBackupSections {
    static func all(defaults: UserDefaults = .standard,
                    domainName: String? = Bundle.main.bundleIdentifier,
                    supportDirectory: URL = MacHelperPaths.supportDirectory,
                    hasFans: Bool,
                    defaultRoots: @escaping () -> [String] = { ArtifactScanner.defaultRoots() }) -> [any SettingsSection] {
        [
            GeneralSettingsSection(defaults: defaults, domainName: domainName),
            MonitorSettingsSection(defaults: defaults),
            AlertsSettingsSection(defaults: defaults),
            FansSettingsSection(defaults: defaults, hasFans: hasFans),
            CleanRulesSettingsSection(supportDirectory: supportDirectory),
            PathListSettingsSection(id: SettingsCategory.cleanWhitelist.rawValue,
                                    fileURL: supportDirectory.appending(path: "clean-whitelist.txt"),
                                    summary: String(localized: "Cleaning Whitelist")),
            PathListSettingsSection(id: SettingsCategory.cleanPurgePaths.rawValue,
                                    fileURL: supportDirectory.appending(path: "purge-paths.txt"),
                                    summary: String(localized: "Extra Purge Folders")),
            OptimizeRootsSettingsSection(defaults: defaults, defaultRoots: defaultRoots),
        ]
    }
}
