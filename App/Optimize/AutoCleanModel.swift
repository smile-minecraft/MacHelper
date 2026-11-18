import CleanEngine
import Foundation
import Observation
import ServiceManagement

/// Auto clean settings. The schedule runs as a user LaunchAgent (registered here through SMAppService)
/// that calls the embedded CLI every 30 minutes; the CLI runs only when enabled and due, so the app need not be open.
/// Existing installs get the new trigger through `AutoCleanScheduleMigration` — one explicit,
/// visible, retryable re-registration; never a best-effort `try?` on every refresh.
@MainActor
@Observable
final class AutoCleanModel {
    private(set) var config: AutoCleanConfig
    private(set) var agentStatus: AutoCleanAgentStatus = .notRegistered
    private(set) var message: String?
    /// Reason an existing-agent schedule migration failed, when it did. Written, cleared or
    /// retried only through `refreshScheduleMigration()`; shown in Settings with a Retry action.
    private(set) var scheduleMigrationError: String?
    private(set) var isRunning = false
    @ObservationIgnored private let agent: any AutoCleanAgentServicing
    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var isUpdatingSchedule = false
    @ObservationIgnored private var pendingEnabledChange = false

    convenience init() {
        self.init(agent: SMAppServiceAgentServicing(), configURL: AutoClean.configURL, defaults: .standard)
        refresh()
    }

    init(agent: any AutoCleanAgentServicing, configURL: URL, defaults: UserDefaults) {
        self.agent = agent
        self.configURL = configURL
        self.defaults = defaults
        self.config = AutoClean.load(from: configURL)
        self.agentStatus = agent.status
    }

    func refresh() {
        if !isUpdatingSchedule {
            config = AutoClean.load(from: configURL)
            agentStatus = agent.status
        }
        let tasks = maintenanceRows.map(\.task)
        Task {
            let availability = await Task.detached(priority: .utility) { tasks.map(\.isAvailable) }.value
            maintenanceRows = zip(tasks, availability).map { ($0, $1) }
        }
        Task { await refreshScheduleMigration() }
    }

    func refreshScheduleMigration() async {
        guard !isUpdatingSchedule, !pendingEnabledChange, config.enabled else { return }
        isUpdatingSchedule = true
        let outcome = await AutoCleanScheduleMigration.runIfNeeded(servicing: agent, defaults: defaults) {
            self.config.enabled && !self.pendingEnabledChange
        }
        if case .failed(let error) = outcome { scheduleMigrationError = error }
        else { scheduleMigrationError = nil }
        await finishScheduleOperation()
    }

    func retryScheduleMigration() {
        Task { await refreshScheduleMigration() }
    }

    var enabled: Bool {
        get { config.enabled }
        set {
            guard newValue != config.enabled else { return }
            config.enabled = newValue
            guard save() else {
                config.enabled = !newValue
                return
            }
            if !newValue {
                AutoCleanScheduleMigration.cancel(defaults: defaults)
                scheduleMigrationError = nil
            }
            pendingEnabledChange = true
            Task { await applyEnabledChange() }
        }
    }

    var frequency: AutoCleanConfig.Frequency {
        get { config.frequency }
        set {
            config.frequency = newValue
            save()
            // Picking a frequency is exactly when a missing schedule migration matters; the
            // migrator no-ops (zero agent calls) when the registered agent is current.
            Task { await refreshScheduleMigration() }
        }
    }

    var trashInstead: Bool {
        get { config.trashInstead == true }
        set { config.trashInstead = newValue; save() }
    }

    var tempClean: Bool {
        get { config.tempClean == true }
        set { config.tempClean = newValue ? true : nil; save() }
    }

    /// Safe maintenance tasks Auto Clean may run, with whether each applies on this Mac
    /// (checked off the main thread in `refresh()`; the probes start processes).
    private(set) var maintenanceRows: [(task: MaintenanceTask, available: Bool)] = AutoClean.maintenanceTaskIDs.compactMap { id in
        MaintenanceCatalog.all.first { $0.id == id }.map { ($0, true) }
    }

    func isMaintenanceEnabled(_ id: String) -> Bool { config.enabledMaintenanceTasks.contains(id) }

    func setMaintenance(_ id: String, enabled: Bool) {
        var set = Set(config.enabledMaintenanceTasks)
        if enabled { set.insert(id) } else { set.remove(id) }
        config.maintenanceTasks = AutoClean.maintenanceTaskIDs.filter(set.contains)
        save()
    }

    func title(forTask id: String) -> String {
        if id == ExpiredTempClean.taskID { return String(localized: "Clean expired temporary files") }
        return MaintenanceCatalog.all.first { $0.id == id }?.title ?? id
    }

    private func applyEnabledChange() async {
        guard !isUpdatingSchedule, pendingEnabledChange else { return }
        isUpdatingSchedule = true
        await finishScheduleOperation()
        if config.enabled { await refreshScheduleMigration() }
    }

    /// A switch change can arrive while unregister is suspended. Reconcile the latest saved
    /// setting within the same operation, before any other task may call the service.
    private func finishScheduleOperation() async {
        while pendingEnabledChange {
            pendingEnabledChange = false
            do {
                if config.enabled {
                    if agent.status != .enabled && agent.status != .requiresApproval {
                        // Persist the intent before the service call: a register that fails here
                        // leaves the marker set, so the next refresh or Retry resumes instead of
                        // reporting the agent inactive (the user would otherwise have to flip the
                        // switch off and on again).
                        AutoCleanScheduleMigration.markPending(defaults: defaults)
                        try agent.register()
                        AutoCleanScheduleMigration.recordRegistration(defaults: defaults)
                    }
                } else if agent.status == .enabled || agent.status == .requiresApproval {
                    try await agent.unregister()
                }
                message = nil
            } catch {
                message = agent.status == .requiresApproval
                    ? String(localized: "Allow MacHelper to run in the background in System Settings → General → Login Items.")
                    : String(localized: "Couldn’t set up the background schedule: \(error.localizedDescription)")
            }
        }
        agentStatus = agent.status
        isUpdatingSchedule = false
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try AutoClean.save(config, to: configURL)
            return true
        } catch {
            message = String(localized: "Couldn’t save settings: \(error.localizedDescription)")
            return false
        }
    }

    /// Runs one low-risk clean now (in-process, same code path the agent uses).
    func runNow() async {
        isRunning = true
        defer { isRunning = false }
        let current = config
        let outcome = await Task.detached(priority: .userInitiated) { () -> (CleanReport, [TaskOutcome])? in
            guard let rules = try? RuleSet.load() else { return nil }
            let (_, report, tasks) = AutoClean.run(config: current, rules: rules)
            return (report, tasks)
        }.value
        guard let (report, tasks) = outcome else { message = String(localized: "Couldn’t load the cleaning rules"); return }
        var updated = AutoClean.load(from: configURL)
        AutoClean.record(report, tasks: tasks, into: &updated)
        updated.enabled = config.enabled
        updated.frequency = config.frequency
        updated.permanent = config.permanent
        updated.trashInstead = config.trashInstead
        updated.maintenanceTasks = config.maintenanceTasks
        updated.tempClean = config.tempClean
        config = updated
        save()
        message = String(localized: "Cleaned \(config.lastItemCount) items.")
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
