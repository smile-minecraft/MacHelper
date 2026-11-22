import ServiceManagement
import SettingsPortability
import SwiftUI
import Telemetry

struct SettingsView: View {
    let app: AppModel

    enum Tab: String { case general, appearance, menuBar, alerts, helper, history }

    /// Opens on General. A debug launch argument (`-settings.tab helper`) can pick another tab for
    /// screenshots; it lives in the volatile argument domain and is never written back.
    @State private var tab = Tab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(app: app)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
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
