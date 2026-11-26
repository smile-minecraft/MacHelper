import Foundation

/// One system grant the app can need. The raw values are stable keys; the declaration order is the
/// order a permission screen lists them in once rank and state agree.
public enum PermissionID: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The root Helper (`SMAppService.daemon`): fan control, system cleanup, maintenance,
    /// privileged process counters, launch daemons and system-wide leftovers.
    case helper
    /// Full Disk Access: the TCC grant that hides Mail, Safari and other apps' containers.
    case fullDiskAccess
    /// Accessibility: the event tap and window queries behind the tweaks.
    case accessibility
    /// Automation → Finder: the one Apple Event the New File tweak sends.
    case finderAutomation
    /// The Finder extension: enabled in Login Items & Extensions, needed for Finder's context menu.
    case finderExtension
    /// Notification permission for threshold alerts and Helper health warnings.
    case notifications
    /// The monitor agent that records history while the app is closed.
    case backgroundRecording
    /// The Auto Clean agent that runs the scheduled low-risk clean.
    case autoCleanSchedule
    /// `SMAppService.mainApp`: starting MacHelper at login.
    case openAtLogin

    public var id: String { rawValue }
}

/// What a permission screen shows for one grant.
public enum PermissionState: String, CaseIterable, Equatable, Hashable, Sendable {
    /// This pass has not read the answer yet.
    case checking
    /// In place and usable now.
    case granted
    /// Registered, but macOS waits for a switch in System Settings.
    case needsApproval
    /// Refused, lost, or registered but not working.
    case denied
    /// Nothing was granted or asked yet, and the feature that needs it is on.
    case notRequested
    /// The feature that needs it is off, so the grant is not part of the current setup.
    case notApplicable
}

/// The Helper as the health monitor sees it, reduced to what a permission answer needs.
public enum HelperPermissionStatus: Equatable, Sendable {
    /// Never registered on this Mac.
    case notConfigured
    /// Registered, approved and answering XPC with a matching protocol version.
    case running
    /// Registered, but the switch in Login Items is still off.
    case waitingForApproval
    /// A health pass is in flight; the answer is not known yet.
    case repairing
    /// Registered but not usable: handshake failed, protocol mismatch or signature untrusted.
    case needsRepair
}

/// Accessibility as the app sees it. macOS 27 keeps answering a running process with the value it
/// read first, so a grant made afterwards only shows up in a new process.
public enum AccessibilityPermissionStatus: Equatable, Sendable {
    case granted
    /// The grant exists, but this process cannot use it until MacHelper relaunches.
    case restartRequired
    case notGranted
}

public enum FinderAutomationStatus: String, Equatable, Sendable {
    case granted
    case denied
    case undetermined
    /// Finder isn't running or did not answer, so macOS has no answer yet.
    case unavailable

    /// What `AEDeterminePermissionToAutomateTarget` returned. Every code other than the three TCC
    /// answers (procNotFound when Finder is not running, a timeout, a bad descriptor) means macOS
    /// gave no answer.
    public init(appleEventStatus status: Int32) {
        switch status {
        case 0: self = .granted                 // noErr
        case -1743: self = .denied              // errAEEventNotPermitted
        case -1744: self = .undetermined        // errAEEventWouldRequireUserConsent
        default: self = .unavailable            // procNotFound (-600) and everything else
        }
    }
}

/// What the Finder automation request does after macOS answered the Continue button, so the button
/// never ends in silence.
public enum FinderAutomationFollowUp: Equatable, Sendable {
    /// Granted, or the person just chose Don't Allow in macOS's alert: nothing more to do now. The
    /// row offers System Settings from then on.
    case done
    /// Finder was not running, so macOS could not ask; start Finder and ask once more.
    case launchFinderAndRetry
    /// Refused before this request: macOS never asks twice, the switch is in Privacy & Security →
    /// Automation.
    case openSettings
    /// macOS answered without showing its alert and recorded nothing (a build without the Apple
    /// Events entitlement, or a TCC database that declines to ask). System Settings is the only way
    /// left, and the person is told why nothing appeared.
    case promptNotShown

    /// - Parameters:
    ///   - asked: the answer to the request made with the prompt allowed.
    ///   - before: what macOS reported, without asking, right before that request.
    ///   - recorded: what macOS reports, without asking, right after it. A refusal the person made
    ///     is recorded; a refusal macOS made on its own without asking is not.
    ///   - canLaunchFinder: false once Finder was already started for this request.
    public static func after(asked: FinderAutomationStatus, before: FinderAutomationStatus,
                             recorded: FinderAutomationStatus, canLaunchFinder: Bool) -> Self {
        switch asked {
        case .granted:
            return .done
        case .denied:
            if before == .denied { return .openSettings }
            return recorded == .denied ? .done : .promptNotShown
        case .undetermined:
            return .promptNotShown
        case .unavailable:
            return canLaunchFinder ? .launchFinderAndRetry : .promptNotShown
        }
    }
}

public enum NotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

/// `SMAppService.Status` for an agent or a login item, without importing ServiceManagement.
public enum ServiceStatus: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
}

/// Whether the Finder extension is switched on. `nil` when PlugInKit could not be asked.
public enum FinderExtensionStatus: Equatable, Sendable {
    case enabled
    case disabled
    case unknown
}

/// Everything one refresh read. A `nil` field means the source has not answered yet in this pass and
/// resolves to `.checking`.
public struct PermissionSnapshot: Equatable, Sendable {
    public var helper: HelperPermissionStatus?
    public var fullDiskAccess: Bool?
    public var accessibility: AccessibilityPermissionStatus?
    public var finderAutomation: FinderAutomationStatus?
    public var finderExtension: FinderExtensionStatus?
    public var notifications: NotificationAuthorizationStatus?
    public var backgroundRecording: ServiceStatus?
    public var autoCleanSchedule: ServiceStatus?
    public var openAtLogin: ServiceStatus?

    public init(helper: HelperPermissionStatus? = nil,
                fullDiskAccess: Bool? = nil,
                accessibility: AccessibilityPermissionStatus? = nil,
                finderAutomation: FinderAutomationStatus? = nil,
                finderExtension: FinderExtensionStatus? = nil,
                notifications: NotificationAuthorizationStatus? = nil,
                backgroundRecording: ServiceStatus? = nil,
                autoCleanSchedule: ServiceStatus? = nil,
                openAtLogin: ServiceStatus? = nil) {
        self.helper = helper
        self.fullDiskAccess = fullDiskAccess
        self.accessibility = accessibility
        self.finderAutomation = finderAutomation
        self.finderExtension = finderExtension
        self.notifications = notifications
        self.backgroundRecording = backgroundRecording
        self.autoCleanSchedule = autoCleanSchedule
        self.openAtLogin = openAtLogin
    }

    /// Nothing read yet: what a freshly built screen shows before the first refresh finishes.
    public static let unknown = PermissionSnapshot()
}

/// The switches outside the permission system that decide whether a grant is needed. Every field is
/// a plain fact the app can read without touching TCC, so the rules stay unit-testable.
public struct PermissionRequirements: Equatable, Sendable {
    /// Pages whose main job needs the root Helper.
    public var fansModuleEnabled: Bool
    public var optimizeModuleEnabled: Bool
    public var startupModuleEnabled: Bool
    public var uninstallModuleEnabled: Bool
    /// Pages that read folders only Full Disk Access can see.
    public var diskModuleEnabled: Bool
    /// At least one enabled tweak declares Accessibility.
    public var accessibilityTweaksEnabled: Bool
    /// New File in Finder is on; it is the only tweak that sends Finder an Apple Event.
    public var finderAutomationTweakEnabled: Bool
    /// Finder's context menu tweak is on; its items come from the extension.
    public var finderExtensionTweakEnabled: Bool
    /// At least one alert threshold is on.
    public var alertNotificationsEnabled: Bool
    /// The Monitor module is on and the user asked for recording while MacHelper is closed.
    public var monitorModuleEnabled: Bool
    public var backgroundRecordingIntent: Bool
    /// Auto Clean is switched on while the Optimize module is on.
    public var autoCleanEnabled: Bool

    public init(fansModuleEnabled: Bool = false,
                optimizeModuleEnabled: Bool = false,
                startupModuleEnabled: Bool = false,
                uninstallModuleEnabled: Bool = false,
                diskModuleEnabled: Bool = false,
                accessibilityTweaksEnabled: Bool = false,
                finderAutomationTweakEnabled: Bool = false,
                finderExtensionTweakEnabled: Bool = false,
                alertNotificationsEnabled: Bool = false,
                monitorModuleEnabled: Bool = false,
                backgroundRecordingIntent: Bool = false,
                autoCleanEnabled: Bool = false) {
        self.fansModuleEnabled = fansModuleEnabled
        self.optimizeModuleEnabled = optimizeModuleEnabled
        self.startupModuleEnabled = startupModuleEnabled
        self.uninstallModuleEnabled = uninstallModuleEnabled
        self.diskModuleEnabled = diskModuleEnabled
        self.accessibilityTweaksEnabled = accessibilityTweaksEnabled
        self.finderAutomationTweakEnabled = finderAutomationTweakEnabled
        self.finderExtensionTweakEnabled = finderExtensionTweakEnabled
        self.alertNotificationsEnabled = alertNotificationsEnabled
        self.monitorModuleEnabled = monitorModuleEnabled
        self.backgroundRecordingIntent = backgroundRecordingIntent
        self.autoCleanEnabled = autoCleanEnabled
    }

    /// Nothing switched on: every permission is optional.
    public static let none = PermissionRequirements()
}

/// The single translation from what macOS answered to what a screen shows.
public enum PermissionResolver {
    /// Whether the feature that needs this grant is part of the current setup.
    public static func isRequired(_ id: PermissionID, requirements: PermissionRequirements) -> Bool {
        switch id {
        case .helper:
            // Fan control and Optimize's system work are the Helper's core jobs; Startup Items and
            // Uninstall only reach for it on the actions that need root.
            requirements.fansModuleEnabled || requirements.optimizeModuleEnabled
                || requirements.startupModuleEnabled || requirements.uninstallModuleEnabled
        case .fullDiskAccess:
            // Both pages lose protected folders without it: sizes are missing and their caches
            // cannot be cleaned.
            requirements.optimizeModuleEnabled || requirements.diskModuleEnabled
        case .accessibility:
            requirements.accessibilityTweaksEnabled
        case .finderAutomation:
            requirements.finderAutomationTweakEnabled
        case .finderExtension:
            requirements.finderExtensionTweakEnabled
        case .notifications:
            requirements.alertNotificationsEnabled
        case .backgroundRecording:
            requirements.monitorModuleEnabled && requirements.backgroundRecordingIntent
        case .autoCleanSchedule:
            requirements.optimizeModuleEnabled && requirements.autoCleanEnabled
        case .openAtLogin:
            // A convenience: the app works without it and never asks on its own.
            false
        }
    }

    /// The user-facing state of one grant. A problem is reported even when the grant is optional, so
    /// a screen never hides a refusal behind "you don't need this"; a grant that was simply never
    /// asked for is only worth a row when the feature that needs it is on.
    public static func state(for id: PermissionID,
                             snapshot: PermissionSnapshot,
                             requirements: PermissionRequirements) -> PermissionState {
        let required = isRequired(id, requirements: requirements)
        guard let raw = rawState(for: id, snapshot: snapshot) else { return .checking }
        switch raw {
        case .checking, .granted, .denied, .needsApproval:
            return raw
        case .notRequested, .notApplicable:
            return required ? .notRequested : .notApplicable
        }
    }

    /// Accessibility can be granted while this process still sees the old answer; the UI has to say
    /// that a relaunch finishes the job instead of sending the user back to System Settings.
    public static func requiresRelaunch(for id: PermissionID, snapshot: PermissionSnapshot) -> Bool {
        id == .accessibility && snapshot.accessibility == .restartRequired
    }

    /// Each source reduced to the six states without looking at requirements. `nil` means the source
    /// has not answered in this pass.
    public static func rawState(for id: PermissionID, snapshot: PermissionSnapshot) -> PermissionState? {
        switch id {
        case .helper:
            switch snapshot.helper {
            case .none: nil
            case .notConfigured: .notRequested
            case .running: .granted
            case .waitingForApproval: .needsApproval
            case .repairing: .checking
            case .needsRepair: .denied
            }
        case .fullDiskAccess:
            // macOS has no way to tell a refusal from a grant that was never made: a read that
            // fails with EPERM is reported as "not requested".
            snapshot.fullDiskAccess.map { $0 ? .granted : .notRequested }
        case .accessibility:
            switch snapshot.accessibility {
            case .none: nil
            case .granted: .granted
            case .restartRequired: .needsApproval
            case .notGranted: .notRequested
            }
        case .finderAutomation:
            switch snapshot.finderAutomation {
            case .none: nil
            case .granted: .granted
            case .denied: .denied
            case .undetermined: .notRequested
            // Finder is not running, so macOS has nothing to answer; a later refresh resolves it.
            case .unavailable: .notRequested
            }
        case .finderExtension:
            switch snapshot.finderExtension {
            case .none, .unknown: .checking
            case .enabled: .granted
            case .disabled: .notRequested
            }
        case .notifications:
            switch snapshot.notifications {
            case .none: nil
            case .authorized, .provisional, .ephemeral: .granted
            case .denied: .denied
            case .notDetermined: .notRequested
            }
        case .backgroundRecording:
            snapshot.backgroundRecording.flatMap(serviceState)
        case .autoCleanSchedule:
            snapshot.autoCleanSchedule.flatMap(serviceState)
        case .openAtLogin:
            snapshot.openAtLogin.flatMap(serviceState)
        }
    }

    /// Agents and login items share the platform's four statuses. `.notFound` means the plist is
    /// missing from the bundle: nothing the user can approve, so it counts as not granted.
    private static func serviceState(_ status: ServiceStatus) -> PermissionState? {
        switch status {
        case .notRegistered: .notRequested
        case .requiresApproval: .needsApproval
        case .enabled: .granted
        case .notFound: .denied
        }
    }
}

/// Display order for a permission list.
public enum PermissionOrder {
    /// Lower comes first: a grant the current setup needs and doesn't have, then one it needs and
    /// has, then optional grants that still need a decision, then the rest.
    public static func rank(isRequired: Bool, state: PermissionState) -> Int {
        if isRequired { return state == .granted ? 1 : 0 }
        switch state {
        case .denied, .needsApproval: return 2
        case .checking: return 3
        case .granted, .notRequested, .notApplicable: return 4
        }
    }

    /// Stable order for a whole list: rank first, then the order `PermissionID` declares.
    public static func sorted(_ states: [(id: PermissionID, isRequired: Bool, state: PermissionState)]) -> [PermissionID] {
        let declaration = Dictionary(uniqueKeysWithValues: PermissionID.allCases.enumerated().map { ($1, $0) })
        return states
            .sorted { a, b in
                let ra = rank(isRequired: a.isRequired, state: a.state)
                let rb = rank(isRequired: b.isRequired, state: b.state)
                if ra != rb { return ra < rb }
                return declaration[a.id, default: 0] < declaration[b.id, default: 0]
            }
            .map(\.id)
    }
}
