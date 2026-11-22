import HelperProtocol
import ServiceManagement
import SwiftUI

struct MainView: View {
    @Bindable var app: AppModel
    @Environment(\.openWindow) private var openWindow
    /// First-launch sheets, one at a time: Full Disk Access, then the Helper, then the agent skill.
    @State private var onboarding = OnboardingStep.next(after: nil)
    @State private var lastOnboarding: OnboardingStep?
    /// False once the Helper guide is opened by hand from the sidebar: closing it shows nothing else.
    @State private var chainOnboarding = true

    var body: some View {
        NavigationSplitView {
            Sidebar(app: app, setUpHelper: { chainOnboarding = false; onboarding = .helper })
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            // The previous page leaves at once and the new one fades in, rising a few points, so a
            // switch reads as one movement and two heavy pages are never blended mid-fade.
            // With Reduce Motion it is a plain fade.
            ZStack {
                detail
                    .id(app.section)
                    .onAppear { PageLoadProbe.mark(app.section, "render") }
                    .transition(Motion.pageIn)
            }
            .animation(Motion.reduced ? .easeOut(duration: 0.15) : .smooth(duration: 0.32), value: app.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.base)
            .navigationTitle(Text(app.section.title))
            .modifier(SteadyTitleBar())
        }
        .frame(minWidth: 980, minHeight: 640)
        // Single-variant themes and the Light / Dark setting force their scheme on the window.
        .themeColorScheme()
        .onAppear { app.openMainWindow = { openWindow(id: "main") } }
        .onChange(of: app.section) { _, section in
            // The timing probe is inert unless `--measure-pages` is running.
            guard PageLoadProbe.active else { return }
            DispatchQueue.main.async { PageLoadProbe.mark(section, "render") }
        }
        .sheet(item: $onboarding, onDismiss: { onboarding = chainOnboarding ? OnboardingStep.next(after: lastOnboarding) : nil }) { step in
            Group {
                switch step {
                case .fullDiskAccess: FullDiskAccessSheet()
                case .helper: HelperSetupSheet()
                case .agentSkill: AgentSkillSheet()
                }
            }
            .onAppear { lastOnboarding = step }
        }
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

/// The sheets offered on first launch, in order.
private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case fullDiskAccess, helper, agentSkill
    var id: Int { rawValue }

    var shouldOffer: Bool {
        switch self {
        case .fullDiskAccess: FullDiskAccess.shouldOfferOnboarding
        case .helper: HelperSetup.shouldOfferOnboarding
        case .agentSkill: AgentSkillSetup.shouldOffer
        }
    }

    /// The first step after `previous` that still applies.
    static func next(after previous: OnboardingStep?) -> OnboardingStep? {
        allCases.first { $0.rawValue > (previous?.rawValue ?? -1) && $0.shouldOffer }
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
    @State private var status = HelperClient.shared.status

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            UpdateAvailableButton()
                .padding(.horizontal, 12)
            HStack(spacing: 8) {
                if status == .enabled {
                    Circle().fill(Theme.mint).frame(width: 8, height: 8)
                    Text("Helper running").font(.mhCaption).foregroundStyle(Palette.textMuted)
                } else {
                    // Not running: the line opens the setup guide.
                    Button(action: setUpHelper) {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.amber).frame(width: 8, height: 8)
                            Text("Set up Helper…").font(.mhCaption).foregroundStyle(Palette.text)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Helper not enabled")
                }
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
                // The status only changes when the user turns the Helper on or off; check sooner
                // while it is off so the footer follows the setup guide.
                let now = HelperClient.shared.status
                if now != status { status = now }
                try? await Task.sleep(for: .seconds(status == .enabled ? 30 : 3))
            }
        }
    }
}
