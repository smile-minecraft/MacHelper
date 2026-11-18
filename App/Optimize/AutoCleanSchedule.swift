import Foundation
import ServiceManagement

/// Status of the composed background agent, stripped of ServiceManagement types so the logic can
/// be unit-tested without constructing a real SMAppService.
enum AutoCleanAgentStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
}

/// The composition over SMAppService the migration talks to. Production uses
/// `SMAppServiceAgentServicing`; tests use a scripted fake. MainActor-bound, like every other
/// SMAppService touchpoint in the app, so the non-Sendable SMAppService never crosses an
/// isolation boundary.
@MainActor
protocol AutoCleanAgentServicing {
    var status: AutoCleanAgentStatus { get }
    func register() throws
    func unregister() async throws
}

struct SMAppServiceAgentServicing: AutoCleanAgentServicing {
    static let plistName = "com.machelper.MacHelper.AutoClean.plist"
    private let agent = SMAppService.agent(plistName: plistName)

    var status: AutoCleanAgentStatus {
        switch agent.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        default: return .unknown
        }
    }

    func register() throws { try agent.register() }

    func unregister() async throws { try await agent.unregister() }
}

/// The version of the schedule embedded in the shipped plist.
/// 1 = every 60 minutes, 2 = every 30 minutes. Bump this only together with the plist.
enum AutoCleanAgentScheduleVersion {
    static let current = 2
}

enum AutoCleanScheduleMigration {
    static let defaultsKey = "MacHelper.autoCleanAgent.plistVersion"

    private static let pendingKey = "MacHelper.autoCleanAgent.migrationPending"

    enum Outcome: Equatable {
        /// Recorded version is already the one being shipped; no agent call was made.
        case alreadyCurrent
        /// Agent is not `.enabled`; fresh registrations install the current plist themselves.
        case inactive
        /// Unregistered and re-registered; marker updated.
        case migrated
        /// Either unregister or register failed. The marker was not updated, so the next
        /// refresh, the next frequency change, or an explicit retry will attempt migration again.
        case failed(String)
    }

    /// Persist intent before unregistering so a relaunch can resume if registration was interrupted.
    /// The caller serializes service operations and supplies the current setting after suspension.
    @MainActor
    static func runIfNeeded(servicing: any AutoCleanAgentServicing,
                            defaults: UserDefaults = .standard,
                            shouldRegister: () -> Bool = { true }) async -> Outcome {
        guard shouldRegister() else { return .inactive }
        if defaults.integer(forKey: defaultsKey) >= AutoCleanAgentScheduleVersion.current {
            return .alreadyCurrent
        }
        let pending = defaults.bool(forKey: pendingKey)
        let status = servicing.status
        guard status == .enabled || (pending && status == .notRegistered) else { return .inactive }
        defaults.set(true, forKey: pendingKey)
        do {
            if status == .enabled { try await servicing.unregister() }
            guard shouldRegister() else { return .inactive }
            try servicing.register()
            recordRegistration(defaults: defaults)
            return .migrated
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @MainActor
    static func cancel(defaults: UserDefaults) {
        defaults.removeObject(forKey: pendingKey)
    }

    /// Marks the registered agent as current. Called when the user enables Auto Clean (a fresh
    /// `register()` installs the embedded plist) — no migration call needed afterwards.
    @MainActor
    static func recordRegistration(defaults: UserDefaults = .standard,
                                   version: Int = AutoCleanAgentScheduleVersion.current) {
        defaults.set(version, forKey: defaultsKey)
        cancel(defaults: defaults)
    }
}
