import HelperProtocol
import ServiceManagement
import SMCKit
import SwiftUI

/// Temporary diagnostics window for the Helper spike. Replaced by the real UI later.
struct HelperDiagnosticsView: View {
    @State private var status = HelperClient.shared.status
    @State private var log: [String] = []
    @State private var fans: [FanReading] = []

    private let client = HelperClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Helper status", value: status.label)
            if let info = CodeSigning.currentProcess() {
                LabeledContent("App signature", value: info.isAdHoc ? "ad-hoc" : "Team \(info.teamID ?? "")")
            }

            HStack {
                Button("Register") { act("register") { try client.register() } }
                Button("Open Login Items") { client.openLoginItemsSettings() }
                Button("Unregister") { act("unregister") { try await client.unregister() } }
            }
            HStack {
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
            }

            Divider()
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(Array(log.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
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
            status = client.status
        }
    }
}
