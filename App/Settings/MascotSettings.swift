import Foundation
import Observation
import SwiftUI

/// Persists the mascot reaction frequency in UserDefaults (same guard as the theme store:
/// snapshot instances never write).
@Observable
final class MascotSettingsStore: @unchecked Sendable {
    nonisolated(unsafe) static let shared = MascotSettingsStore()
    nonisolated static let frequencyKey = "mascot.frequency.v1"

    var frequency: MascotFrequency {
        didSet {
            guard frequency != oldValue, persists else { return }
            UserDefaults.standard.set(frequency.rawValue, forKey: Self.frequencyKey)
        }
    }

    @ObservationIgnored private let persists = !CommandLine.arguments.contains { $0.hasPrefix("--snapshot") }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.frequencyKey)
        frequency = raw.flatMap(MascotFrequency.init(rawValue:)) ?? .normal
    }
}

/// Settings → Appearance → Mascot: how often the slime reacts.
struct MascotSettingsSection: View {
    @Bindable private var store = MascotSettingsStore.shared

    var body: some View {
        Section {
            Picker("Mascot reactions", selection: $store.frequency) {
                Text("Quiet").tag(MascotFrequency.quiet)
                Text("Normal").tag(MascotFrequency.normal)
                Text("Lively").tag(MascotFrequency.lively)
            }
            .pickerStyle(.segmented)
            Text(store.frequency.description).settingsCaption()
        } header: { Text("Mascot") } footer: {
            Text(String(localized: "The mascot reacts to taps, hovering and dragging, and to system events like high CPU, tight memory, low disk, heat, battery, health changes, cleanup and the Helper. With Reduce Motion it only changes expression."))
                .settingsCaption()
        }
    }
}
