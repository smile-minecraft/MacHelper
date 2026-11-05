import SwiftUI

struct AlertSettingsSection: View {
    @Bindable var alerts: AlertCenter

    var body: some View {
        Section("Alerts") {
            HStack {
                Toggle("CPU temperature above", isOn: $alerts.settings.temperatureEnabled)
                Spacer()
                Stepper(value: $alerts.settings.temperatureCelsius, in: 70...105, step: 5) {
                    Text(Fmt.celsius(alerts.settings.temperatureCelsius)).monospacedDigit()
                }
                .accessibilityLabel(Text("CPU temperature above"))
                .accessibilityValue(Text(Fmt.celsius(alerts.settings.temperatureCelsius)))
                .disabled(!alerts.settings.temperatureEnabled)
            }
            Toggle("Memory pressure becomes critical", isOn: $alerts.settings.memoryPressureEnabled)
            HStack {
                Toggle("Free disk space below", isOn: $alerts.settings.diskEnabled)
                Spacer()
                Stepper(value: $alerts.settings.diskFreeGB, in: 5...200, step: 5) {
                    Text("\(Int(alerts.settings.diskFreeGB)) GB").monospacedDigit()
                }
                .accessibilityLabel(Text("Free disk space below"))
                .accessibilityValue(Text("\(Int(alerts.settings.diskFreeGB)) GB"))
                .disabled(!alerts.settings.diskEnabled)
            }
            HStack {
                Text("At most one notification of each kind every \(Int(alerts.settings.cooldownMinutes)) minutes.")
                    .settingsCaption()
                Spacer()
                Button("Send Test Notification") { alerts.sendTest() }
            }
            if alerts.authorizationDenied {
                Text("Notifications are turned off for MacHelper in System Settings → Notifications.")
                    .settingsCaption(Theme.amber)
            }
        }
    }
}
