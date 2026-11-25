import Testing
@testable import Permissions

/// Every branch of the translation from a source's answer to the state a permission screen shows.
@Suite struct PermissionResolverTests {
    private let nothing = PermissionRequirements()

    // MARK: Unread sources

    @Test func anUnreadSourceIsChecking() {
        for id in PermissionID.allCases {
            #expect(PermissionResolver.state(for: id, snapshot: .unknown, requirements: nothing) == .checking)
        }
    }

    // MARK: Helper

    @Test func helperStatesFollowTheHealthMonitor() {
        func state(_ s: HelperPermissionStatus) -> PermissionState {
            PermissionResolver.state(for: .helper, snapshot: PermissionSnapshot(helper: s), requirements: nothing)
        }
        #expect(state(.notConfigured) == .notApplicable)
        #expect(state(.running) == .granted)
        #expect(state(.waitingForApproval) == .needsApproval)
        #expect(state(.repairing) == .checking)
        #expect(state(.needsRepair) == .denied)
        // A running Helper is granted whatever the switches say.
        var running = PermissionSnapshot()
        running.helper = .running
        #expect(PermissionResolver.state(for: .helper, snapshot: running, requirements: .none) == .granted)
    }

    // MARK: Full Disk Access

    @Test func fullDiskAccessIsNotRequestedUntilTheProbeCanRead() {
        #expect(PermissionResolver.state(for: .fullDiskAccess,
                                         snapshot: PermissionSnapshot(fullDiskAccess: true),
                                         requirements: nothing) == .granted)
        // The probe only fails with EPERM, so "false" is a grant that was never made. The state
        // follows the requirement: asked for when Optimize or Disk Analysis is on, else not needed.
        #expect(PermissionResolver.state(for: .fullDiskAccess,
                                         snapshot: PermissionSnapshot(fullDiskAccess: false),
                                         requirements: nothing) == .notApplicable)
        var optimize = PermissionRequirements()
        optimize.optimizeModuleEnabled = true
        #expect(PermissionResolver.state(for: .fullDiskAccess,
                                         snapshot: PermissionSnapshot(fullDiskAccess: false),
                                         requirements: optimize) == .notRequested)
    }

    // MARK: Accessibility

    @Test func accessibilityKeepsItsRestartCase() {
        #expect(PermissionResolver.state(for: .accessibility,
                                         snapshot: PermissionSnapshot(accessibility: .granted),
                                         requirements: nothing) == .granted)
        // The grant exists but this process cannot use it: the UI has to offer a relaunch, so the
        // state is an approval step rather than "denied".
        #expect(PermissionResolver.state(for: .accessibility,
                                         snapshot: PermissionSnapshot(accessibility: .restartRequired),
                                         requirements: nothing) == .needsApproval)
        #expect(PermissionResolver.state(for: .accessibility,
                                         snapshot: PermissionSnapshot(accessibility: .notGranted),
                                         requirements: nothing) == .notApplicable)
    }

    @Test func onlyAccessibilityReportsAnExistingGrantAfterRelaunch() {
        let restart = PermissionSnapshot(accessibility: .restartRequired)
        for id in PermissionID.allCases {
            #expect(PermissionResolver.requiresRelaunch(for: id, snapshot: restart) == (id == .accessibility))
            #expect(!PermissionResolver.requiresRelaunch(for: id, snapshot: .unknown))
        }
        #expect(!PermissionResolver.requiresRelaunch(for: .accessibility,
                                                     snapshot: PermissionSnapshot(accessibility: .granted)))
    }

    // MARK: Finder automation

    @Test func finderAutomationStates() {
        #expect(PermissionResolver.state(for: .finderAutomation,
                                         snapshot: PermissionSnapshot(finderAutomation: .granted),
                                         requirements: nothing) == .granted)
        // A refusal stays visible even when the tweak that needs it is off.
        #expect(PermissionResolver.state(for: .finderAutomation,
                                         snapshot: PermissionSnapshot(finderAutomation: .denied),
                                         requirements: nothing) == .denied)
        #expect(PermissionResolver.state(for: .finderAutomation,
                                         snapshot: PermissionSnapshot(finderAutomation: .undetermined),
                                         requirements: nothing) == .notApplicable)
        var newFile = PermissionRequirements()
        newFile.finderAutomationTweakEnabled = true
        #expect(PermissionResolver.state(for: .finderAutomation,
                                         snapshot: PermissionSnapshot(finderAutomation: .undetermined),
                                         requirements: newFile) == .notRequested)
        // Finder not running: macOS has nothing to answer, so it reads as "not asked yet".
        #expect(PermissionResolver.state(for: .finderAutomation,
                                         snapshot: PermissionSnapshot(finderAutomation: .unavailable),
                                         requirements: newFile) == .notRequested)
    }

    // MARK: Finder extension

    @Test func finderExtensionStates() {
        #expect(PermissionResolver.state(for: .finderExtension,
                                         snapshot: PermissionSnapshot(finderExtension: .enabled),
                                         requirements: nothing) == .granted)
        #expect(PermissionResolver.state(for: .finderExtension,
                                         snapshot: PermissionSnapshot(finderExtension: .disabled),
                                         requirements: nothing) == .notApplicable)
        var contextMenu = PermissionRequirements()
        contextMenu.finderExtensionTweakEnabled = true
        #expect(PermissionResolver.state(for: .finderExtension,
                                         snapshot: PermissionSnapshot(finderExtension: .disabled),
                                         requirements: contextMenu) == .notRequested)
        // PlugInKit could not be asked; the next refresh tries again.
        #expect(PermissionResolver.state(for: .finderExtension,
                                         snapshot: PermissionSnapshot(finderExtension: .unknown),
                                         requirements: contextMenu) == .checking)
    }

    // MARK: Notifications

    @Test func notificationStates() {
        func state(_ s: NotificationAuthorizationStatus) -> PermissionState {
            PermissionResolver.state(for: .notifications, snapshot: PermissionSnapshot(notifications: s), requirements: nothing)
        }
        #expect(state(.authorized) == .granted)
        #expect(state(.provisional) == .granted)
        #expect(state(.ephemeral) == .granted)
        #expect(state(.denied) == .denied)
        #expect(state(.notDetermined) == .notApplicable)
        var alerts = PermissionRequirements()
        alerts.alertNotificationsEnabled = true
        #expect(PermissionResolver.state(for: .notifications,
                                         snapshot: PermissionSnapshot(notifications: .notDetermined),
                                         requirements: alerts) == .notRequested)
    }

    // MARK: Agents and login items

    @Test func serviceStatesAreSharedByAgentsAndLoginItems() {
        func snapshot(_ status: ServiceStatus, for id: PermissionID) -> PermissionSnapshot {
            var snapshot = PermissionSnapshot()
            switch id {
            case .backgroundRecording: snapshot.backgroundRecording = status
            case .autoCleanSchedule: snapshot.autoCleanSchedule = status
            default: snapshot.openAtLogin = status
            }
            return snapshot
        }
        // The two agents are required once their module and switch are on; the login item never is.
        var agentRequirements = PermissionRequirements()
        agentRequirements.monitorModuleEnabled = true
        agentRequirements.backgroundRecordingIntent = true
        agentRequirements.optimizeModuleEnabled = true
        agentRequirements.autoCleanEnabled = true

        for id: PermissionID in [.backgroundRecording, .autoCleanSchedule] {
            #expect(PermissionResolver.state(for: id, snapshot: snapshot(.notRegistered, for: id),
                                             requirements: agentRequirements) == .notRequested)
            #expect(PermissionResolver.state(for: id, snapshot: snapshot(.requiresApproval, for: id),
                                             requirements: agentRequirements) == .needsApproval)
            #expect(PermissionResolver.state(for: id, snapshot: snapshot(.enabled, for: id),
                                             requirements: agentRequirements) == .granted)
            #expect(PermissionResolver.state(for: id, snapshot: snapshot(.notFound, for: id),
                                             requirements: agentRequirements) == .denied)
            // Off: the agent a user never registered is not part of the setup.
            #expect(PermissionResolver.state(for: id, snapshot: snapshot(.notRegistered, for: id),
                                             requirements: nothing) == .notApplicable)
        }

        #expect(PermissionResolver.state(for: .openAtLogin, snapshot: snapshot(.notRegistered, for: .openAtLogin),
                                         requirements: nothing) == .notApplicable)
        #expect(PermissionResolver.state(for: .openAtLogin, snapshot: snapshot(.requiresApproval, for: .openAtLogin),
                                         requirements: nothing) == .needsApproval)
    }

    @Test func anEnabledAgentIsGrantedWhateverTheSwitchesSay() {
        var snapshot = PermissionSnapshot()
        snapshot.backgroundRecording = .enabled
        snapshot.autoCleanSchedule = .enabled
        snapshot.openAtLogin = .enabled
        for id: PermissionID in [.backgroundRecording, .autoCleanSchedule, .openAtLogin] {
            #expect(PermissionResolver.state(for: id, snapshot: snapshot, requirements: .none) == .granted)
        }
    }

    // MARK: Requirements

    @Test func helperIsRequiredByThePagesThatCannotWorkWithoutIt() {
        func required(_ mutate: (inout PermissionRequirements) -> Void) -> Bool {
            var r = PermissionRequirements()
            mutate(&r)
            return PermissionResolver.isRequired(.helper, requirements: r)
        }
        #expect(!required { _ in })
        #expect(required { $0.fansModuleEnabled = true })
        #expect(required { $0.optimizeModuleEnabled = true })
        #expect(required { $0.startupModuleEnabled = true })
        #expect(required { $0.uninstallModuleEnabled = true })
        // Pages that only read a public list do not need the Helper by themselves.
        #expect(!required { $0.diskModuleEnabled = true })
        #expect(!required { $0.monitorModuleEnabled = true })
    }

    @Test func fullDiskAccessIsRequiredByOptimizeAndDiskAnalysis() {
        var r = PermissionRequirements()
        #expect(!PermissionResolver.isRequired(.fullDiskAccess, requirements: r))
        r.optimizeModuleEnabled = true
        #expect(PermissionResolver.isRequired(.fullDiskAccess, requirements: r))
        r = PermissionRequirements()
        r.diskModuleEnabled = true
        #expect(PermissionResolver.isRequired(.fullDiskAccess, requirements: r))
    }

    @Test func tweakPermissionsFollowTheEnabledTweaks() {
        var r = PermissionRequirements()
        #expect(!PermissionResolver.isRequired(.accessibility, requirements: r))
        #expect(!PermissionResolver.isRequired(.finderAutomation, requirements: r))
        #expect(!PermissionResolver.isRequired(.finderExtension, requirements: r))
        r.accessibilityTweaksEnabled = true
        r.finderAutomationTweakEnabled = true
        r.finderExtensionTweakEnabled = true
        #expect(PermissionResolver.isRequired(.accessibility, requirements: r))
        #expect(PermissionResolver.isRequired(.finderAutomation, requirements: r))
        #expect(PermissionResolver.isRequired(.finderExtension, requirements: r))
    }

    @Test func notificationsFollowTheAlertThresholds() {
        var r = PermissionRequirements()
        #expect(!PermissionResolver.isRequired(.notifications, requirements: r))
        r.alertNotificationsEnabled = true
        #expect(PermissionResolver.isRequired(.notifications, requirements: r))
    }

    @Test func backgroundRecordingNeedsTheModuleAndTheIntent() {
        var r = PermissionRequirements()
        #expect(!PermissionResolver.isRequired(.backgroundRecording, requirements: r))
        r.monitorModuleEnabled = true
        #expect(!PermissionResolver.isRequired(.backgroundRecording, requirements: r))
        r.backgroundRecordingIntent = true
        #expect(PermissionResolver.isRequired(.backgroundRecording, requirements: r))
        r.monitorModuleEnabled = false
        #expect(!PermissionResolver.isRequired(.backgroundRecording, requirements: r))
    }

    @Test func autoCleanNeedsTheModuleAndTheSwitch() {
        var r = PermissionRequirements()
        #expect(!PermissionResolver.isRequired(.autoCleanSchedule, requirements: r))
        r.optimizeModuleEnabled = true
        #expect(!PermissionResolver.isRequired(.autoCleanSchedule, requirements: r))
        r.autoCleanEnabled = true
        #expect(PermissionResolver.isRequired(.autoCleanSchedule, requirements: r))
        r.optimizeModuleEnabled = false
        #expect(!PermissionResolver.isRequired(.autoCleanSchedule, requirements: r))
    }

    @Test func openAtLoginIsNeverRequired() {
        var r = PermissionRequirements()
        #expect(!PermissionResolver.isRequired(.openAtLogin, requirements: r))
        r.fansModuleEnabled = true
        r.optimizeModuleEnabled = true
        r.diskModuleEnabled = true
        r.monitorModuleEnabled = true
        r.backgroundRecordingIntent = true
        r.autoCleanEnabled = true
        r.alertNotificationsEnabled = true
        r.accessibilityTweaksEnabled = true
        #expect(!PermissionResolver.isRequired(.openAtLogin, requirements: r))
    }

    // MARK: Optional grants

    @Test func anOptionalGrantThatWasNeverAskedForIsNotApplicable() {
        #expect(PermissionResolver.state(for: .accessibility,
                                         snapshot: PermissionSnapshot(accessibility: .notGranted),
                                         requirements: nothing) == .notApplicable)
    }

    @Test func aGrantIsReportedAsGrantedEvenWhenTheFeatureIsOff() {
        #expect(PermissionResolver.state(for: .fullDiskAccess,
                                         snapshot: PermissionSnapshot(fullDiskAccess: true),
                                         requirements: nothing) == .granted)
        #expect(PermissionResolver.state(for: .finderExtension,
                                         snapshot: PermissionSnapshot(finderExtension: .enabled),
                                         requirements: nothing) == .granted)
    }

    @Test func aRefusalIsReportedEvenWhenTheFeatureIsOff() {
        #expect(PermissionResolver.state(for: .notifications,
                                         snapshot: PermissionSnapshot(notifications: .denied),
                                         requirements: nothing) == .denied)
        #expect(PermissionResolver.state(for: .finderAutomation,
                                         snapshot: PermissionSnapshot(finderAutomation: .denied),
                                         requirements: nothing) == .denied)
    }

    // MARK: Ordering

    @Test func orderRankPutsNeededMissingGrantsFirst() {
        #expect(PermissionOrder.rank(isRequired: true, state: .denied) == 0)
        #expect(PermissionOrder.rank(isRequired: true, state: .needsApproval) == 0)
        #expect(PermissionOrder.rank(isRequired: true, state: .notRequested) == 0)
        #expect(PermissionOrder.rank(isRequired: true, state: .checking) == 0)
        #expect(PermissionOrder.rank(isRequired: true, state: .granted) == 1)
        #expect(PermissionOrder.rank(isRequired: false, state: .denied) == 2)
        #expect(PermissionOrder.rank(isRequired: false, state: .needsApproval) == 2)
        #expect(PermissionOrder.rank(isRequired: false, state: .checking) == 3)
        #expect(PermissionOrder.rank(isRequired: false, state: .granted) == 4)
        #expect(PermissionOrder.rank(isRequired: false, state: .notRequested) == 4)
        #expect(PermissionOrder.rank(isRequired: false, state: .notApplicable) == 4)
    }

    @Test func orderSortsByRankThenDeclarationOrder() {
        let sorted = PermissionOrder.sorted([
            (id: .openAtLogin, isRequired: false, state: .granted),
            (id: .notifications, isRequired: true, state: .notRequested),
            (id: .helper, isRequired: true, state: .notRequested),
            (id: .finderAutomation, isRequired: false, state: .denied),
            (id: .fullDiskAccess, isRequired: true, state: .granted),
            (id: .accessibility, isRequired: true, state: .needsApproval),
            (id: .backgroundRecording, isRequired: false, state: .notApplicable),
        ])
        #expect(sorted == [.helper, .accessibility, .notifications,
                           .fullDiskAccess,
                           .finderAutomation,
                           .backgroundRecording, .openAtLogin])
    }

    @Test func orderIsStableForAnEntirelyUnreadList() {
        let all = PermissionID.allCases.map { (id: $0, isRequired: false, state: PermissionState.checking) }
        #expect(PermissionOrder.sorted(all) == PermissionID.allCases)
    }
}
