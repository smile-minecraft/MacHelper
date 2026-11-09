import Sparkle

/// Receives Sparkle's install/relaunch callbacks. Kept separate because the standard updater
/// controller needs its delegate at initialization time, before `UpdaterController.shared`
/// exists.
/// Sparkle hands us an Objective-C block that must be invoked after the background recorder
/// stops. Box it so the main-actor Task can hold it without the compiler treating the block
/// as a non-Sendable value crossing actors.
private final class InstallHandlerBox: @unchecked Sendable {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
}

@MainActor
private final class UpdaterDelegate: NSObject, @preconcurrency SPUUpdaterDelegate {
    /// Sparkle is about to install an update and relaunch. Stop the background recorder first,
    /// then let Sparkle continue; the next launch resumes it only if the user still wants it.
    nonisolated func updater(_ updater: SPUUpdater,
                             shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let box = InstallHandlerBox(installHandler)
        Task { @MainActor in
            await AppModel.shared.backgroundRecording.suspendForUpdate()
            box.handler()
        }
        return true
    }

    /// If the update cycle ends without installing (cancel or error), put background recording
    /// back. A successful install relaunches, so this is only for the cancelled path.
    nonisolated func updater(_ updater: SPUUpdater,
                             didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: Error?) {
        guard error != nil else { return }
        Task { @MainActor in
            AppModel.shared.backgroundRecording.resumeAfterUpdateIfNeeded()
        }
    }
}

/// Holds the Sparkle self-update controller for the app.
///
/// Sparkle's updater must live on the main thread and stay alive for the whole
/// session, so the shared instance is created from AppDelegate.init and
/// retained there. Background downloading is on, but installing always prompts
/// (SUAutomaticallyUpdate stays off in Info.plist).
@MainActor
@Observable
final class UpdaterController {
    static let shared = UpdaterController()

    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private let controller: SPUStandardUpdaterController

    private init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyDownloadsUpdates = true
    }

    /// Whether Sparkle checks for updates automatically.
    ///
    /// Setting this persists to the app's defaults via Sparkle. Only assign it
    /// when the user changes the setting; never write it on launch.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Checks for updates now and shows Sparkle's progress UI.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
