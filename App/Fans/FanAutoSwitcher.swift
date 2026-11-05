import AppKit
import FanControl
import Foundation
import IOKit.ps
import Observation
import ServiceManagement

/// Applies a fan profile while a rule matches (an app is running, on battery, on the power adapter)
/// and returns to the policy chosen by hand when none does.
@MainActor
@Observable
final class FanAutoSwitcher {
    var enabled: Bool { didSet { save(); evaluate(force: true) } }
    var rules: [FanAutoRule] { didSet { save(); evaluate(force: true) } }
    private(set) var activeRule: FanAutoRule?
    private(set) var lastError: String?

    @ObservationIgnored nonisolated static let rulesKey = "fan.autoRules.v1"
    @ObservationIgnored nonisolated static let enabledKey = "fan.autoEnabled"
    @ObservationIgnored nonisolated static let baseKey = "fan.basePolicy.v1"
    @ObservationIgnored private var applied: FanPolicy?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        rules = UserDefaults.standard.data(forKey: Self.rulesKey).flatMap { try? JSONDecoder().decode([FanAutoRule].self, from: $0) } ?? []
    }

    /// The policy the user applied in the fan window; used when no rule matches.
    static var basePolicy: FanPolicy {
        get { UserDefaults.standard.data(forKey: baseKey).flatMap { try? JSONDecoder().decode(FanPolicy.self, from: $0) } ?? .automatic }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: baseKey) }
    }

    /// Re-reads the stored preferences after settings are imported.
    func reload() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        rules = UserDefaults.standard.data(forKey: Self.rulesKey)
            .flatMap { try? JSONDecoder().decode([FanAutoRule].self, from: $0) } ?? []
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        // Power source changes have no workspace notification; a cheap poll covers them.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        Task {
            // First run: the policy the helper already holds (set before switching existed) is the base.
            if UserDefaults.standard.data(forKey: Self.baseKey) == nil,
               let status = try? await HelperClient.shared.fanControlStatus() {
                Self.basePolicy = status.policy
            }
            evaluate(force: true)
        }
    }

    /// The user applied a policy by hand: it becomes the base, and stays unless a rule matches.
    func userApplied(_ policy: FanPolicy) {
        Self.basePolicy = policy
        applied = activeRule == nil ? policy : applied
    }

    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }

    func evaluate(force: Bool = false) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let match = enabled ? FanAutoRule.firstMatch(rules, runningBundleIDs: running, onBattery: Self.onBattery) : nil
        guard force || match?.id != activeRule?.id else { return }
        let previous = activeRule
        activeRule = match
        let policy = match?.target.policy ?? Self.basePolicy
        // Nothing to undo when switching was never active and the base is already in place.
        guard match != nil || previous != nil || (force && applied != nil && applied != policy) else { return }
        guard policy != applied, HelperClient.shared.status == .enabled else { return }
        applied = policy
        Task {
            do {
                try await HelperClient.shared.applyFanPolicy(policy)
                lastError = nil
            } catch {
                lastError = "\(error)"
            }
        }
    }

    private func save() {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: Self.rulesKey)
    }

    func addAppRule() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        rules.append(FanAutoRule(trigger: .appRunning(bundleID: id, name: name), target: .performance))
    }

    func addPowerRule(battery: Bool) {
        rules.append(FanAutoRule(trigger: battery ? .onBattery : .onPowerAdapter, target: battery ? .quiet : .balanced))
    }
}

extension FanAutoRule.Trigger {
    var title: String {
        switch self {
        case .appRunning(_, let name): String(localized: "While \(name) is running")
        case .onBattery: String(localized: "On battery")
        case .onPowerAdapter: String(localized: "On the power adapter")
        }
    }
}

extension FanAutoRule.Target {
    var title: String {
        switch self {
        case .system: String(localized: "System control")
        case .quiet: String(localized: "Quiet")
        case .balanced: String(localized: "Balanced")
        case .performance: String(localized: "Performance")
        }
    }
}
