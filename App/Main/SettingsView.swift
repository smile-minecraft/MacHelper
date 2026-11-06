import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let app: AppModel

    var body: some View {
        TabView {
            GeneralSettings(app: app)
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            MonitorSettingsView(settings: app.settings, available: app.store.availableModules)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            Form { AlertSettingsSection(alerts: app.store.alerts) }
                .formStyle(.grouped)
                .settingsSurface()
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
            HelperDiagnosticsView()
                .tabItem { Label("Helper", systemImage: "lock.shield") }
            OperationHistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .frame(minWidth: 760, minHeight: 580)
    }
}

private struct GeneralSettings: View {
    let app: AppModel
    @AppStorage("showInDock") private var showInDock = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

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
                }
            }
            BackgroundRecordingSection(model: app.backgroundRecording)
            HistoryManagementSection()
            Section("General") {
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { AppModel.applyDockPreference() }
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
                if let loginError {
                    Text(loginError).settingsCaption(Theme.rose)
                }
                Text("Without the Dock icon, MacHelper lives in the menu bar; its window opens from there.")
                    .settingsCaption()
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
