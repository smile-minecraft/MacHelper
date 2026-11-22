import AppKit
import Foundation
import Observation
import OSLog
import Storage
import UserNotifications

/// Tone of the sidebar's Helper indicator, kept out of the view so the label and the
/// colour can never disagree about the same state.
enum HelperIndicatorTone {
    case healthy
    case warning
    case alert
    case neutral
}

/// Watches the privileged Helper for real, not just in Background Task Management.
///
/// `SMAppService.status == .enabled` only means launchd has a job registered. It says
/// nothing about whether the daemon was replaced by an update, speaks an older XPC
/// protocol, or was never spawned at all. This monitor probes the Helper over XPC on
/// launch, periodically, and whenever the app becomes active — the moment a user flips
/// the switch in Login Items — and repairs or explains what went wrong.
@MainActor
@Observable
final class HelperHealthMonitor {
    static let shared = HelperHealthMonitor()

    private static let pollingInterval: TimeInterval = 60
    private static let maxRecoveryAttempts = 4

    @ObservationIgnored private let client = HelperClient.shared
    @ObservationIgnored private let handoffURL = HelperUpdateHandoffStore.defaultURL()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    /// The one automatic pass that currently owns the Helper probe and any SMAppService
    /// mutation. Its handle also lets a manual repair wait for that pass to finish.
    @ObservationIgnored private var activeCheckTask: Task<Void, Never>?
    /// A trigger arrived while another pass or a manual repair owned SMAppService. One
    /// follow-up pass is enough, however many triggers piled up.
    @ObservationIgnored private var pendingRecheck = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var lastNotifiedState: HelperHealthState?

    private(set) var state: HelperHealthState = .notConfigured
    /// Dismiss hides the banner for this session only; the sidebar indicator stays.
    var isDismissedForSession = false
    var isRepairing = false
    var repairError: String?

    private init() {}

    /// Short-lived snapshot, measurement and CLI runs must never touch a real Helper.
    private static var isNonInteractiveRun: Bool {
        CommandLine.arguments.contains { arg in
            arg.hasPrefix("--snapshot") || arg == "--measure-pages"
                || arg == "--selftest" || arg == "--export-icon-template"
        }
    }

    // MARK: Lifecycle

    /// Called once at launch from AppDelegate. Non-blocking: the first probe runs in a
    /// Task so the window can appear while the Helper is being checked.
    func startAfterLaunch() {
        guard !Self.isNonInteractiveRun, !started else { return }
        started = true

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.check(allowRecovery: true) }
        }

        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollingInterval))
                guard !Task.isCancelled else { break }
                await self?.check(allowRecovery: true)
            }
        }
        Task { @MainActor [weak self] in await self?.check(allowRecovery: true) }
    }

    /// Called immediately before Sparkle replaces the bundle. Records what the Helper
    /// was doing and drops the XPC connection so the old daemon is not held open.
    func prepareForUpdate() {
        let wasEnabled = client.status == .enabled
        let wasHealthy = wasEnabled && (isHealthy || client.hadPreviouslyWorked)
        let snapshot = HelperUpdateHandoff(
            wasEnabled: wasEnabled,
            wasHealthy: wasHealthy,
            previousAppVersion: client.appVersion,
            previousHelperHash: client.embeddedHelperHash,
            timestamp: Date())
        do {
            try HelperUpdateHandoffStore.save(snapshot, to: handoffURL)
        } catch {
            HelperClient.logger.error("Could not save the Helper update handoff: \(error.localizedDescription, privacy: .public)")
        }
        client.resetConnection()
        state = .recovering
        HelperClient.logger.notice("Helper handoff saved before update (enabled=\(wasEnabled, privacy: .public), healthy=\(wasHealthy, privacy: .public))")
    }

    /// An update that failed or was cancelled must not later claim an update happened.
    func clearPendingUpdateHandoff() {
        HelperUpdateHandoffStore.clear(from: handoffURL)
        Task { @MainActor [weak self] in await self?.check(allowRecovery: false) }
    }

    // MARK: Observation and recovery

    private func activeHandoff() -> HelperUpdateHandoff? {
        HelperUpdateHandoffStore.load(from: handoffURL) ?? client.detectedManualUpdateHandoff()
    }

    /// True while one automatic pass owns the Helper check. The in-flight task is the
    /// gate; this name keeps the guards below readable.
    private var isChecking: Bool { activeCheckTask != nil }

    /// Entry point for every automatic probe: launch, activation, the periodic timer and
    /// a cancelled update. Only one pass may run at a time, because a pass can call
    /// `softRepair()` or `reinstall()` and two overlapping passes would mutate
    /// SMAppService on top of each other.
    func check(allowRecovery: Bool) async {
        guard !Self.isNonInteractiveRun else { return }

        // A manual repair owns SMAppService until it finishes. Starting a recovery pass
        // now could reinstall over it; remember the trigger instead.
        if isRepairing || isChecking {
            if allowRecovery { pendingRecheck = true }
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runCheckLoop(allowRecovery: allowRecovery)
            self.activeCheckTask = nil
        }
        activeCheckTask = task
        await task.value

        // A trigger arrived during the pass. Run exactly one clean follow-up, unless a
        // manual repair took over in the meantime — it performs its own observation.
        if pendingRecheck, !isRepairing {
            pendingRecheck = false
            await check(allowRecovery: true)
        }
    }

    /// One bounded recovery pass. Each iteration re-observes from scratch: an action can
    /// change the registration (`.reinstall`) or the user can approve during a retry, so
    /// a cached status would make the next decision wrong.
    /// Callers must hold the `activeCheckTask` gate or be the manual repair owner.
    private func runCheckLoop(allowRecovery: Bool) async {
        var attempt = 0

        while !Task.isCancelled {
            let status = client.pureStatus
            let handoff = activeHandoff()
            let hadWorked = client.hadPreviouslyWorked
            let outcome: HelperHandshakeOutcome? = status == .enabled ? await client.probeHandshake() : nil
            let observed = HelperRecoveryPlanner.evaluateState(
                status: status,
                handshakeResult: outcome,
                handoff: handoff,
                hadPreviouslyWorked: hadWorked)

            if case .healthy = observed {
                // A successful probe already recorded the known-good fingerprint; the
                // handoff has served its purpose and must not fire on a later launch.
                HelperUpdateHandoffStore.clear(from: handoffURL)
                applyState(observed)
                return
            }

            guard allowRecovery, attempt < Self.maxRecoveryAttempts else {
                applyState(observed)
                return
            }

            let action = HelperRecoveryPlanner.nextAction(
                status: status,
                handshakeResult: outcome,
                handoff: handoff,
                hadPreviouslyWorked: hadWorked,
                attemptCount: attempt)

            switch action {
            case .none:
                applyState(observed)
                return
            case .promptUser(let prompt):
                applyState(prompt)
                return
            case .retryHandshake:
                attempt += 1
                HelperClient.logger.notice("Helper handshake retry \(attempt, privacy: .public)")
                try? await Task.sleep(for: .milliseconds(500))
            case .softReregister:
                attempt += 1
                state = .recovering
                do {
                    try await client.softRepair()
                } catch {
                    HelperClient.logger.warning("Automatic soft repair failed: \(error.localizedDescription, privacy: .public)")
                }
            case .reinstall:
                attempt += 1
                state = .recovering
                do {
                    try await client.reinstall()
                } catch {
                    HelperClient.logger.warning("Automatic reinstall failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func applyState(_ newState: HelperHealthState) {
        state = newState
        if case .healthy = newState {
            lastNotifiedState = nil
            isDismissedForSession = false
            repairError = nil
            return
        }
        guard newState.needsAttention else { return }
        Task { @MainActor [weak self] in await self?.postNotificationIfNeeded(newState) }
    }

    // MARK: User actions

    /// The banner's one-click repair. A full reinstall is used because a soft repair has
    /// already been tried automatically by then.
    func repairNow() async {
        guard !Self.isNonInteractiveRun else { return }
        // Two taps on Repair must not start two reinstalls.
        guard !isRepairing else { return }
        isRepairing = true

        // An automatic pass started before the tap may still be probing or retrying.
        // Wait it out before touching SMAppService. New triggers now only set
        // pendingRecheck, so no second pass can start while we are repairing.
        while let inFlight = activeCheckTask {
            await inFlight.value
        }

        repairError = nil
        state = .recovering
        do {
            try await client.reinstall()
        } catch {
            repairError = error.localizedDescription
            HelperClient.logger.error("Manual Helper repair failed: \(error.localizedDescription, privacy: .public)")
        }
        // Observe the outcome ourselves. The gate rejects a normal check while
        // isRepairing is true, so use the pass directly.
        await runCheckLoop(allowRecovery: false)

        isRepairing = false
        if pendingRecheck {
            pendingRecheck = false
            await check(allowRecovery: true)
        }
    }

    func reinstallNow() async { await repairNow() }

    func openLoginItems() { client.openLoginItemsSettings() }

    func dismissBanner() { isDismissedForSession = true }

    // MARK: Presentation

    var shouldShowBanner: Bool { !isDismissedForSession && state.needsAttention }

    var isHealthy: Bool {
        if case .healthy = state { return true }
        return false
    }

    var footerTone: HelperIndicatorTone {
        switch state {
        case .healthy: .healthy
        case .notConfigured, .recovering: .neutral
        case .requiresApproval: .warning
        case .permissionLostAfterUpdate, .unresponsive, .versionMismatch, .untrustedSignature: .alert
        }
    }

    /// Short label for the sidebar footer and diagnostics, always derived from the real
    /// health state rather than the raw registration status.
    var summaryLabel: String {
        switch state {
        case .notConfigured: String(localized: "Set up Helper…")
        case .healthy: String(localized: "Helper running")
        case .recovering: String(localized: "Checking Helper…")
        case .requiresApproval: String(localized: "Helper needs approval")
        case .permissionLostAfterUpdate, .versionMismatch, .untrustedSignature:
            String(localized: "Helper needs repair")
        case .unresponsive: String(localized: "Helper unresponsive")
        }
    }

    var bannerTitle: String {
        switch state {
        case .requiresApproval: String(localized: "MacHelper Helper needs your approval")
        case .permissionLostAfterUpdate: String(localized: "MacHelper Helper lost permission after the update")
        case .unresponsive: String(localized: "MacHelper Helper isn’t responding")
        case .versionMismatch: String(localized: "MacHelper Helper is out of date")
        case .untrustedSignature: String(localized: "MacHelper Helper could not be verified")
        case .notConfigured, .healthy, .recovering: String(localized: "MacHelper Helper needs attention")
        }
    }

    /// Plain-language explanation shared by the in-app banner and the local notification.
    /// It says why the Helper stopped and what the user can do, without exposing cdhash or
    /// protocol internals.
    func explanatoryText(for state: HelperHealthState) -> String {
        switch state {
        case .requiresApproval(let afterUpdate):
            return afterUpdate
                ? String(localized: "After the recent update, macOS paused the MacHelper Helper. Re-enable it in System Settings → General → Login Items & Extensions to restore fan control and system cleanup.")
                : String(localized: "macOS is waiting for you to allow the MacHelper Helper in System Settings → General → Login Items & Extensions.")
        case .permissionLostAfterUpdate:
            return String(localized: "After the recent update, the MacHelper Helper lost its permission. Repair it to restore fan control and system cleanup.")
        case .unresponsive(_, let afterUpdate):
            return afterUpdate
                ? String(localized: "After the recent update, the MacHelper Helper isn’t responding. Repair it to restore fan control and system cleanup.")
                : String(localized: "The MacHelper Helper isn’t responding. Repair it to restore fan control and system cleanup.")
        case .versionMismatch:
            return String(localized: "The MacHelper Helper is out of date after the update. Repair it to restore fan control and system cleanup.")
        case .untrustedSignature:
            return String(localized: "The MacHelper Helper’s signature could not be verified. Reinstall MacHelper to restore it.")
        case .notConfigured, .healthy, .recovering:
            return ""
        }
    }

    var bannerMessage: String { explanatoryText(for: state) }

    // MARK: Notification

    /// One deduplicated local notification per failure incident. Notification permission
    /// is checked but never requested, so menu-bar-only users are alerted without a prompt
    /// and no permission state can crash the monitor.
    private func postNotificationIfNeeded(_ state: HelperHealthState) async {
        guard state.needsAttention else { return }
        guard client.hadPreviouslyWorked || activeHandoff() != nil else { return }
        guard lastNotifiedState != state else { return }
        lastNotifiedState = state

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "MacHelper Helper needs attention")
        content.body = explanatoryText(for: state)
        let request = UNNotificationRequest(identifier: "com.machelper.helper-health",
                                            content: content, trigger: nil)
        do {
            try await center.add(request)
            HelperClient.logger.notice("Posted Helper health notification")
        } catch {
            HelperClient.logger.warning("Could not post Helper health notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}
