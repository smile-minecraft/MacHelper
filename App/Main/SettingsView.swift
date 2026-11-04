import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let app: AppModel

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            MonitorSettingsView(settings: app.settings, available: app.store.availableModules)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            Form { AlertSettingsSection(alerts: app.store.alerts) }
                .formStyle(.grouped)
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
            HelperDiagnosticsView()
                .tabItem { Label("Helper", systemImage: "lock.shield") }
        }
        .frame(width: 620, height: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage("showInDock") private var showInDock = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.none).frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacHelper").font(.title3.weight(.semibold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
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
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                Text("Without the Dock icon, MacHelper lives in the menu bar; its window opens from there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LanguagePicker()
                CommandLineToolRow()
            }
        }
        .formStyle(.grouped)
    }
}
