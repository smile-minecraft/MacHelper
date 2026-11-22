import AppKit
import SwiftUI
import Theming

struct MonitorSettingsView: View {
    @Bindable var settings: MonitorSettingsStore
    let available: Set<MonitorModule>
    var alerts: AlertCenter?

    @Bindable private var look = ThemeStore.shared
    @AppStorage(HealthScoreMenuBar.key) private var showHealthScore = false

    var body: some View {
        Form {
            Section {
                Picker("Font", selection: $look.settings.menuBarFont) {
                    Text("System Rounded").tag(AppearanceSettings.MenuBarFont.rounded)
                    Text("System").tag(AppearanceSettings.MenuBarFont.system)
                    Text("Pixel").tag(AppearanceSettings.MenuBarFont.pixel)
                }
                .pickerStyle(.segmented)
                Picker("Label each value with", selection: $look.settings.menuBarLabel) {
                    Text("Short name (CPU, MEM)").tag(AppearanceSettings.MenuBarLabel.text)
                    Text("Icon").tag(AppearanceSettings.MenuBarLabel.icon)
                    Text("Nothing").tag(AppearanceSettings.MenuBarLabel.none)
                }
                Picker("Value color", selection: $look.settings.menuBarColored) {
                    Text("White (menu bar text color)").tag(false)
                    Text("Soft hint when high").tag(true)
                }
                let valueColorCaption = look.settings.menuBarColored
                     ? "Values that need attention get a pale yellow or red, close to white, so they stay easy to read."
                     : "Every value uses the menu bar’s own text color."
                Text(valueColorCaption).settingsCaption()
                    .id(valueColorCaption)
                    .transition(Motion.stateSwap)
                    .animatesStateChanges(valueColorCaption)
                Toggle("Two lines (name above value, saves width)", isOn: $settings.configuration.compact)
                    .disabled(look.settings.menuBarLabel != .text)
            } header: { Text("How Values Look") }

            Section {
                Toggle("Show the health score", isOn: $showHealthScore)
                Text("The same score as on Overview, shown first in the menu bar as HP. It goes down for each problem found now or in the last 24 hours; Health Check lists what lowers it.")
                    .settingsCaption()
            } header: { Text("Health Score") }

            if let alerts { AlertSettingsSection(alerts: alerts) }
            Section {
                HStack(spacing: 12) {
                    Text("Item").frame(width: ModuleRow.itemWidth, alignment: .leading)
                    Text("In menu bar")
                    Spacer()
                    Text("Graph").frame(minWidth: 80, alignment: .leading)
                    Text("Updates every").frame(minWidth: 80, alignment: .leading)
                }
                .font(.mhCaption.weight(.semibold)).foregroundStyle(Palette.textMuted)
                ForEach(MonitorModule.allCases) { m in
                    if available.contains(m) {
                        ModuleRow(module: m, config: binding(m))
                    } else {
                        LabeledContent(m.title, value: String(localized: "Not supported on this Mac"))
                            .foregroundStyle(Palette.textMuted)
                    }
                }
            } header: { Text("Items") } footer: {
                Text("Turning an item off stops measuring it everywhere. “In menu bar” only decides whether it shows up there; it stays in the panel and the main window.")
                    .settingsCaption()
                Text("Accessories appear only while connected.")
                    .settingsCaption()
            }

            Section {
                ForEach(Array(settings.configuration.panelPageOrder.enumerated()), id: \.element) { index, page in
                    HStack(spacing: 12) {
                        Toggle(page.title, isOn: pageVisibleBinding(page))
                            .frame(minWidth: 90, alignment: .leading)
                            .disabled(isLastVisiblePage(page))
                        Spacer()
                        Button { movePage(page, by: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain)
                        .help("Move up")
                        .disabled(index == 0)
                        Button { movePage(page, by: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .help("Move down")
                        .disabled(index == settings.configuration.panelPageOrder.count - 1)
                    }
                }
            } header: { Text("Panel") } footer: {
                Text("Choose which pages appear when you open the menu bar panel. Pages whose hardware is missing stay hidden automatically. At least one page stays visible.")
                    .settingsCaption()
            }
        }
        .formStyle(.grouped)
        .settingsSurface()
    }

    private func binding(_ m: MonitorModule) -> Binding<ModuleConfig> {
        Binding(get: { settings[m] }, set: { settings[m] = $0 })
    }

    /// A page is shown by default; the toggle writes into `hiddenPanelPages`. The last visible
    /// page stays on — switching it off is refused here and disabled on the toggle.
    private func pageVisibleBinding(_ page: PanelPage) -> Binding<Bool> {
        Binding(
            get: { !settings.configuration.hiddenPanelPages.contains(page) },
            set: { shown in
                var configuration = settings.configuration
                if shown {
                    configuration.hiddenPanelPages.remove(page)
                } else {
                    guard configuration.panelPageOrder.count - configuration.hiddenPanelPages.count > 1 else { return }
                    configuration.hiddenPanelPages.insert(page)
                }
                settings.configuration = configuration
            }
        )
    }

    private func isLastVisiblePage(_ page: PanelPage) -> Bool {
        !settings.configuration.hiddenPanelPages.contains(page)
            && settings.configuration.panelPageOrder.count - settings.configuration.hiddenPanelPages.count == 1
    }

    private func movePage(_ page: PanelPage, by offset: Int) {
        var configuration = settings.configuration
        guard let index = configuration.panelPageOrder.firstIndex(of: page) else { return }
        let target = index + offset
        guard configuration.panelPageOrder.indices.contains(target) else { return }
        configuration.panelPageOrder.swapAt(index, target)
        settings.configuration = configuration
    }
}

private struct ModuleRow: View {
    let module: MonitorModule
    @Binding var config: ModuleConfig
    /// The item's name and its on/off switch, so the "In menu bar" header sits over the checkbox.
    static let itemWidth: CGFloat = 170

    var body: some View {
        HStack(spacing: 12) {
            HStack {
                Text(module.title)
                Spacer(minLength: 8)
                Toggle(module.title, isOn: $config.enabled).labelsHidden()
            }
            .frame(width: Self.itemWidth)
            Toggle("Show", isOn: $config.inMenuBar)
                .toggleStyle(.checkbox)
                .disabled(!config.enabled)
            Spacer()
            Picker("Style", selection: $config.style) {
                ForEach(module.supportedStyles) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(minWidth: 80)
            .disabled(!config.enabled || !config.inMenuBar)
            Picker("Interval", selection: $config.interval) {
                ForEach([1.0, 2, 5, 10, 30], id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            .labelsHidden()
            .frame(minWidth: 80)
            .disabled(!config.enabled)
        }
    }
}

/// Overrides the app's language (the AppleLanguages default in MacHelper's own domain); takes effect
/// after a relaunch. "System" removes the override.
struct LanguagePicker: View {
    @State private var selection: String = Self.current ?? "system"
    @State private var changed = false

    private static var current: String? {
        UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"]
            .flatMap { ($0 as? [String])?.first }
            .map { AppLanguage.match($0) ?? "en" }
    }

    var body: some View {
        HStack {
            Picker("Language", selection: $selection) {
                Text("System Default").tag("system")
                ForEach(AppLanguage.all, id: \.code) { code, name in
                    Text(verbatim: name).tag(code)
                }
            }
            .onChange(of: selection) { _, new in
                if new == "system" {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.set([new], forKey: "AppleLanguages")
                }
                changed = true
            }
            if changed {
                Button("Relaunch") { relaunch() }
            }
        }
        if changed {
            Text("The new language is used after MacHelper relaunches.")
                .settingsCaption()
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Links ~/.local/bin/machelper to the CLI inside the app bundle (no administrator needed).
struct CommandLineToolRow: View {
    static let linkPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/machelper"
    static var target: String { Bundle.main.bundlePath + "/Contents/MacOS/machelper-cli" }
    @State private var installed = Self.isInstalled
    @State private var error: String?

    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == target
    }

    var body: some View {
        LabeledContent("Command-line tool") {
            HStack {
                Text(installed ? "~/.local/bin/machelper" : String(localized: "Not installed"))
                    .font(.mhCaption.monospaced()).foregroundStyle(Palette.textMuted)
                Button(installed ? "Remove" : "Install") { toggle() }
            }
        }
        if let error {
            Text(error).settingsCaption(Theme.rose)
        }
        if installed {
            Text("Run “machelper --help” in Terminal. ~/.local/bin must be in your PATH.")
                .settingsCaption()
        }
    }

    private func toggle() {
        error = nil
        do {
            if installed { try FileManager.default.removeItem(atPath: Self.linkPath) } else { try Self.install() }
        } catch let e {
            error = e.localizedDescription
        }
        installed = Self.isInstalled
    }

    /// Links ~/.local/bin/machelper to the app's CLI; refuses to replace a file that isn't a link.
    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (linkPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil { try fm.removeItem(atPath: linkPath) }
        guard !fm.fileExists(atPath: linkPath) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "~/.local/bin/machelper already exists and isn’t a link; remove it first.")])
        }
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
    }
}
