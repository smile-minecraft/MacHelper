import Sparkle
import SwiftUI

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

/// Scheduled checks that find an update don't open Sparkle's window on their own: the app shows an
/// update button instead (sidebar, menu bar panel, Settings) and the window opens when it is clicked.
@MainActor
private final class UserDriverDelegate: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        UpdaterController.shared.availableVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {}

    func standardUserDriverWillFinishUpdateSession() {
        UpdaterController.shared.availableVersion = nil
    }
}

/// Holds the Sparkle self-update controller for the app.
///
/// Sparkle's updater must live on the main thread and stay alive for the whole
/// session, so the shared instance is created from AppDelegate.init and
/// retained there. Updates are never installed silently: a found update shows the update button,
/// and installing goes through Sparkle's window with the release notes in the app's language.
@MainActor
@Observable
final class UpdaterController {
    static let shared = UpdaterController()

    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private let userDriverDelegate: UserDriverDelegate
    @ObservationIgnored private let controller: SPUStandardUpdaterController

    /// The newer version a background check found, waiting for the user; nil when up to date.
    var availableVersion: String?

    private static let silentInstallMigrationKey = "updates.silentInstallOff.v1"

    private init() {
        let delegate = UpdaterDelegate()
        let userDriverDelegate = UserDriverDelegate()
        self.delegate = delegate
        self.userDriverDelegate = userDriverDelegate
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: userDriverDelegate
        )
        // 0.3.0 and 0.3.1 turned on automatic installs at every launch, so updates went in silently
        // on quit and the user never saw them. Turn that off once; installs always ask now.
        if !UserDefaults.standard.bool(forKey: Self.silentInstallMigrationKey) {
            controller.updater.automaticallyDownloadsUpdates = false
            UserDefaults.standard.set(true, forKey: Self.silentInstallMigrationKey)
        }
        // Snapshot and export runs are short-lived copies; they never check for updates.
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--snapshot") || $0.hasPrefix("--export") }) {
            controller.startUpdater()
        }
    }

    /// Whether Sparkle checks for updates automatically.
    ///
    /// Setting this persists to the app's defaults via Sparkle. Only assign it
    /// when the user changes the setting; never write it on launch.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Checks for updates now and shows Sparkle's window: the waiting update with its release
    /// notes when the update button was clicked, otherwise the check's progress and result.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// "Update to x.y.z" — shown wherever the app has room once a background check finds a newer
/// version. Clicking opens Sparkle's window with the release notes in the app's language.
struct UpdateAvailableButton: View {
    var compact = false
    private var updater: UpdaterController { .shared }

    var body: some View {
        if let version = updater.availableVersion {
            Button { updater.checkForUpdates() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Update to \(version)")
                }
                .font(compact ? .mh(size: 11, weight: .semibold) : .mhCaption.weight(.semibold))
                .foregroundStyle(Palette.base)
                .padding(.horizontal, compact ? 8 : 10)
                .padding(.vertical, compact ? 3 : 5)
                .background(SurfaceShape(capsule: true).fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .help("See what’s new and install the update")
        }
    }
}
