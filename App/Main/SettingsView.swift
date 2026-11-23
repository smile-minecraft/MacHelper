import FanControl
import ServiceManagement
import SettingsPortability
import SwiftUI
import Telemetry

struct SettingsView: View {
    let app: AppModel

    enum Tab: String { case general, features, appearance, menuBar, alerts, helper, history }

    /// Opens on General. A debug launch argument (`-settings.tab helper`) can pick another tab for
    /// screenshots; it lives in the volatile argument domain and is never written back.
    @State private var tab = Tab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(app: app)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            FeatureSettings(app: app)
                .tabItem { Label("Features", systemImage: "square.grid.2x2") }
                .tag(Tab.features)
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(Tab.appearance)
            MonitorSettingsView(settings: app.settings, available: app.store.availableModules)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
                .tag(Tab.menuBar)
            Form { AlertSettingsSection(alerts: app.store.alerts) }
                .formStyle(.grouped)
                .settingsSurface()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
                .tag(Tab.alerts)
            HelperDiagnosticsView()
                .tabItem { Label("Helper", systemImage: "lock.shield") }
                .tag(Tab.helper)
            OperationHistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
        }
        .frame(minWidth: 760, minHeight: 580)
    }
}

/// Each tool page has one switch here. Turning one off removes its page and every shortcut that
/// leads to it while keeping the user's settings for that tool intact.
private struct FeatureSettings: View {
    let app: AppModel
    @State private var pending: FeatureModule?

    var body: some View {
        Form {
            Section("Feature Modules") {
                Text("Turn a tool off to remove its page and shortcuts. Its saved settings are kept.")
                    .settingsCaption()
                ForEach(FeatureModule.allCases, id: \.self) { module in
                    row(module)
                }
            }
        }
        .formStyle(.grouped)
        .settingsSurface()
        .task { await app.fanModel.refresh() }
        .confirmationDialog(Text(verbatim: confirmationText),
                            isPresented: Binding(get: { pending != nil },
                                                 set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) {
                if let pending { apply(pending, false) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ module: FeatureModule) -> some View {
        let section = AppSection(rawValue: module.rawValue) ?? .overview
        return Toggle(isOn: Binding(
            get: { FeatureStore.shared.isEnabled(module) },
            set: { request(module, $0) }
        )) {
            HStack(spacing: 12) {
                PixelIcon(name: section.icon, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(.mh(size: 13.5, weight: .semibold))
                    Text(description(for: module)).settingsCaption()
                    if let note = sideEffectNote(for: module) {
                        Text(note).settingsCaption(Theme.amber)
                    }
                    if module.hiddenInSimpleMode {
                        Text("Not shown in Simple mode").settingsCaption()
                    }
                }
            }
        }
    }

    private func description(for module: FeatureModule) -> LocalizedStringKey {
        switch module {
        case .monitor: "Live monitoring, charts and the background recording agent."
        case .health: "A one-off check of the recorded history and system health."
        case .fans: "Fan curves and automatic switching rules."
        case .optimize: "Find and remove build artifacts and other low-risk clutter."
        case .disk: "See which volumes and folders use the most space."
        case .uninstall: "Remove apps together with their leftovers."
        case .updates: "Check Homebrew casks and upgrade the ones you pick."
        case .startup: "Review login items and background agents."
        }
    }

    private func sideEffectNote(for module: FeatureModule) -> LocalizedStringKey? {
        switch module {
        case .monitor: "Background recording is paused while this is off."
        case .fans: "Fans return to automatic system control while this is off."
        case .optimize: "Turning this off also pauses scheduled cleanup."
        case .updates: "Homebrew update checks stop while this is off."
        case .health, .disk, .uninstall, .startup: nil
        }
    }

    private func request(_ module: FeatureModule, _ enabled: Bool) {
        guard !enabled else { apply(module, true); return }
        let needsConfirmation: Bool
        switch module {
        case .fans:
            let helperIsNotAutomatic: Bool
            if let mode = app.fanModel.status?.policy.mode {
                if case .automatic = mode { helperIsNotAutomatic = false }
                else { helperIsNotAutomatic = true }
            } else {
                helperIsNotAutomatic = false
            }
            needsConfirmation = app.fanSwitcher.enabled || helperIsNotAutomatic
        case .optimize: needsConfirmation = app.autoCleanModel.enabled
        default: needsConfirmation = false
        }
        if needsConfirmation {
            pending = module
        } else {
            apply(module, false)
        }
    }

    private var confirmationText: String {
        switch pending {
        case .fans: String(localized: "Turn off Fans? Fans return to automatic system control while this is off.")
        case .optimize: String(localized: "Turn off Optimize? Turning this off also pauses scheduled cleanup.")
        default: ""
        }
    }

    private func apply(_ module: FeatureModule, _ enabled: Bool) {
        withAnimation(Motion.stateChange) { FeatureStore.shared.setEnabled(module, enabled) }
    }
}

private struct GeneralSettings: View {
    let app: AppModel
    @AppStorage(DockPreference.modeKey) private var dockMode = DockMode.whileWindowOpen
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var autoCheckUpdates = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacHelper").font(.mhTitle3.weight(.semibold)).foregroundStyle(Palette.text)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                            .settingsCaption()
                    }
                    Spacer()
                    if UpdaterController.shared.availableVersion != nil {
                        UpdateAvailableButton()
                    } else {
                        Button("Check for Updates") { UpdaterController.shared.checkForUpdates() }
                    }
                }
                Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
                    .onChange(of: autoCheckUpdates) { _, on in
                        // Writing back persists the preference through Sparkle.
                        if on != UpdaterController.shared.automaticallyChecksForUpdates {
                            UpdaterController.shared.automaticallyChecksForUpdates = on
                        }
                    }
                    .onAppear { autoCheckUpdates = UpdaterController.shared.automaticallyChecksForUpdates }
            }
            TelemetrySettingsView(client: app.telemetry)
            BackgroundRecordingSection(model: app.backgroundRecording)
            HistoryManagementSection()
            Section("General") {
                Picker("Dock icon", selection: Binding(
                    get: { dockMode },
                    set: { newValue in
                        withAnimation(Motion.stateChange) { dockMode = newValue }
                    }
                )) {
                    Text("Always").tag(DockMode.always)
                    Text("While a window is open").tag(DockMode.whileWindowOpen)
                    Text("Never").tag(DockMode.never)
                }
                .onChange(of: dockMode) { AppModel.applyDockPreference() }
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Group {
                    if let loginError {
                        Text(loginError).settingsCaption(Theme.rose)
                    }
                }
                .transition(Motion.stateSwap)
                .animatesStateChanges(loginError)
                Group {
                    if dockMode == .never {
                        Text("Without the Dock icon, MacHelper lives in the menu bar; its window opens from there.")
                            .settingsCaption()
                    }
                }
                .transition(Motion.stateSwap)
                .animatesStateChanges(dockMode)
            }
            Section {
                LanguagePicker()
                CommandLineToolRow()
                AgentSkillRow()
            }
            SettingsBackupSection(app: app)
        }
        .formStyle(.grouped)
        .settingsSurface()
    }
}
