import AppKit
import Observation
import Permissions

/// The one button a permission row offers, decided from its live state.
enum PermissionPrimaryAction: Equatable, Sendable {
    case installHelper
    case repairHelper
    /// Open the System Settings page where the switch lives.
    case openSettings
    /// Ask macOS, which shows its own alert.
    case allow
    /// The grant is in place but only a new copy of MacHelper can use it.
    case relaunch
    case turnOnAtLogin
    case turnOffAtLogin
    /// Nothing to approve yet; read the state again.
    case checkAgain

    var title: String {
        switch self {
        case .installHelper: String(localized: "Install Helper")
        case .repairHelper: String(localized: "Repair Helper")
        case .openSettings: String(localized: "Open System Settings")
        case .allow: String(localized: "Allow…")
        case .relaunch: String(localized: "Relaunch MacHelper")
        case .turnOnAtLogin: String(localized: "Turn On")
        case .turnOffAtLogin: String(localized: "Turn Off")
        case .checkAgain: String(localized: "Check Again")
        }
    }

    /// Actions that make macOS show its own alert or notification get MacHelper's explanation first.
    var needsPrePrompt: Bool { self == .installHelper || self == .allow }
}

/// Every path from a button to a permission grant: which action a row offers, the explanation that
/// comes before a system prompt, and the floating guide that stays beside System Settings.
///
/// Screens never call macOS themselves. The settings tab, the welcome guide and the shortcuts on the
/// feature pages all go through here, so the same permission is always explained the same way.
@MainActor
@Observable
final class PermissionFlow {
    static let shared = PermissionFlow()

    /// The row the Permissions tab should expand and scroll to.
    var focus: PermissionID?
    /// A permission whose action should start as soon as the Permissions tab is on screen.
    var pendingStart: PermissionID?
    /// Bumped each time something asks for the Permissions tab; the settings window follows it.
    private(set) var tabRequest = 0

    @ObservationIgnored private let center = PermissionCenter.shared

    private init() {}

    // MARK: Deciding

    /// The button for a row, or nil when there is nothing to do (granted, or still checking).
    static func primaryAction(for item: PermissionCenter.Item) -> PermissionPrimaryAction? {
        if item.state == .checking { return nil }
        if item.requiresRelaunch { return .relaunch }
        switch item.id {
        case .helper:
            switch item.state {
            case .granted, .checking: return nil
            case .needsApproval: return .openSettings
            case .denied: return .repairHelper
            case .notRequested, .notApplicable: return .installHelper
            }
        case .openAtLogin:
            switch item.state {
            case .granted: return .turnOffAtLogin
            case .needsApproval: return .openSettings
            default: return .turnOnAtLogin
            }
        case .accessibility, .finderAutomation, .notifications:
            switch item.state {
            case .granted, .checking: return nil
            case .notRequested, .notApplicable: return .allow
            case .denied, .needsApproval: return .openSettings
            }
        case .fullDiskAccess, .finderExtension:
            return item.state == .granted ? nil : .openSettings
        case .backgroundRecording, .autoCleanSchedule:
            // The feature registers its own agent; only the approval switch is the user's job.
            switch item.state {
            case .needsApproval: return .openSettings
            case .notRequested, .denied: return .checkAgain
            case .granted, .notApplicable, .checking: return nil
            }
        }
    }

    /// Permissions granted by hand in System Settings, where a floating guide helps.
    static func hasGuide(_ id: PermissionID) -> Bool {
        switch id {
        case .helper, .backgroundRecording, .autoCleanSchedule, .fullDiskAccess, .accessibility, .finderExtension:
            true
        case .finderAutomation, .notifications, .openAtLogin:
            false
        }
    }

    // MARK: Acting

    /// Runs a row's button: explanation first when macOS is about to ask, the action otherwise.
    func trigger(_ id: PermissionID, presentPrePrompt: (PermissionID) -> Void) {
        guard let item = center.item(id), let action = Self.primaryAction(for: item) else { return }
        if action.needsPrePrompt {
            presentPrePrompt(id)
        } else {
            Task { await perform(action, for: id) }
        }
    }

    /// What the explanation's Continue button runs, read again from the state at that moment.
    func confirmPrePrompt(_ id: PermissionID) async {
        guard let item = center.item(id), let action = Self.primaryAction(for: item) else { return }
        await perform(action, for: id)
    }

    func perform(_ action: PermissionPrimaryAction, for id: PermissionID) async {
        switch action {
        case .installHelper:
            await center.installHelper()
            if center.item(.helper)?.state != .granted { PermissionGuideController.shared.show(.helper) }
        case .repairHelper:
            await HelperHealthMonitor.shared.repairNow()
            await center.refresh()
            if center.item(.helper)?.state == .needsApproval { openGuided(.helper) }
        case .openSettings:
            openGuided(id)
        case .allow:
            switch id {
            case .accessibility:
                // The prompt adds MacHelper to the list; the switch itself is still flipped by hand.
                center.requestAccessibility()
                openGuided(.accessibility)
            case .finderAutomation:
                await center.requestAutomation()
            case .notifications:
                await center.requestNotifications()
            default:
                await center.request(id)
            }
        case .relaunch:
            AppRelauncher.relaunch()
        case .turnOnAtLogin:
            await center.setOpenAtLogin(true)
        case .turnOffAtLogin:
            await center.setOpenAtLogin(false)
        case .checkAgain:
            await center.refresh()
        }
    }

    /// Opens the page where the switch lives and, where the switch is flipped by hand, the guide.
    func openGuided(_ id: PermissionID) {
        center.openSettings(for: id)
        if Self.hasGuide(id) { PermissionGuideController.shared.show(id) }
    }

    // MARK: Navigating

    /// Opens Settings → Permissions with one row expanded. With `start`, that row's action begins
    /// as soon as the tab shows it, explanation first where macOS is about to ask.
    func showInSettings(_ id: PermissionID?, start: Bool = false) {
        focus = id
        pendingStart = start ? id : nil
        tabRequest += 1
        AppModel.shared.showSettings()
    }

    /// The Helper's state only changes when the health monitor probes it. While a screen waits for
    /// an approval, ask it again every couple of seconds instead of once a minute. The probe never
    /// repairs or registers anything.
    func followHelperApproval() async {
        while !Task.isCancelled {
            if center.item(.helper)?.state != .granted,
               HelperClient.shared.currentStatus == .enabled {
                await HelperHealthMonitor.shared.check(allowRecovery: false)
                await center.refresh()
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
}
