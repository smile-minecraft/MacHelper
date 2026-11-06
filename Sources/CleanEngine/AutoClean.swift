import Foundation

/// Scheduled low-risk cleaning. The app edits this config and registers a LaunchAgent that runs
/// `machelper autoclean --run-if-due` hourly; the CLI decides whether a run is due and records the result.
public struct AutoCleanConfig: Codable, Sendable, Equatable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily, weekly

        /// Slightly less than the nominal period, so an hourly check never drifts a whole day.
        public var interval: TimeInterval {
            switch self {
            case .daily: 23 * 3600
            case .weekly: 7 * 86_400 - 3600
            }
        }
    }

    public var enabled = false
    public var frequency: Frequency = .weekly
    /// Delete permanently instead of moving to the Trash. Off by default. Kept for older config
    /// files; since low-risk rules delete by default it only matters for rules that say "trash".
    public var permanent = false
    /// Move everything to the Trash instead of following each rule's action. Optional so config
    /// files written before it existed still decode; nil means off.
    public var trashInstead: Bool?
    public var lastRun: Date?
    public var lastTrashedBytes: UInt64 = 0
    public var lastFreedBytes: UInt64 = 0
    public var lastItemCount = 0
    public var lastError: String?

    public init() {}

    public func isDue(now: Date = Date()) -> Bool {
        guard enabled else { return false }
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= frequency.interval
    }

    public var nextRun: Date? {
        guard enabled else { return nil }
        return (lastRun ?? Date()).addingTimeInterval(lastRun == nil ? 0 : frequency.interval)
    }
}

public enum AutoClean {
    public static let configURL = MacHelperPaths.supportDirectory.appending(path: "autoclean.json")
    /// The only risk level scheduled cleaning ever touches.
    public static let maxRisk: RiskLevel = .low

    public static func load(from url: URL = configURL) -> AutoCleanConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let c = try? decoder.decode(AutoCleanConfig.self, from: data) else {
            return AutoCleanConfig()
        }
        return c
    }

    public static func save(_ config: AutoCleanConfig, to url: URL = configURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    /// Runs one scheduled clean: low-risk rules, default selection, running apps skipped.
    public static func run(config: AutoCleanConfig, rules: [CleanRule]) -> (CleanPlan, CleanReport) {
        let eligible = rules.filter { $0.risk <= maxRisk && $0.selectedByDefault }
        let plan = CleanScanner(rules: eligible).scan()
        let report = CleanExecutor(safety: .forCleaning(), permanent: config.permanent, alwaysTrash: config.trashInstead == true)
            .execute(plan.removalItems, dryRun: false, command: "autoclean")
        return (plan, report)
    }

    /// Records a finished run into the config.
    public static func record(_ report: CleanReport, into config: inout AutoCleanConfig, at date: Date = Date()) {
        config.lastRun = date
        config.lastTrashedBytes = report.trashedBytes
        config.lastFreedBytes = report.freedBytes
        config.lastItemCount = report.items.filter { $0.result == .trashed || $0.result == .deleted }.count
        config.lastError = report.failures.isEmpty ? nil : String(localized: "\(report.failures.count) items not processed: \(report.failures.first?.message ?? "")", bundle: .module)
    }
}
