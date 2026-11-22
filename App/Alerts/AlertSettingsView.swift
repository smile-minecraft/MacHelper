import SwiftUI

/// Settings → Alerts: one switch per condition, with its threshold on the row below (dimmed while
/// the switch is off, so "above…" never reads as unfinished).
struct AlertSettingsSection: View {
    @Bindable var alerts: AlertCenter

    var body: some View {
        Section {
            Toggle("CPU temperature above", isOn: $alerts.settings.temperatureEnabled)
            Stepper(value: $alerts.settings.temperatureCelsius, in: 70...105, step: 5) {
                LabeledContent("Threshold") {
                    Text(Fmt.celsius(alerts.settings.temperatureCelsius)).monospacedDigit()
                        .foregroundStyle(alerts.settings.temperatureEnabled ? Palette.text : Palette.textFaint)
                }
            }
            .padding(.leading, 16)
            .accessibilityLabel(Text("CPU temperature above"))
            .accessibilityValue(Text(Fmt.celsius(alerts.settings.temperatureCelsius)))
            .disabled(!alerts.settings.temperatureEnabled)
            .animatesStateChanges(alerts.settings.temperatureEnabled)
            Toggle("Memory pressure becomes critical", isOn: $alerts.settings.memoryPressureEnabled)
            Toggle("Free disk space below", isOn: $alerts.settings.diskEnabled)
            Stepper(value: $alerts.settings.diskFreeGB, in: 5...200, step: 5) {
                LabeledContent("Threshold") {
                    Text("\(Int(alerts.settings.diskFreeGB)) GB").monospacedDigit()
                        .foregroundStyle(alerts.settings.diskEnabled ? Palette.text : Palette.textFaint)
                }
            }
            .padding(.leading, 16)
            .accessibilityLabel(Text("Free disk space below"))
            .accessibilityValue(Text("\(Int(alerts.settings.diskFreeGB)) GB"))
            .disabled(!alerts.settings.diskEnabled)
            .animatesStateChanges(alerts.settings.diskEnabled)
        } header: {
            Text("Notify me when")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("At most one notification of each kind every \(Int(alerts.settings.cooldownMinutes)) minutes.")
                        .settingsCaption()
                        .id(alerts.settings.cooldownMinutes)
                        .transition(Motion.stateSwap)
                        .animatesStateChanges(alerts.settings.cooldownMinutes)
                    Spacer()
                    Button("Send Test Notification") { alerts.sendTest() }
                }
                Group {
                    if alerts.authorizationDenied {
                        Text("Notifications are turned off for MacHelper in System Settings → Notifications.")
                            .settingsCaption(Theme.amber)
                    }
                }
                .transition(Motion.stateSwap)
                .animatesStateChanges(alerts.authorizationDenied)
            }
        }
    }
}
