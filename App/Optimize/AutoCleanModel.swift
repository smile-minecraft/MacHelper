import CleanEngine
import Foundation
import Observation
import ServiceManagement

/// Auto clean settings. The schedule runs as a user LaunchAgent (registered here through SMAppService)
/// that calls the embedded CLI hourly; the CLI runs only when enabled and due, so the app need not be open.
@MainActor
@Observable
final class AutoCleanModel {
    static let agentPlist = "com.machelper.MacHelper.AutoClean.plist"

    private(set) var config = AutoClean.load()
    private(set) var agentStatus: SMAppService.Status = .notRegistered
    private(set) var message: String?
    private(set) var isRunning = false

    @ObservationIgnored private let agent = SMAppService.agent(plistName: AutoCleanModel.agentPlist)

    init() { refresh() }

    func refresh() {
        config = AutoClean.load()
        agentStatus = agent.status
    }

    var enabled: Bool {
        get { config.enabled }
        set { Task { await setEnabled(newValue) } }
    }

    var frequency: AutoCleanConfig.Frequency {
        get { config.frequency }
        set { config.frequency = newValue; save() }
    }

    var trashInstead: Bool {
        get { config.trashInstead == true }
        set { config.trashInstead = newValue; save() }
    }

    private func setEnabled(_ on: Bool) async {
        config.enabled = on
        save()
        do {
            if on {
                if agent.status != .enabled { try agent.register() }
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
        let report = await Task.detached(priority: .userInitiated) { () -> CleanReport? in
            guard let rules = try? RuleSet.load() else { return nil }
            return AutoClean.run(config: current, rules: rules).1
        }.value
        guard let report else { message = String(localized: "Couldn’t load the cleaning rules"); return }
        var updated = AutoClean.load()
        AutoClean.record(report, into: &updated)
        updated.enabled = config.enabled
        updated.frequency = config.frequency
        updated.permanent = config.permanent
        updated.trashInstead = config.trashInstead
        config = updated
        save()
        message = String(localized: "Cleaned \(config.lastItemCount) items.")
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
