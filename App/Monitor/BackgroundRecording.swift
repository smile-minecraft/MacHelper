import Foundation
import Observation
import ServiceManagement
import Storage

/// Bridges the user's "record history when MacHelper quits" toggle to the user-level
/// background agent. The agent is registered only on an explicit toggle; it is never
/// registered at launch or in the background. The app remains the live writer while
/// background recording is off, exactly as before.
///
/// App-scope object (owned by AppModel), so closing the settings window never loses the
/// wiring. The persisted intent is restored from the profile snapshot at launch, and the
/// snapshot is re-published whenever the monitor configuration changes while enabled.
///
/// The recorder loop itself runs from the embedded CLI (`machelper monitor --record`); this
/// model only registers the agent, publishes its profile, and reads the heartbeat.
@MainActor
@Observable
final class BackgroundRecordingModel {
    static let agentPlistName = "com.machelper.MacHelper.MonitorAgent.plist"
    private static let approvalMessage = String(localized: "Allow MacHelper to run in the background in System Settings → General → Login Items.")

    private(set) var state: BackgroundRecordingState = .notEnabled
    private(set) var enabledIntent = false
    private(set) var message: String?

    @ObservationIgnored private let agent = SMAppService.agent(plistName: BackgroundRecordingModel.agentPlistName)
    @ObservationIgnored private let settings: MonitorSettingsStore
    @ObservationIgnored private let availableModules: Set<MonitorModule>
    @ObservationIgnored private let profileURL: URL
    @ObservationIgnored private let heartbeatURL: URL
    @ObservationIgnored private let handoffURL: URL
    /// Identifies the message `writeProfileSnapshot` set, so a later successful save clears
    /// only that failure and never an approval or registration message.
    @ObservationIgnored private var saveErrorMessage: String?
    @ObservationIgnored private var historyStore: HistoryStore?

    init(settings: MonitorSettingsStore,
         availableModules: Set<MonitorModule>,
         profileURL: URL = MonitorAgentProfileStore.defaultURL(),
         heartbeatURL: URL = MonitorAgentHeartbeatStore.defaultURL(),
         handoffURL: URL? = nil) {
        self.settings = settings
        self.availableModules = availableModules
        self.profileURL = profileURL
        self.heartbeatURL = heartbeatURL
        self.handoffURL = handoffURL
            ?? profileURL.deletingLastPathComponent().appending(path: UpdateAgentHandoffStore.fileName)
        // Restore the persisted intent so a relaunch never silently disables recording;
        // re-publish a fresh snapshot because sampling settings may have changed while away.
        let profile = MonitorAgentProfileStore.load(from: profileURL)
        enabledIntent = profile?.backgroundRecordingEnabled ?? false
        if enabledIntent { writeProfileSnapshot() }
        if profile?.backgroundRecordingEnabled == false,
           agent.status == .enabled || agent.status == .requiresApproval {
            // The profile says off but the service is still registered: a previous disable
            // did not finish, or the app quit before its unregister completed. Clean it up.
            Task {
                do {
                    try await agent.unregister()
                } catch {
                    message = String(localized: "Couldn’t stop background recording: \(error.localizedDescription)")
                }
                refresh()
            }
        }
        observeSettings()
        refresh()
    }

    /// Re-reads service status and heartbeat. Called on appear, periodically while the
    /// settings are visible, and after every toggle.
    func refresh() {
        let heartbeat = MonitorAgentHeartbeatStore.load(from: heartbeatURL)
        state = BackgroundRecordingStatus.evaluate(serviceStatus: Self.serviceStatus(agent.status),
                                                   profileEnabled: enabledIntent,
                                                   enabledModuleCount: enabledModulePlans().count,
                                                   processCollectionEnabled: processCollectionEnabled(),
                                                   heartbeat: heartbeat,
                                                   now: Date())
        // The instruction is stale in every state except "still waiting for approval",
        // including failures that keep the service from ever reaching approval.
        if state != .pendingApproval, message == Self.approvalMessage {
            message = nil
        }
    }

    /// The process switch lives in the shared history database, which the agent also reads,
    /// so it is re-read here instead of being cached.
    private func processCollectionEnabled() -> Bool {
        if historyStore == nil { historyStore = try? HistoryStore(readOnly: true) }
        return (try? historyStore?.isProcessCollectionEnabled()) == true
    }

    /// User-initiated enable. Registers the agent (or reports that Login Items approval is needed).
    func enable() {
        enabledIntent = true
        // The agent reads the profile, so registering it without a readable snapshot would
        // start a recorder with the wrong settings (or none). Surface the failure and stay off.
        guard writeProfileSnapshot() else {
            enabledIntent = false
            refresh()
            return
        }
        do {
            if agent.status != .enabled { try agent.register() }
            message = nil
        } catch {
            if agent.status == .requiresApproval {
                message = Self.approvalMessage
            } else {
                enabledIntent = false
                writeProfileSnapshot()
                message = String(localized: "Couldn’t set up background recording: \(error.localizedDescription)")
            }
        }
        refresh()
    }

    /// User-initiated disable. Unregisters the agent; the app keeps recording while it runs.
    func disable() {
        enabledIntent = false
        // Stopping the service is the point of this action, so unregister even if the profile
        // could not be rewritten; the save failure stays visible in `message`.
        let profileSaved = writeProfileSnapshot()
        Task {
            do {
                if agent.status == .enabled || agent.status == .requiresApproval {
                    try await agent.unregister()
                }
                if profileSaved { message = nil }
            } catch {
                enabledIntent = true
                writeProfileSnapshot()
                message = String(localized: "Couldn’t stop background recording: \(error.localizedDescription)")
            }
            refresh()
        }
        refresh()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: - App update

    /// Stops the agent before Sparkle replaces the bundle. The user's intent stays enabled;
    /// `resumeAfterUpdateIfNeeded()` restores it on the next launch only if the permission is
    /// still present. Called from the updater's relaunch-postponement callback.
    func suspendForUpdate() async {
        let handoff = UpdateAgentRestorePlanner.snapshot(
            enabledIntent: enabledIntent,
            serviceStatus: Self.serviceStatus(agent.status),
            heartbeat: MonitorAgentHeartbeatStore.load(from: heartbeatURL),
            now: Date()
        )
        do {
            try UpdateAgentHandoffStore.save(handoff, to: handoffURL)
        } catch {
            message = String(localized: "Couldn’t prepare background recording for the update: \(error.localizedDescription)")
            return
        }
        guard handoff.wasEnabled,
              agent.status == .enabled || agent.status == .requiresApproval else {
            return
        }
        do {
            try await agent.unregister()
            for _ in 0..<50 where agent.status != .notRegistered {
                try? await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            message = String(localized: "Couldn’t stop background recording before the update: \(error.localizedDescription)")
        }
        refresh()
    }

    /// Restores background recording after an update. The handoff records only a service that
    /// was enabled and registered before the install; a revoked permission, a disabled intent,
    /// or a pending approval stays off.
    func resumeAfterUpdateIfNeeded() {
        guard let handoff = UpdateAgentHandoffStore.load(from: handoffURL) else { return }
        switch UpdateAgentRestorePlanner.restore(handoff: handoff,
                                                 serviceStatus: Self.serviceStatus(agent.status)) {
        case .stayOff:
            UpdateAgentHandoffStore.clear(from: handoffURL)
            if agent.status == .requiresApproval { message = Self.approvalMessage }
        case .republish:
            guard writeProfileSnapshot() else { return }
            UpdateAgentHandoffStore.clear(from: handoffURL)
            message = nil
        case .reregister:
            guard writeProfileSnapshot() else { return }
            do {
                try agent.register()
                UpdateAgentHandoffStore.clear(from: handoffURL)
                message = agent.status == .requiresApproval ? Self.approvalMessage : nil
            } catch {
                // Keep the handoff so a later launch can retry after the user approves.
                if agent.status == .requiresApproval { message = Self.approvalMessage }
            }
        }
        refresh()
    }

    // MARK: - Snapshot publishing

    private func observeSettings() {
        withObservationTracking {
            _ = settings.configuration
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncProfileSnapshotIfEnabled()
                self.observeSettings()
            }
        }
    }

    /// Re-publishes the agent profile after any monitor configuration change; no-op while disabled.
    private func syncProfileSnapshotIfEnabled() {
        guard enabledIntent else { return }
        writeProfileSnapshot()
    }

    @discardableResult
    private func writeProfileSnapshot() -> Bool {
        let profile = MonitorAgentProfile(backgroundRecordingEnabled: enabledIntent,
                                          modules: enabledModulePlans())
        do {
            try MonitorAgentProfileStore.save(profile, to: profileURL)
            if message == saveErrorMessage { message = nil }
            saveErrorMessage = nil
            return true
        } catch {
            let text = String(localized: "Couldn’t save the background recording settings: \(error.localizedDescription)")
            saveErrorMessage = text
            message = text
            return false
        }
    }

    /// Snapshot of the monitor modules the app can sample and the user enabled, with their intervals.
    private func enabledModulePlans() -> [ModulePlan] {
        MonitorModule.allCases
            .filter { availableModules.contains($0) && settings[$0].enabled }
            .map { ModulePlan(module: $0.rawValue, interval: settings[$0].interval) }
    }

    private static func serviceStatus(_ status: SMAppService.Status) -> BackgroundServiceStatus {
        switch status {
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}
