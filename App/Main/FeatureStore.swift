import Foundation
import Observation
import SettingsPortability

/// The app-wide switchboard for tool modules. The stored value is a small JSON override set;
/// an absent or unreadable value means "everything at its default".
@MainActor
@Observable
final class FeatureStore {
    static let shared = FeatureStore()
    static nonisolated let key = "features.v1"

    private(set) var features: FeatureSet
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.features = Self.load(from: defaults)
    }

    func isEnabled(_ module: FeatureModule) -> Bool { features.isEnabled(module) }

    func setEnabled(_ module: FeatureModule, _ enabled: Bool) {
        guard features.isEnabled(module) != enabled else { return }
        features.setEnabled(module, enabled)
        persist()
        FeatureLifecycle.apply(features, to: AppModel.shared)
    }

    /// Re-reads after a settings import; the backup applies to the same defaults domain.
    func reload() {
        let restored = Self.load(from: defaults)
        guard restored != features else { return }
        features = restored
        FeatureLifecycle.apply(features, to: AppModel.shared)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(features) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func load(from defaults: UserDefaults) -> FeatureSet {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(FeatureSet.self, from: data)
        else { return FeatureSet() }
        return decoded
    }
}
