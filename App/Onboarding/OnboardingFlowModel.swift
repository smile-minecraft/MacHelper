import AppKit
import CleanEngine
import Observation
import Permissions
import ServiceManagement
import SwiftUI
import Theming

/// Onboarding copy lives in its own String Catalog (`App/Onboarding/Onboarding.xcstrings`), so the
/// guide can change without touching the shared `Localizable.xcstrings`. Keys are plain strings
/// (not `LocalizationValue`), so the compiler doesn't also extract them into the shared table;
/// every key in that catalog therefore carries every shipped language (`scripts/l10n/check.py`).
func onboardingText(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: "Onboarding")
}

/// A key with `%lld` / `%@` placeholders, filled in after the lookup.
func onboardingText(format key: String, _ arguments: any CVarArg...) -> String {
    String(format: onboardingText(key), locale: .current, arguments: arguments)
}

/// The pages of the welcome guide, in order.
enum OnboardingStep: Int, CaseIterable, Identifiable, Comparable {
    case welcome, personalize, tour, permissions, agentCli, ready
    var id: Int { rawValue }

    static func < (a: OnboardingStep, b: OnboardingStep) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .welcome: onboardingText("Welcome")
        case .personalize: onboardingText("Your Experience")
        case .tour: onboardingText("Menu Bar")
        case .permissions: onboardingText("Permissions")
        case .agentCli: onboardingText("AI Agents")
        case .ready: onboardingText("All Set")
        }
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// When the guide opens by itself, and what counts as having seen it.
enum OnboardingLifecycle {
    static let completedKey = "onboarding.v2.completed"
    /// Keys of the three first-launch sheets the guide replaces. Seeing any of them means the user
    /// went through the old first launch, so an upgrade doesn't greet them again (Help → Welcome
    /// Guide still opens it).
    static let legacyKeys = [FullDiskAccess.onboardingKey, HelperSetup.onboardingKey, AgentSkillSetup.askedKey,
                             "onboarding.fda.shown"]

    /// Debug, measurement and export runs never show the guide: it would cover what they capture.
    static var isAutomatedRun: Bool {
        CommandLine.arguments.contains {
            $0.hasPrefix("--snapshot") || $0.hasPrefix("--export-") || $0 == "--measure-pages" || $0 == "--selftest"
        }
    }

    static func shouldAutoShow(defaults: UserDefaults = .standard) -> Bool {
        guard !isAutomatedRun, !defaults.bool(forKey: completedKey) else { return false }
        return !legacyKeys.contains { defaults.bool(forKey: $0) }
    }

    /// Finished, skipped or closed: never offered automatically again, and the legacy sheets'
    /// flags are set too so nothing else asks the same questions.
    static func markCompleted(defaults: UserDefaults = .standard) {
        guard !isAutomatedRun else { return }
        defaults.set(true, forKey: completedKey)
        for key in [FullDiskAccess.onboardingKey, HelperSetup.onboardingKey, AgentSkillSetup.askedKey] {
            defaults.set(true, forKey: key)
        }
    }
}

/// Presents the guide over the main window: by itself on first launch, or from Help → Welcome Guide.
@MainActor
@Observable
final class OnboardingCenter {
    static let shared = OnboardingCenter()

    var isPresented = false
    @ObservationIgnored private var checkedFirstLaunch = false

    private init() {}

    /// Called when the main window appears; opens the guide once per launch when it applies.
    func presentIfNeeded() {
        guard !checkedFirstLaunch else { return }
        checkedFirstLaunch = true
        if OnboardingSnapshot.runIfRequested() { return }
        if OnboardingLifecycle.shouldAutoShow() { isPresented = true }
    }

    /// Opens the guide on request, bringing the main window forward first.
    func present() {
        checkedFirstLaunch = true
        let app = AppModel.shared
        app.show(app.section)
        isPresented = true
    }

    func dismissed() {
        isPresented = false
        OnboardingLifecycle.markCompleted()
    }
}

/// State of one run through the guide. Every permission and agent check is live and tolerant: a
/// missing agent, a denied permission or an error from the system leaves the step usable.
@MainActor
@Observable
final class OnboardingFlowModel {
    private(set) var step: OnboardingStep = .welcome
    /// Direction of the last move, for the page transition.
    private(set) var forward = true

    // Permissions come from PermissionCenter, the same model as Settings → Permissions.
    @ObservationIgnored private let permissions = PermissionCenter.shared

    // AI agents
    private(set) var agentTargets: [AgentSkill.Target] = AgentSkill.targets()
    private(set) var agentStates: [String: AgentSkill.State] = [:]
    var chosenAgents: Set<String> = []
    var linkCommandLine = !CommandLineToolRow.isInstalled
    private(set) var commandLineInstalled = CommandLineToolRow.isInstalled
    private(set) var agentError: String?
    private(set) var agentJustInstalled = false

    // General
    private(set) var openAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var loginError: String?

    init(start: OnboardingStep = .welcome) {
        step = start
        reloadAgents()
        chosenAgents = Set(agentTargets.filter { $0.detected && agentStates[$0.id] == .notInstalled }.map(\.id))
    }

    // MARK: Navigation

    var progress: Double { Double(step.rawValue + 1) / Double(OnboardingStep.allCases.count) }
    var isFirst: Bool { step.previous == nil }
    var isLast: Bool { step.next == nil }

    func goNext() {
        guard let next = step.next else { return }
        move(to: next)
    }

    func goBack() {
        guard let previous = step.previous else { return }
        move(to: previous)
    }

    func move(to target: OnboardingStep) {
        guard target != step else { return }
        forward = target > step
        withAnimation(Motion.standard ?? Motion.fade) { step = target }
    }

    // MARK: Experience

    var mode: AppearanceSettings.Mode {
        get { ThemeStore.shared.settings.mode }
        set { ThemeStore.shared.settings.mode = newValue }
    }

    /// The ready-made look in use, or nil when the user has a custom combination.
    var preset: AppearancePreset? { AppearancePreset.matching(ThemeStore.shared.settings) }

    func apply(_ preset: AppearancePreset) {
        var settings = ThemeStore.shared.settings
        preset.apply(to: &settings)
        ThemeStore.shared.settings = settings
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Menu bar

    /// Modules this Mac can show in the menu bar, in the order the panel uses.
    var menuBarModules: [MonitorModule] {
        let available = AppModel.shared.store.availableModules
        return [.cpu, .memory, .disk, .network, .gpu, .battery, .temperature, .power].filter(available.contains)
    }

    func isInMenuBar(_ module: MonitorModule) -> Bool {
        let config = AppModel.shared.settings[module]
        return config.enabled && config.inMenuBar
    }

    func setInMenuBar(_ module: MonitorModule, _ on: Bool) {
        var config = AppModel.shared.settings[module]
        config.inMenuBar = on
        if on { config.enabled = true }
        AppModel.shared.settings[module] = config
    }

    // MARK: Permissions

    var helperItem: PermissionCenter.Item? { permissions.item(.helper) }
    var fullDiskAccessItem: PermissionCenter.Item? { permissions.item(.fullDiskAccess) }
    /// Other grants, listed only when a feature that is on needs them.
    var otherRequiredItems: [PermissionCenter.Item] {
        permissions.items.filter { $0.isRequired && $0.id != .helper && $0.id != .fullDiskAccess }
    }

    var fullDiskAccess: Bool { fullDiskAccessItem?.state == .granted }
    /// The Helper answered over XPC: allowed in System Settings and started by launchd.
    var helperResponding: Bool { helperItem?.state == .granted }
    var helperInstalled: Bool {
        switch helperItem?.state {
        case .granted, .needsApproval, .denied: true
        default: false
        }
    }

    /// Follows the grants while the permissions step (or the summary) is on screen; the switches
    /// are flipped in System Settings, outside the app.
    func watchPermissions() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await PermissionCenter.shared.watch() }
            group.addTask { await PermissionFlow.shared.followHelperApproval() }
        }
    }

    // MARK: AI agents

    var detectedAgents: [AgentSkill.Target] { agentTargets.filter(\.detected) }

    func agentState(_ target: AgentSkill.Target) -> AgentSkill.State { agentStates[target.id] ?? .notInstalled }

    /// An agent the skill can be written for: present, and not holding someone else's SKILL.md.
    func canInstall(_ target: AgentSkill.Target) -> Bool {
        target.detected && agentState(target) != .foreign && agentState(target) != .installed
    }

    var installableChosen: [AgentSkill.Target] { agentTargets.filter { chosenAgents.contains($0.id) && canInstall($0) } }

    var skillInstalledAnywhere: Bool { agentTargets.contains { agentState($0) == .installed || agentState($0) == .outdated } }

    func toggleAgent(_ target: AgentSkill.Target, _ on: Bool) {
        if on { chosenAgents.insert(target.id) } else { chosenAgents.remove(target.id) }
    }

    func installSkills() {
        agentError = nil
        do {
            if linkCommandLine, !CommandLineToolRow.isInstalled { try CommandLineToolRow.install() }
            // AgentSkill.install refuses a SKILL.md it didn't write; canInstall filters those out first.
            try AgentSkillSetup.install(installableChosen)
            agentJustInstalled = true
        } catch {
            agentError = error.localizedDescription
        }
        reloadAgents()
    }

    func reloadAgents() {
        agentTargets = AgentSkill.targets()
        agentStates = Dictionary(uniqueKeysWithValues: agentTargets.map { ($0.id, AgentSkill.state($0)) })
        commandLineInstalled = CommandLineToolRow.isInstalled
    }

    // MARK: Finishing

    /// Where a quick action on the last step takes the user.
    enum Destination { case overview, health, disk }

    func open(_ destination: Destination) {
        let app = AppModel.shared
        switch destination {
        case .overview: app.section = .overview
        case .health: app.show(AppSection.health.isVisible ? .health : .overview)
        case .disk: app.show(AppSection.disk.isVisible ? .disk : .overview)
        }
    }
}
