import Permissions
import SwiftUI
import UserNotifications

/// Settings → Alerts: one switch per condition, with its threshold on the row below (dimmed while
/// the switch is off, so "above…" never reads as unfinished).
struct AlertSettingsSection: View {
    @Bindable var alerts: AlertCenter
    /// The explanation shown before macOS asks about notifications.
    @State private var prePrompt: PermissionID?
    @State private var sendTestAfterPrompt = false

    var body: some View {
        Section {
            Toggle("CPU temperature above", isOn: alertSwitch(\.temperatureEnabled))
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
            Toggle("Memory pressure becomes critical", isOn: alertSwitch(\.memoryPressureEnabled))
            Toggle("Free disk space below", isOn: alertSwitch(\.diskEnabled))
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
                        .animatesTextChanges(alerts.settings.cooldownMinutes)
                    Spacer()
                    Button("Send Test Notification") { askIfUndecided(thenSendTest: true) }
                }
                Group {
                    if alerts.authorizationDenied {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Notifications are turned off for MacHelper in System Settings → Notifications.")
                                .settingsCaption(Theme.amber)
                            Spacer()
                            Button("Open Notification Settings") { PermissionFlow.shared.openGuided(.notifications) }
                        }
                    }
                }
                .transition(Motion.stateSwap)
                .animatesStateChanges(alerts.authorizationDenied)
            }
            // On the footer, one view, so the sheet is attached once and not to every row.
            .sheet(item: $prePrompt) { id in
                PermissionPrePromptSheet(id: id) {
                    _ = await alerts.authorizationStatus()
                    if sendTestAfterPrompt, !alerts.authorizationDenied { alerts.sendTest() }
                    sendTestAfterPrompt = false
                }
            }
            .task { _ = await alerts.authorizationStatus() }
        }
    }

    /// An alert switch. Turning one on is the moment MacHelper needs notifications, so that is when
    /// it explains and asks, and only if macOS has not been asked before.
    private func alertSwitch(_ keyPath: WritableKeyPath<AlertSettings, Bool>) -> Binding<Bool> {
        Binding(get: { alerts.settings[keyPath: keyPath] },
                set: { on in
                    alerts.settings[keyPath: keyPath] = on
                    if on { askIfUndecided(thenSendTest: false) }
                })
    }

    private func askIfUndecided(thenSendTest: Bool) {
        Task {
            if await alerts.authorizationStatus() == .notDetermined {
                sendTestAfterPrompt = thenSendTest
                prePrompt = .notifications
            } else if thenSendTest {
                alerts.sendTest()
            }
        }
    }
}
