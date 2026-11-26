import AppKit
import CleanEngine
import Foundation
import Observation
import Permissions
import ServiceManagement
import Storage
import Tweaks
import UserNotifications

/// The single source of truth for every system permission MacHelper can need.
///
/// A screen shows `items`, acts through `request(_:)`, and never reads TCC, `SMAppService` or the
/// Helper itself. The model refreshes when the app becomes active (the moment someone comes back
/// from System Settings), when a screen calls `refresh()`, and once a second while a guidance screen
/// is visible through `watch()`. Nothing polls in the background.
///
/// What macOS answered and what that means for a screen are kept apart: the reads happen here, and
/// the translation lives in the testable `Permissions` package (`PermissionResolver`).
@MainActor
@Observable
final class PermissionCenter {
    static let shared = PermissionCenter()

    /// One permission with its copy and its current answer, in the order a screen lists it.
    struct Item: Identifiable, Equatable, Sendable {
        let id: PermissionID
        let info: PermissionInfo
        let state: PermissionState
        /// Whether the feature that needs this grant is part of the current setup.
        let isRequired: Bool
        /// The grant is in place but this process cannot use it until MacHelper relaunches.
        let requiresRelaunch: Bool
    }

    /// Rows in display order: grants the current setup needs and does not have come first.
    private(set) var items: [Item] = PermissionID.allCases.map {
        Item(id: $0,
             info: PermissionInfo.info(for: $0),
             state: .checking,
             isRequired: false,
             requiresRelaunch: false)
    }

    /// Why the last request failed, for a screen to show after the call returns.
    private(set) var lastActionError: String?

    @ObservationIgnored private var snapshot = PermissionSnapshot.unknown
    @ObservationIgnored private var lastAccessibilityProbe: Date?
    @ObservationIgnored private var inFlightRefresh: Task<Void, Never>?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var watcherCount = 0
    @ObservationIgnored private var watcherTask: Task<Void, Never>?

    /// A fresh Accessibility answer can only come from a new process, and each check starts one, so
    /// an answer is reused for a couple of seconds while a guidance screen polls.
    private static let accessibilityProbeInterval: TimeInterval = 2

    init() {
        // Coming back from System Settings is when a grant has most likely just been made. The
        // observer is installed here so it works even before the first screen asks for a refresh,
        // but it stays quiet until the model has been read once.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hasLoaded else { return }
                await self.refresh()
            }
        }
    }

    /// The row for one permission, once the first refresh has filled the list.
    func item(_ id: PermissionID) -> Item? {
        items.first { $0.id == id }
    }

    // MARK: Reading

    /// Reads every source once. Safe to call often: overlapping calls share one pass instead of
    /// asking macOS twice.
    func refresh() async {
        if let inFlightRefresh {
            await inFlightRefresh.value
            return
        }
        let pass = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.readStatuses()
        }
        inFlightRefresh = pass
        await pass.value
        inFlightRefresh = nil
    }

    /// Polls while a guidance screen is visible. The caller's task is the lifetime: SwiftUI cancels
    /// a `.task` when the view disappears, and the loop stops with it. Several screens share one
    /// poller, so the settings page and a floating guide can watch at the same time.
    func watch(every interval: Duration = .seconds(1)) async {
        watcherCount += 1
        if watcherTask == nil {
            watcherTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do { try await Task.sleep(for: interval) } catch { return }
                }
            }
        }
        // Suspends until this call's task is cancelled; a cancelled sleep throws at once.
        do { try await Task.sleep(for: .seconds(86_400)) } catch {}
        watcherCount -= 1
        guard watcherCount == 0 else { return }
        watcherTask?.cancel()
        watcherTask = nil
    }

    private func readStatuses() async {
        let requirements = currentRequirements()
        var next = snapshot

        // Local, cheap answers first.
        next.helper = helperStatus()
        next.backgroundRecording = Self.serviceStatus(
            SMAppService.agent(plistName: BackgroundRecordingModel.agentPlistName).status)
        next.autoCleanSchedule = Self.serviceStatus(
            SMAppService.agent(plistName: SMAppServiceAgentServicing.plistName).status)
        next.openAtLogin = Self.serviceStatus(SMAppService.mainApp.status)

        // These block: a protected file open, an Apple Event to Finder, and pluginkit. None of them
        // belongs on the main thread, and they do not depend on each other.
        async let fullDiskAccess = Task.detached(priority: .utility) { FullDiskAccess.isGranted }.value
        async let automation = Task.detached(priority: .utility) { FinderAutomation.permission }.value
        async let extensionEnabled = Task.detached(priority: .utility) { FinderExtensionStatus.isEnabled() }.value

        next.fullDiskAccess = await fullDiskAccess
        next.finderAutomation = await automation
        next.finderExtension = (await extensionEnabled).map { $0 ? .enabled : .disabled } ?? .unknown
        next.accessibility = await accessibilityStatus()

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        next.notifications = Self.notificationStatus(settings.authorizationStatus)

        snapshot = next
        hasLoaded = true
        apply(next, requirements: requirements)
    }

    private func apply(_ snapshot: PermissionSnapshot, requirements: PermissionRequirements) {
        let rows = PermissionID.allCases.map { id in
            Item(id: id,
                 info: PermissionInfo.info(for: id),
                 state: PermissionResolver.state(for: id, snapshot: snapshot, requirements: requirements),
                 isRequired: PermissionResolver.isRequired(id, requirements: requirements),
                 requiresRelaunch: PermissionResolver.requiresRelaunch(for: id, snapshot: snapshot))
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let order = PermissionOrder.sorted(rows.map { (id: $0.id, isRequired: $0.isRequired, state: $0.state) })
        items = order.compactMap { byID[$0] }
    }

    private func accessibilityStatus() async -> AccessibilityPermissionStatus {
        if AccessibilityAuthority.isGranted { return .granted }
        // Snapshot and self-test instances must not start extra processes.
        guard !Self.isNonInteractiveRun else { return .notGranted }
        if let last = lastAccessibilityProbe,
           Date().timeIntervalSince(last) < Self.accessibilityProbeInterval {
            return snapshot.accessibility ?? .notGranted
        }
        lastAccessibilityProbe = Date()
        // The same split `AccessibilityGrant` draws for the tweaks: a new process sees a grant made
        // while this one runs, and this one cannot until it relaunches (macOS 27).
        return await AccessibilityAuthority.isGrantedInFreshProcess() ? .restartRequired : .notGranted
    }

    /// The switches outside the permission system, read from the same stores the features use.
    private func currentRequirements() -> PermissionRequirements {
        let features = FeatureStore.shared
        let tweaks = TweakStore().load()
        func tweakEnabled(_ permission: TweakPermission) -> Bool {
            TweakCatalog.all.contains {
                $0.implemented && $0.permissions.contains(permission) && tweaks.isEnabled($0.id)
            }
        }
        let profile = MonitorAgentProfileStore.load(from: MonitorAgentProfileStore.defaultURL())
        return PermissionRequirements(
            fansModuleEnabled: features.isEnabled(.fans),
            optimizeModuleEnabled: features.isEnabled(.optimize),
            startupModuleEnabled: features.isEnabled(.startup),
            uninstallModuleEnabled: features.isEnabled(.uninstall),
            diskModuleEnabled: features.isEnabled(.disk),
            accessibilityTweaksEnabled: tweakEnabled(.accessibility),
            finderAutomationTweakEnabled: tweakEnabled(.automationFinder),
            finderExtensionTweakEnabled: tweakEnabled(.finderExtension),
            alertNotificationsEnabled: alertNotificationsEnabled,
            monitorModuleEnabled: features.isEnabled(.monitor),
            backgroundRecordingIntent: profile?.backgroundRecordingEnabled ?? false,
            autoCleanEnabled: AutoClean.load().enabled)
    }

    private var alertNotificationsEnabled: Bool {
        guard let data = UserDefaults.standard.data(forKey: AlertCenter.key),
              let settings = try? JSONDecoder().decode(AlertSettings.self, from: data) else { return false }
        return settings.anyEnabled
    }

    private func helperStatus() -> HelperPermissionStatus {
        // The health monitor already probes the Helper over XPC on launch, on activation and every
        // minute; "running" therefore means a real handshake, not just an SMAppService record.
        switch HelperHealthMonitor.shared.state {
        case .notConfigured: .notConfigured
        case .healthy: .running
        case .recovering: .repairing
        case .requiresApproval: .waitingForApproval
        case .permissionLostAfterUpdate, .unresponsive, .versionMismatch, .untrustedSignature: .needsRepair
        }
    }

    private static func serviceStatus(_ status: SMAppService.Status) -> ServiceStatus {
        switch status {
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    private static func notificationStatus(_ status: UNAuthorizationStatus) -> NotificationAuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .notDetermined
        }
    }

    /// Snapshot, measurement and self-test runs are short-lived diagnostic instances; they must not
    /// start extra processes or register anything.
    private static var isNonInteractiveRun: Bool {
        CommandLine.arguments.contains { arg in
            arg.hasPrefix("--snapshot") || arg == "--measure-pages"
                || arg == "--selftest" || arg == "--export-icon-template"
        }
    }

    // MARK: Acting

    /// The one action a row needs: a prompt where macOS can ask, System Settings where only a
    /// switch can help.
    func request(_ id: PermissionID) async {
        lastActionError = nil
        switch id {
        case .helper: await installHelper()
        case .accessibility: requestAccessibility()
        case .finderAutomation: await requestAutomation()
        case .notifications: await requestNotifications()
        case .openAtLogin:
            if item(.openAtLogin)?.state == .granted {
                await setOpenAtLogin(false)
            } else {
                await setOpenAtLogin(true)
            }
        case .fullDiskAccess, .finderExtension, .backgroundRecording, .autoCleanSchedule:
            openSettings(for: id)
        }
    }

    func openSettings(for id: PermissionID) {
        PermissionInfo.info(for: id).settingsPane.open()
    }

    /// Registers the Helper and, when macOS wants the entry approved, opens Login Items. Repairing a
    /// registration that stopped working stays in `HelperHealthMonitor.repairNow()`, which owns the
    /// recovery flow.
    func installHelper() async {
        lastActionError = nil
        do {
            try HelperClient.shared.register()
        } catch {
            lastActionError = error.localizedDescription
        }
        if HelperClient.shared.currentStatus == .requiresApproval {
            SystemSettingsPane.loginItems.open()
        }
        // The row reads the health monitor's verified state; probe once so it reflects the new
        // registration now instead of at the next periodic pass. The probe never repairs.
        await HelperHealthMonitor.shared.check(allowRecovery: false)
        await refresh()
    }

    /// Shows macOS's own Accessibility alert once. The switch in Settings still has to be turned on,
    /// and on macOS 27 the grant only reaches this process after a relaunch.
    func requestAccessibility() {
        AccessibilityAuthority.requestPrompt()
    }

    /// Asks macOS for the Automation grant; the system shows its own alert the first time. macOS can
    /// only ask about a running Finder, so a Finder that isn't running is started first. When macOS
    /// will not ask (refused before, or it declines to show the alert), Privacy & Security →
    /// Automation opens instead, so the button never ends in silence.
    @discardableResult
    func requestAutomation() async -> FinderAutomationStatus {
        lastActionError = nil
        var canLaunchFinder = true
        var outcome: (asked: FinderAutomationStatus, followUp: FinderAutomationFollowUp)
        repeat {
            outcome = await Self.askForAutomation(canLaunchFinder: canLaunchFinder)
            guard outcome.followUp == .launchFinderAndRetry, await FinderAutomation.launchFinder() else { break }
            canLaunchFinder = false
        } while true
        switch outcome.followUp {
        case .done, .launchFinderAndRetry:
            break
        case .openSettings:
            openSettings(for: .finderAutomation)
        case .promptNotShown:
            lastActionError = String(localized: "macOS didn’t show its Finder prompt. Turn on Finder under MacHelper in Privacy & Security → Automation.")
            openSettings(for: .finderAutomation)
        }
        await refresh()
        return outcome.asked
    }

    /// One request with the prompt allowed, between two reads that never ask. The request waits for
    /// the person's answer to the system alert, so none of it runs on the main thread.
    private static func askForAutomation(canLaunchFinder: Bool) async
        -> (asked: FinderAutomationStatus, followUp: FinderAutomationFollowUp) {
        await Task.detached(priority: .userInitiated) {
            let before = FinderAutomation.permission
            let asked = FinderAutomation.requestPermission()
            let recorded = FinderAutomation.permission
            return (asked, FinderAutomationFollowUp.after(asked: asked, before: before, recorded: recorded,
                                                          canLaunchFinder: canLaunchFinder))
        }.value
    }

    func requestNotifications() async {
        lastActionError = nil
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            lastActionError = error.localizedDescription
        }
        await refresh()
    }

    /// The Open at login switch. The app registers itself, so macOS never asks for approval here.
    func setOpenAtLogin(_ enabled: Bool) async {
        lastActionError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            lastActionError = error.localizedDescription
        }
        await refresh()
    }
}
