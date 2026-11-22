import Foundation

/// Creates an in-memory-preference-like suite with a unique name so parallel tests cannot see
/// each other's opt-in state.
func makePreferenceSuite() -> String {
    let name = "TelemetryTests.\(UUID().uuidString)"
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    return name
}

func removePreferenceSuite(_ name: String) {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
}
