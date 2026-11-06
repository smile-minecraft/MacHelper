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
    /// Maintenance task ids to run with each clean, from `AutoClean.maintenanceTaskIDs`. Optional so
    /// older config files still decode; nil means all of them.
    public var maintenanceTasks: [String]?
    public var lastRun: Date?
    public var lastTrashedBytes: UInt64 = 0
    public var lastFreedBytes: UInt64 = 0
    public var lastItemCount = 0
    public var lastError: String?
    /// Maintenance tasks from the last run. Optional for older config files.
    public var lastTasks: [TaskOutcome]?

    public init() {}

    /// The maintenance tasks this config runs, in catalog order, limited to the allowlist.
    public var enabledMaintenanceTasks: [String] {
        let chosen = Set(maintenanceTasks ?? AutoClean.maintenanceTaskIDs)
        return AutoClean.maintenanceTaskIDs.filter(chosen.contains)
    }

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

    /// Maintenance tasks scheduled cleaning may run: low risk, user level, safe to repeat, and
    /// nothing lost that the system doesn't rebuild. Anything else needs a person to choose it.
    public static let maintenanceTaskIDs = ["quicklook.reset", "simulators.unavailable"]

    /// The tasks a run would execute: enabled in the config, in the catalog, still user-level and
    /// low risk (re-checked here so a catalog change can't widen what runs unattended).
    public static func maintenanceTasks(for config: AutoCleanConfig, catalog: [MaintenanceTask] = MaintenanceCatalog.all) -> [MaintenanceTask] {
        config.enabledMaintenanceTasks.compactMap { id in
            catalog.first { $0.id == id && !$0.requiresRoot && $0.risk <= maxRisk }
        }
    }

    /// Runs one scheduled clean: low-risk rules, default selection, running apps skipped; then
    /// the enabled maintenance tasks. Tasks not available on this Mac are skipped, not failed.
    public static func run(config: AutoCleanConfig, rules: [CleanRule],
                           runTask: (MaintenanceTask) -> TaskOutcome = { MaintenanceRunner().run($0, dryRun: false, command: "autoclean") })
        -> (CleanPlan, CleanReport, [TaskOutcome]) {
        let eligible = rules.filter { $0.risk <= maxRisk && $0.selectedByDefault }
        let plan = CleanScanner(rules: eligible).scan()
        let report = CleanExecutor(safety: .forCleaning(), permanent: config.permanent, alwaysTrash: config.trashInstead == true)
            .execute(plan.removalItems, dryRun: false, command: "autoclean")
        return (plan, report, runMaintenance(config: config, runTask: runTask))
    }

    public static func runMaintenance(config: AutoCleanConfig, catalog: [MaintenanceTask] = MaintenanceCatalog.all,
                                      isAvailable: (MaintenanceTask) -> Bool = { $0.isAvailable },
                                      runTask: (MaintenanceTask) -> TaskOutcome) -> [TaskOutcome] {
        maintenanceTasks(for: config, catalog: catalog).filter(isAvailable).map(runTask)
    }

    /// Records a finished run into the config.
    public static func record(_ report: CleanReport, tasks: [TaskOutcome] = [], into config: inout AutoCleanConfig, at date: Date = Date()) {
        config.lastRun = date
        config.lastTrashedBytes = report.trashedBytes
        config.lastFreedBytes = report.freedBytes
        config.lastItemCount = report.items.filter { $0.result == .trashed || $0.result == .deleted }.count
        config.lastTasks = tasks
        var errors: [String] = []
        if !report.failures.isEmpty {
            errors.append(String(localized: "\(report.failures.count) items not processed: \(report.failures.first?.message ?? "")", bundle: .module))
        }
        let failedTasks = tasks.filter { !$0.ok }
        if !failedTasks.isEmpty {
            errors.append(String(localized: "Maintenance failed: \(failedTasks.map(\.id).joined(separator: ", "))", bundle: .module))
        }
        config.lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}
