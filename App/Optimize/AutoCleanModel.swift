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
    static let agentPlist = "com.machelper.MacHelper.AutoClean.plist"

    private(set) var config = AutoClean.load()
    private(set) var agentStatus: SMAppService.Status = .notRegistered
    private(set) var message: String?
    /// Reason an existing-agent schedule migration failed, when it did. Written, cleared or
    /// retried only through `refreshScheduleMigration()`; shown in Settings with a Retry action.
    private(set) var scheduleMigrationError: String?
    private(set) var isRunning = false
    @ObservationIgnored private let agentServicing = SMAppServiceAgentServicing()

    @ObservationIgnored private let agent = SMAppService.agent(plistName: AutoCleanModel.agentPlist)

    init() { refresh() }

    func refresh() {
        config = AutoClean.load()
        agentStatus = agent.status
        let tasks = maintenanceRows.map(\.task)
        Task {
            let availability = await Task.detached(priority: .utility) { tasks.map(\.isAvailable) }.value
            maintenanceRows = zip(tasks, availability).map { ($0, $1) }
        }
        Task { await refreshScheduleMigration() }
    }

    /// Runs the one-time schedule migration for an already-registered agent. No-op when the
    /// current version is already recorded (or the agent is inactive). Failure is surfaced, and
    /// the next refresh, the next frequency change or an explicit retry can run it again.
    private func refreshScheduleMigration() async {
        switch await AutoCleanScheduleMigration.runIfNeeded(servicing: agentServicing) {
        case .alreadyCurrent, .inactive:
            scheduleMigrationError = nil
        case .migrated:
            scheduleMigrationError = nil
            agentStatus = agent.status
        case .failed(let message):
            scheduleMigrationError = message
        }
    }

    /// User-facing retry for a failed schedule migration (Settings shows it only when there is an error).
    func retryScheduleMigration() {
        Task { await refreshScheduleMigration() }
    }

    var enabled: Bool {
        get { config.enabled }
        set { Task { await setEnabled(newValue) } }
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

    var agentTempClean: Bool {
        get { config.agentTempClean == true }
        set { config.agentTempClean = newValue ? true : nil; save() }
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
        if id == AgentTempClean.taskID { return String(localized: "Clean expired agent test temp files") }
        return MaintenanceCatalog.all.first { $0.id == id }?.title ?? id
    }

    private func setEnabled(_ on: Bool) async {
        config.enabled = on
        save()
        do {
            if on {
                if agent.status != .enabled {
                    try agent.register()
                    // A fresh registration installs the embedded plist; no migration needed after this.
                    AutoCleanScheduleMigration.recordRegistration()
                }
            } else if agent.status == .enabled || agent.status == .requiresApproval {
                try await agent.unregister()
            }
            message = nil
        } catch {
            // Agents can need approval in Login Items, which register() reports as an error.
            message = agent.status == .requiresApproval
                ? String(localized: "Allow MacHelper to run in the background in System Settings → General → Login Items.")
                : String(localized: "Couldn’t set up the background schedule: \(error.localizedDescription)")
        }
        agentStatus = agent.status
    }

    private func save() {
        do { try AutoClean.save(config) } catch { message = String(localized: "Couldn’t save settings: \(error.localizedDescription)") }
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
        var updated = AutoClean.load()
        AutoClean.record(report, tasks: tasks, into: &updated)
        updated.enabled = config.enabled
        updated.frequency = config.frequency
        updated.permanent = config.permanent
        updated.trashInstead = config.trashInstead
        updated.maintenanceTasks = config.maintenanceTasks
        updated.agentTempClean = config.agentTempClean
        config = updated
        save()
        message = String(localized: "Cleaned \(config.lastItemCount) items.")
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
