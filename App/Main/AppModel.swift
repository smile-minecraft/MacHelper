import AppKit
import Observation
import SettingsPortability
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case overview, monitor, health, fans, optimize, disk, uninstall, updates, startup
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
        }
    }

    var icon: String { "px.\(rawValue)" }

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
        }
    }

    static var groups: [(LocalizedStringKey, [AppSection])] {
        ThemeStore.shared.isSimple
            ? [(LocalizedStringKey("This Mac"), simpleSections.filter { $0.isThisMac }),
               (LocalizedStringKey("Clean Up"), simpleSections.filter { !$0.isThisMac })]
            : [("This Mac", [.overview, .monitor, .health, .fans]), ("Clean Up", [.optimize, .disk, .uninstall, .updates, .startup])]
    }

    /// Simple mode keeps the everyday tools; monitoring charts, fan curves and launch agents are advanced.
    static let simpleSections: [AppSection] = [.overview, .health, .optimize, .disk, .uninstall, .updates]

    var isThisMac: Bool { [.overview, .monitor, .health, .fans].contains(self) }

    /// Whether the page is shown in the current mode.
    var isVisible: Bool { !ThemeStore.shared.isSimple || Self.simpleSections.contains(self) }
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
    let autoCleanModel = AutoCleanModel()
    let uninstallModel = UninstallModel()
    let startupModel = StartupModel()
    let healthModel = HealthModel()

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
        backgroundRecording = BackgroundRecordingModel(settings: settings, availableModules: store.availableModules)
    }

    func show(_ section: AppSection) {
        self.section = section
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
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        DispatchQueue.main.async { AppModel.applyDockPreference() }
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
