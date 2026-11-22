import SwiftUI
import Telemetry

/// Lives in the General settings tab. The switch defaults to off and the sample payload is built
/// from the same schema the client uses, so users see exactly what would be sent.
struct TelemetrySettingsView: View {
    let client: AppTelemetryClient

    @State private var enabled = TelemetryPreferences().isEnabled
    @State private var showsPreview = false

    private let samplePayload = AppTelemetryClient.samplePayloadJSON()

    var body: some View {
        Section("Privacy & Diagnostics") {
            Toggle("Share anonymous usage & performance diagnostics", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    Task { await client.setEnabled(on) }
                }
            Text("Stays off unless you turn it on. Sends your app version, macOS version, chip family, feature counts and coarse performance buckets. Never sends file paths, process names, disk contents or personal data. Turning it off clears the anonymous ID and the pending queue.")
                .settingsCaption()
            DisclosureGroup("Preview Sample Payload", isExpanded: $showsPreview) {
                ScrollView {
                    Text(samplePayload)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
    }
}
