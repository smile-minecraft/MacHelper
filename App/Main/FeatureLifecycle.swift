import Foundation
import SettingsPortability

/// Reconciles background work with the current feature switches. Re-running with the same state is
/// safe: each model converges on the state it was given instead of replaying a toggle history.
///
/// Only the real app instance drives background services and the fans. Snapshot and screenshot
/// instances run next to it and must never register agents or touch the Helper, so nothing here
/// runs until AppDelegate calls `start` from its non-snapshot launch path.
@MainActor
enum FeatureLifecycle {
    private static var isLive = false

    static func start(_ app: AppModel = .shared) {
        isLive = true
        apply(FeatureStore.shared.features, to: app)
    }

    static func apply(_ features: FeatureSet, to app: AppModel = .shared) {
        guard isLive else { return }
        app.backgroundRecording.applyModuleAvailability(features.isEnabled(.monitor))
        app.autoCleanModel.applyModuleAvailability(features.isEnabled(.optimize))
        app.fanSwitcher.applyModuleAvailability(features.isEnabled(.fans))
        app.fanModel.applyModuleAvailability(features.isEnabled(.fans))
        app.updatesModel.applyModuleAvailability(features.isEnabled(.updates))
        if !features.isEnabled(.disk) { app.diskModel.trimCachedTrees() }
    }
}
