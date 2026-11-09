import ServiceManagement
import SwiftUI

/// First-launch setup of the privileged Helper: what it is for, then install → approve → running,
/// each step with a live status. Also opened from the sidebar footer while the Helper is off.
enum HelperSetup {
    static let onboardingKey = "onboarding.helper.shown"

    /// Offered once, on a launch where the Helper isn't running; never in snapshot runs.
    static var shouldOfferOnboarding: Bool {
        !CommandLine.arguments.contains { $0.hasPrefix("--snapshot") }
            && !UserDefaults.standard.bool(forKey: onboardingKey)
            && HelperClient.shared.status != .enabled
    }
}

struct HelperSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = HelperClient.shared.status
    /// The Helper answered over XPC: approved in System Settings and actually started by launchd.
    @State private var responding = false
    @State private var working = false
    @State private var error: String?

    private var installed: Bool { status == .requiresApproval || status == .enabled }
    private var approved: Bool { status == .enabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                SlimeMascot(mood: .init(level: responding ? .good : .attention,
                                        reaction: responding ? .helperConnected : nil), cell: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up the MacHelper Helper").font(.mhTitle2).foregroundStyle(Palette.text)
                    Text("A few features need a small helper that runs with administrator rights: fan control, cleaning system caches and logs, turning system background items on or off, and reading the usage of system processes. Everything else works without it, and you can set it up later from the sidebar.")
                        .font(.mhCallout).foregroundStyle(Palette.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                step(1, done: installed, active: !installed,
                     title: "Install the Helper",
                     detail: "macOS adds it to Login Items. Nothing runs until you allow it.") {
                    Button("Install Helper") { install() }.disabled(working)
                }
                step(2, done: approved, active: installed && !approved,
                     title: "Allow it in System Settings",
                     detail: "In General → Login Items & Extensions, turn on MacHelper under “Allow in the Background”. macOS asks for your password.") {
                    Button("Open Login Items") { HelperClient.shared.openLoginItemsSettings() }
                }
                step(3, done: responding, active: approved && !responding,
                     title: "Helper is running",
                     detail: responding ? "All set. MacHelper checked that the Helper answers."
                                        : "MacHelper checks this by itself once the Helper is allowed.") {
                    EmptyView()
                }
            }
            .padding(14)
            .surface()

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.mhCaption).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if responding {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { dismiss() }
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .background(Palette.base)
        .task {
            // The approval happens in System Settings; follow it from here.
            while !Task.isCancelled && !responding {
                status = HelperClient.shared.status
                if status == .enabled {
                    responding = (try? await HelperClient.shared.handshake()) != nil
                }
                if !responding { try? await Task.sleep(for: .seconds(1.5)) }
            }
        }
        .onDisappear { UserDefaults.standard.set(true, forKey: HelperSetup.onboardingKey) }
    }

    private func install() {
        working = true
        error = nil
        do {
            try HelperClient.shared.register()
            status = HelperClient.shared.status
            // Registering normally needs approval; take the user straight to the switch.
            if status == .requiresApproval { HelperClient.shared.openLoginItemsSettings() }
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }

    @ViewBuilder
    private func step(_ number: Int, done: Bool, active: Bool, title: LocalizedStringKey, detail: LocalizedStringKey,
                      @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Theme.mint : active ? Palette.text.opacity(0.12) : Palette.text.opacity(0.06))
                if done {
                    Image(systemName: "checkmark").font(.mhCaption.weight(.bold)).foregroundStyle(Palette.base)
                } else {
                    Text(verbatim: "\(number)").font(.mhCaption.weight(.semibold))
                        .foregroundStyle(active ? Palette.text : Palette.textMuted)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.mhCallout.weight(.semibold))
                    .foregroundStyle(done || active ? Palette.text : Palette.textMuted)
                Text(detail).font(.mhCaption).foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if active { action() }
        }
    }
}
