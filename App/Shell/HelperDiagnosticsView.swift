import HelperProtocol
import ServiceManagement
import SMCKit
import SwiftUI

/// Settings → Helper: what the Helper is for, whether it runs, and the one thing to do next.
/// The raw tools (register, handshake, reading fans through the Helper) sit under Diagnostics.
struct HelperDiagnosticsView: View {
    @State private var status = HelperClient.shared.status
    @State private var log: [String] = []
    @State private var fans: [FanReading] = []
    @State private var showSetup = false
    @State private var showDiagnostics = false
    /// Verified health, shared with the banner and sidebar: "enabled" in Login Items does
    /// not prove the Helper answers, so this view must show what XPC actually observed.
    @Bindable private var health = HelperHealthMonitor.shared

    private let client = HelperClient.shared

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(statusColor)
                        .frame(width: 34)
                    Text("A few features need a small helper that runs with administrator rights: fan control, cleaning system caches and logs, turning system background items on or off, and reading the usage of system processes. Everything else works without it, and you can set it up later from the sidebar.")
                        .settingsCaption()
                }
                .padding(.vertical, 4)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(health.summaryLabel).foregroundStyle(Palette.text)
                    }
                }
                switch status {
                case .enabled:
                    Button("Turn Off Helper", role: .destructive) { act("unregister") { try await client.unregister() } }
                case .requiresApproval:
                    Text("In General → Login Items & Extensions, turn on MacHelper under “Allow in the Background”. macOS asks for your password.")
                        .settingsCaption()
                    Button("Open Login Items") { client.openLoginItemsSettings() }
                case .notFound:
                    Text("The Helper is missing from this copy of MacHelper. Reinstall the app to restore it.")
                        .settingsCaption(Theme.amber)
                default:
                    Button("Set up Helper…") { showSetup = true }
                }
                if health.state.needsAttention {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(health.bannerMessage).settingsCaption(Theme.amber)
                        HStack(spacing: 8) {
                            if health.state.isRepairable {
                                Button {
                                    Task { await health.reinstallNow() }
                                } label: {
                                    HStack(spacing: 5) {
                                        if health.isRepairing { ProgressView().controlSize(.small) }
                                        Text("Repair / Reinstall Helper")
                                    }
                                }
                                .disabled(health.isRepairing)
                            }
                            Button("Open Login Items") { health.openLoginItems() }
                        }
                        if let error = health.repairError {
                            Text(error).settingsCaption(Theme.rose)
                        }
                    }
                }
            } header: { Text("Helper") }

            Section {
                DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                    if let info = CodeSigning.currentProcess() {
                        LabeledContent("App signature", value: info.isAdHoc ? "ad-hoc" : "Team \(info.teamID ?? "")")
                    }
                    LabeledContent("Helper status", value: status.label)
                    HStack {
                        Button("Register") { act("register") { try client.register() } }
                        Button("Unregister") { act("unregister") { try await client.unregister() } }
                        Button("Handshake") {
                            act("handshake") {
                                let r = try await client.handshake()
                                append("helper protocol v\(r.protocolVersion), version \(r.helperVersion)")
                            }
                        }
                        Button("Read fans via Helper") {
                            act("readFans") { fans = try await client.readFans() }
                        }
                    }
                    ForEach(fans) { f in
                        Text("Fan \(f.id): \(Int(f.actualRPM)) rpm (\(Int(f.minRPM))–\(Int(f.maxRPM))), \(String(describing: f.mode))")
                            .monospacedDigit()
                            .foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if log.isEmpty {
                        Text("No data yet").settingsCaption()
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(log.enumerated()), id: \.offset) {
                                    Text($0.element)
                                        .font(.mhCaption.monospaced())
                                        .foregroundStyle(Palette.text)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 140)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .settingsSurface()
        .sheet(isPresented: $showSetup, onDismiss: { status = client.currentStatus }) { HelperSetupSheet() }
        .task {
            // Approval happens in System Settings; follow it while this tab is open.
            while !Task.isCancelled {
                let now = client.currentStatus
                if now != status { status = now }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var statusColor: Color {
        if health.state.needsAttention {
            switch health.footerTone {
            case .alert: Theme.rose
            case .warning, .healthy, .neutral: Theme.amber
            }
        } else {
            switch status {
            case .enabled: Theme.mint
            case .requiresApproval, .notFound: Theme.amber
            default: Palette.textMuted
            }
        }
    }

    private func append(_ line: String) { log.append(line) }

    private func act(_ name: String, _ body: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await body()
                append("\(name): ok")
            } catch {
                append("\(name): \(error)")
            }
            status = client.currentStatus
        }
    }
}
