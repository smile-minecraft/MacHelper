import HelperProtocol
import ServiceManagement
import SwiftUI

struct MainView: View {
    @Bindable var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var offerFullDiskAccess = FullDiskAccess.shouldOfferOnboarding
    // The agent skill question comes after the Full Disk Access one, never both at once.
    @State private var offerAgentSkill = !FullDiskAccess.shouldOfferOnboarding && AgentSkillSetup.shouldOffer

    var body: some View {
        NavigationSplitView {
            Sidebar(app: app)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            // Each page fades in, rising a few points, while the previous one fades out, so a
            // switch reads as one movement instead of a cut. Nothing moves with Reduce Motion.
            ZStack {
                detail
                    .id(app.section)
                    .transition(Motion.reduced ? .identity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .opacity))
            }
            .animation(Motion.reduced ? nil : .easeOut(duration: 0.2), value: app.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.base)
            .navigationTitle(Text(app.section.title))
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear { app.openMainWindow = { openWindow(id: "main") } }
        .sheet(isPresented: $offerFullDiskAccess, onDismiss: { if AgentSkillSetup.shouldOffer { offerAgentSkill = true } }) {
            FullDiskAccessSheet()
        }
        .sheet(isPresented: $offerAgentSkill) { AgentSkillSheet() }
        // Switching to simple mode while on an advanced page goes back to the overview.
        .onChange(of: ThemeStore.shared.settings.mode) { if !app.section.isVisible { app.section = .overview } }
    }

    @ViewBuilder private var detail: some View {
        switch app.section {
        case .overview: OverviewView(app: app)
        case .monitor: MonitorView(store: app.store)
        case .health: HealthView(app: app, model: app.healthModel)
        case .fans:
            ScrollView {
                FanControlView(model: app.fanModel, switcher: app.fanSwitcher, openHelperDiagnostics: { app.showSettings() })
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        case .optimize: OptimizeView(model: app.optimizeModel, autoClean: app.autoCleanModel)
        case .disk: DiskAnalysisView(model: app.diskModel)
        case .uninstall: UninstallView(model: app.uninstallModel)
        case .updates: UpdatesView(model: app.updatesModel)
        case .startup: StartupView(model: app.startupModel)
        }
    }
}

private struct Sidebar: View {
    @Bindable var app: AppModel

    var body: some View {
        List(selection: Binding(get: { app.section }, set: { if let s = $0 { app.section = s } })) {
            ForEach(Array(AppSection.groups.enumerated()), id: \.offset) { _, group in
                Section(group.0) {
                    ForEach(group.1) { s in
                        Label { Text(s.title) } icon: { PixelIcon(name: s.icon, size: 16) }
                            .tag(s)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter(app: app) }
    }
}

private struct SidebarFooter: View {
    let app: AppModel
    @State private var status = HelperClient.shared.status

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Circle().fill(status == .enabled ? Theme.mint : Theme.amber).frame(width: 8, height: 8)
                Text(status == .enabled ? "Helper running" : "Helper not enabled")
                    .font(.mhCaption).foregroundStyle(Palette.textMuted)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .task {
            while !Task.isCancelled {
                // The status only changes when the user turns the Helper on or off in Settings.
                let now = HelperClient.shared.status
                if now != status { status = now }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}
