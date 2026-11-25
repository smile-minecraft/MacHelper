import SwiftUI

/// A compact, high-contrast warning at the top of the detail area. It explains what
/// happened in plain language and offers the one action that can fix it. Dismissing it
/// only hides the banner for this session; the sidebar indicator keeps warning.
struct HelperRecoveryBanner: View {
    @Bindable private var monitor = HelperHealthMonitor.shared

    var body: some View {
        if monitor.shouldShowBanner {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.mhCallout)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monitor.bannerTitle)
                            .font(.mhCallout.weight(.semibold))
                            .foregroundStyle(Palette.text)
                        Text(monitor.bannerMessage)
                            .font(.mhCaption)
                            .foregroundStyle(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let error = monitor.repairError {
                            Text(error)
                                .font(.mhCaption)
                                .foregroundStyle(Theme.rose)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Repair error: \(error)")
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    if monitor.state.isRepairable {
                        Button {
                            Task { await monitor.reinstallNow() }
                        } label: {
                            HStack(spacing: 6) {
                                if monitor.isRepairing { ProgressView().controlSize(.small) }
                                Text("Repair Helper")
                            }
                        }
                        .disabled(monitor.isRepairing)
                    }
                    // Opens Login Items with the floating guide beside it.
                    Button("Open Login Items") { PermissionFlow.shared.openGuided(.helper) }
                    Button("Permission Details…") { PermissionFlow.shared.showInSettings(.helper) }
                    Spacer()
                    Button("Dismiss") { monitor.dismissBanner() }
                }
                .font(.mhCaption.weight(.medium))
            }
            .padding(14)
            .background(Palette.card)
            .surface()
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
    }

    private var accent: Color {
        switch monitor.footerTone {
        case .alert: Theme.rose
        case .warning: Theme.amber
        case .healthy, .neutral: Theme.amber
        }
    }
}
