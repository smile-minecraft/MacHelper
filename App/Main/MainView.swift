import HelperProtocol
import ServiceManagement
import SwiftUI

struct MainView: View {
    @Bindable var app: AppModel
    @Environment(\.openWindow) private var openWindow
    /// The welcome guide: opens by itself on first launch and again from Help → Welcome Guide.
    @Bindable private var onboarding = OnboardingCenter.shared
    /// The Helper setup guide, opened by hand from the sidebar footer.
    @State private var showHelperSetup = false

    var body: some View {
        NavigationSplitView {
            Sidebar(app: app, setUpHelper: { showHelperSetup = true })
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                HelperRecoveryBanner()
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                // The previous page leaves at once and the new one fades in, rising a few points, so a
                // switch reads as one movement and two heavy pages are never blended mid-fade.
                // With Reduce Motion it is a plain fade.
                ZStack {
                    detail
                        .id(app.section)
                        .onAppear { PageLoadProbe.mark(app.section, "render") }
                        .transition(Motion.pageIn)
                }
                .animation(Motion.pageSwitch, value: app.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Palette.base)
            .navigationTitle(Text(app.section.title))
            .modifier(SteadyTitleBar())
        }
        .frame(minWidth: 980, minHeight: 640)
        // Single-variant themes and the Light / Dark setting force their scheme on the window.
        .themeColorScheme()
        .onAppear {
            app.openMainWindow = { openWindow(id: "main") }
            onboarding.presentIfNeeded()
        }
        .onChange(of: app.section) { _, section in
            // The timing probe is inert unless `--measure-pages` is running.
            guard PageLoadProbe.active else { return }
            DispatchQueue.main.async { PageLoadProbe.mark(section, "render") }
        }
        .sheet(isPresented: $onboarding.isPresented, onDismiss: { OnboardingLifecycle.markCompleted() }) {
            OnboardingFlowView(finish: { onboarding.dismissed() })
        }
        .sheet(isPresented: $showHelperSetup) { HelperSetupSheet() }
        // Switching to simple mode while on an advanced page goes back to the overview.
        .onChange(of: ThemeStore.shared.settings.mode) { if !app.section.isVisible { app.section = .overview } }
    }

    @ViewBuilder private var detail: some View {
        switch app.section {
        case .overview: OverviewView(app: app)
        case .monitor: MonitorView(store: app.store, app: app)
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

/// On macOS 26 the title bar's background follows whatever scroll view sits under it. During a
/// page switch the old page leaves before the new one has faded in, so for a frame or two there is
/// none and the bar flashed off and on. Hiding the bar's own background keeps it the same on every
/// page and in between; scrolled content still fades under the title with the system edge effect.
private struct SteadyTitleBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

private struct Sidebar: View {
    @Bindable var app: AppModel
    var setUpHelper: () -> Void

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
        .safeAreaInset(edge: .bottom) { SidebarFooter(app: app, setUpHelper: setUpHelper) }
    }
}

private struct SidebarFooter: View {
    let app: AppModel
    var setUpHelper: () -> Void
    /// The verified health state, not the raw Login Items registration: a job can be
    /// marked enabled in BTM while the Helper behind it is gone or answers an old protocol.
    @Bindable private var health = HelperHealthMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            UpdateAvailableButton()
                .padding(.horizontal, 12)
            HStack(spacing: 8) {
                helperStatus
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder private var helperStatus: some View {
        let row = HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            Text(health.summaryLabel).font(.mhCaption).foregroundStyle(Palette.text)
        }
        if health.isHealthy {
            row.help("Helper running")
        } else {
            Button(action: setUpHelper) { row }
                .buttonStyle(.plain)
                .help("Open Helper setup and repair options")
        }
    }

    private var dotColor: Color {
        switch health.footerTone {
        case .healthy: Theme.mint
        case .warning: Theme.amber
        case .alert: Theme.rose
        case .neutral: Palette.textMuted
        }
    }
}
