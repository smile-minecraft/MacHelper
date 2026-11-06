import AppKit
import Observation
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
        case .updates: "App Updates"
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

    var section: AppSection = .overview

    /// Set by the main window's view; opens (or brings back) the main window.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    private init() {
        store = MonitorStore(settings: settings)
        backgroundRecording = BackgroundRecordingModel(settings: settings, availableModules: store.availableModules)
    }

    func show(_ section: AppSection) {
        self.section = section
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    func showSettings() {
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Dock icon on (regular app) or off (menu bar only).
    static func applyDockPreference() {
        let show = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }
}
