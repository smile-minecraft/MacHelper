import AppKit
import Observation
import SettingsPortability
import SwiftUI
import Telemetry
import Tweaks

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case overview, monitor, health, fans, optimize, disk, uninstall, updates, startup, tweaks, cable
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .monitor: "Monitor"
        case .health: "Health Check"
        case .fans: "Fans"
        case .optimize: "Optimize"
        case .disk: "Disk Analysis"
        case .uninstall: "Uninstall"
        case .updates: "Homebrew Updates"
        case .startup: "Startup Items"
        case .tweaks: "Tweaks"
        case .cable: "Cable"
        }
    }

    var icon: String {
        switch self {
        case .tweaks: "px.settings"
        case .cable: "px.power"
        default: "px.\(rawValue)"
        }
    }

    var accent: Color {
        switch self {
        case .overview: Theme.blue
        case .monitor: Theme.cyan
        case .health: Theme.rose
        case .fans: Theme.mint
        case .optimize: Theme.amber
        case .disk: Theme.violet
        case .uninstall: Theme.rose
        case .updates: Theme.mint
        case .startup: Theme.orange
        case .tweaks: Theme.slate
        case .cable: Theme.amber
        }
    }

    @MainActor static var groups: [(LocalizedStringKey, [AppSection])] {
        let visible = allCases.filter(\.isVisible)
        return [(LocalizedStringKey("This Mac"), visible.filter(\.isThisMac)),
                (LocalizedStringKey("Clean Up"), visible.filter { !$0.isThisMac && $0 != .tweaks }),
                (LocalizedStringKey("Tweaks"), visible.filter { $0 == .tweaks })]
            .filter { !$0.1.isEmpty }
    }

    var isThisMac: Bool { [.overview, .monitor, .health, .fans, .cable].contains(self) }

    /// Overview is the permanent home page; every other page belongs to one module.
    var module: FeatureModule? { FeatureModule(rawValue: rawValue) }

    /// Whether the page is currently allowed by both its module switch and the display mode.
    @MainActor var isVisible: Bool {
        guard let module else { return true }
        return module.isVisible(enabled: FeatureStore.shared.isEnabled(module),
                                simpleMode: ThemeStore.shared.isSimple)
    }
}

/// Owns every feature model; shared by the main window, the menu bar panel and Settings.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = MonitorSettingsStore()
    let store: MonitorStore
    let backgroundRecording: BackgroundRecordingModel
    let fanModel = FanControlModel()
    let fanSwitcher = FanAutoSwitcher()
    let diskModel = DiskAnalysisModel()
    let optimizeModel = OptimizeModel()
    let updatesModel = UpdatesModel()
    let autoCleanModel: AutoCleanModel
    let uninstallModel = UninstallModel()
    let startupModel = StartupModel()
    let healthModel = HealthModel()
    let tweaks = TweakSettingsModel()
    let cableModel = CableModel()

    /// Opt-in telemetry. Creating the client never reads anything or sends anything; only an
    /// explicit opt-in queues events, and only a configured endpoint can transmit them.
    let telemetry: AppTelemetryClient = {
        let preferences = TelemetryPreferences()
        return AppTelemetryClient(
            preferences: preferences,
            transport: DefaultTelemetryTransport(
                base: URLSessionTelemetryTransport(endpointResolver: { preferences.configuredEndpoint })))
    }()

    var section: AppSection = .overview {
        didSet {
            // Restored scan trees are large; keep only the location on screen once the page closes.
            if oldValue == .disk, section != .disk { diskModel.trimCachedTrees() }
        }
    }

    /// Whether the main window is on screen. AppDelegate maintains this from NSWindow
    /// notifications; OverviewView uses it to stop UI-only work while the window is closed
    /// or miniaturized. Menu bar, background recording and health score read the store
    /// directly and are unaffected.
    var hasVisibleMainWindow = false

    /// Any main window on screen. Miniaturized windows are not visible, so the overview
    /// pauses while the window sits in the Dock.
    static func mainWindowIsVisible() -> Bool {
        NSApp.windows.contains {
            $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible && !$0.isMiniaturized
        }
    }

    /// Set by the main window's view; opens (or brings back) the main window.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    private init() {
        store = MonitorStore(settings: settings)
        if DemoData.snapshot {
            // The synthetic screenshot run uses throwaway files, never the real recorder profile
            // or auto-clean schedule, and skips the launch-time schedule migration.
            let scratch = FileManager.default.temporaryDirectory.appending(path: "MacHelperDemo-\(ProcessInfo.processInfo.processIdentifier)")
            backgroundRecording = BackgroundRecordingModel(settings: settings, availableModules: store.availableModules,
                                                           profileURL: scratch.appending(path: "profile.json"),
                                                           heartbeatURL: scratch.appending(path: "heartbeat.json"))
            autoCleanModel = AutoCleanModel(agent: SMAppServiceAgentServicing(), configURL: scratch.appending(path: "autoclean.json"),
                                            defaults: .standard)
        } else {
            backgroundRecording = BackgroundRecordingModel(settings: settings, availableModules: store.availableModules)
            autoCleanModel = AutoCleanModel()
        }
    }

    func show(_ section: AppSection) {
        // A hidden page has no entry point. Stale shortcuts, the Dock reopen and onboarding land on
        // the overview instead, so the window still opens.
        let section = section.isVisible ? section : .overview
        self.section = section
        if !TelemetryRuntime.isNonProduction() {
            Task { await telemetry.recordSectionView(section.rawValue) }
        }
        if DockPreference.migrate(.standard) != .never {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        // The window may appear after this call; re-evaluate once it has been ordered in.
        DispatchQueue.main.async { AppModel.applyDockPreference() }
    }

    func showSettings() {
        if DockPreference.migrate(.standard) != .never {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        // A SwiftUI `Settings` scene is presented by the app menu's Settings item, not by
        // `showSettingsWindow:`. When no main window is open the app stays in accessory mode,
        // `activate()` cannot bring it forward, and the old selector silently does nothing —
        // that is why the panel gear had no effect. Invoke the very same menu item that
        // "MacHelper > Settings…" uses, which works with no window and in accessory mode.
        if !Self.invokeSettingsMenuItem() {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        DispatchQueue.main.async { AppModel.applyDockPreference() }
    }

    /// Invokes the SwiftUI-provided Settings menu item and reports whether it was found.
    /// The item is identified by its Command-, key equivalent, which is stable across
    /// localizations. Its action and target are SwiftUI internals, so they are read at runtime.
    private static func invokeSettingsMenuItem() -> Bool {
        func settingsItem(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action != nil,
                   item.keyEquivalent == ",",
                   item.keyEquivalentModifierMask.contains(.command) {
                    return item
                }
                if let submenu = item.submenu, let found = settingsItem(in: submenu) {
                    return found
                }
            }
            return nil
        }
        guard let mainMenu = NSApp.mainMenu,
              let item = settingsItem(in: mainMenu),
              let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: nil)
    }

    /// Keeps the app regular while the SwiftUI `Window` scene is being created. Applying the full
    /// policy before the window exists would launch as accessory, and the main window would never
    /// appear for `whileWindowOpen` or `always`. A `never` app starts in the menu bar only.
    static func prepareDockPreference() {
        // `never` must start in the menu bar, while the other modes need the regular policy
        // long enough for the SwiftUI Window scene to order the main window in.
        NSApp.setActivationPolicy(DockPreference.migrate(.standard) == .never ? .accessory : .regular)
    }

    /// Applies the Dock mode to the current set of windows. A mode of `whileWindowOpen` keeps the
    /// regular policy while any ordinary window is visible or minimized; the menu bar panel is an
    /// `NSPanel`, so it never counts as a window here.
    static func applyDockPreference() {
        let mode = DockPreference.migrate(.standard)
        let hasOpenWindows = NSApp.windows.contains {
            $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)
        }
        NSApp.setActivationPolicy(mode.showsDockIcon(hasOpenWindows: hasOpenWindows) ? .regular : .accessory)
    }
}

/// Timing hooks for `--measure-pages`. The mode switches through the main window's pages and
/// records when each page's first usable content is on screen; every mark is ignored unless
/// the measurement mode started it.
@MainActor
enum PageLoadProbe {
    private(set) static var active = false
    private static var marks: [AppSection: [String: CFAbsoluteTime]] = [:]

    static func start() { active = true }

    static func reset(_ section: AppSection) { marks[section] = [:] }

    static func mark(_ section: AppSection, _ event: String) {
        guard active else { return }
        if marks[section]?[event] == nil {
            marks[section, default: [:]][event] = CFAbsoluteTimeGetCurrent()
        }
    }

    static func time(_ section: AppSection, _ event: String) -> CFAbsoluteTime? {
        marks[section]?[event]
    }

    static func events(_ section: AppSection) -> [String: CFAbsoluteTime] {
        marks[section] ?? [:]
    }
}
