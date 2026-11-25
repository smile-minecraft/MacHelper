import Storage
import SwiftUI

/// Settings row for background recording. The periodic refresh keeps the status and
/// heartbeat-derived state current while the window is open; failures stay visible instead
/// of being replaced by a success the app cannot deliver.
struct BackgroundRecordingSection: View {
    let model: BackgroundRecordingModel

    var body: some View {
        Section("Background recording") {
            Toggle("Keep recording after MacHelper quits", isOn: Binding(
                get: { model.enabledIntent },
                set: { on in
                    if on { model.enable() } else { model.disable() }
                }))
            LabeledContent("Status") {
                Text(statusText)
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.state == .pendingApproval {
                Button("Open Login Items") { PermissionFlow.shared.openGuided(.backgroundRecording) }
            }
            if let message = model.message {
                Text(message).settingsCaption(messageColor)
            }
            Text("History keeps being written once a minute after you quit MacHelper, so Health Check and the history charts have no gaps. macOS may ask you to allow MacHelper in Login Items.")
                .settingsCaption()
        }
        .onAppear { model.refresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                model.refresh()
            }
        }
    }

    /// Waiting for approval is a warning; every other message is a failure.
    private var messageColor: Color {
        model.state == .pendingApproval ? Theme.amber : Theme.rose
    }

    private var statusText: String {
        switch model.state {
        case .notEnabled: String(localized: "Off")
        case .pendingApproval: String(localized: "Waiting for approval in Login Items")
        case .running: String(localized: "Recording")
        case .stopped: String(localized: "Enabled, but the recorder is not reporting in")
        case .nothingToRecord: String(localized: "No menu bar metrics selected")
        case .failed(let reason): String(localized: "Failed: \(reason)")
        }
    }
}
