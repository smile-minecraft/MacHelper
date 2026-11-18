import Foundation
import ServiceManagement

/// One-time migration of the embedded Auto Clean background agent to the plist that ships with
/// this app.
///
/// launchd keeps the copy of the plist that was registered when the agent was enabled. After an
/// app update ships a new schedule (this release moves the trigger to every 30 minutes), an
/// existing install keeps the old registration until the service is registered again — simply
/// looking at `SMAppService.agent(plistName:).status` on a new build does not re-read the file.
///
/// So instead of re-registering on every refresh and hoping, the app performs one explicit,
/// visible, retryable migration:
///
/// - `AutoCleanAgentScheduleVersion.current` is bumped only when the embedded plist's schedule
///   changes.
/// - A persisted `defaults` marker records the plist version the *registered* agent was
///   installed with; a missing marker is treated as version 1 (the hourly trigger).
/// - On refresh and on an explicit frequency change, `runIfNeeded` compares the two. When the
///   agent is not `.enabled`, nothing happens (fresh registrations already install the current
///   plist). When it is enabled and older, one explicit unregister + register moves it over;
///   success stores the marker.
/// - Failure keeps the marker (so refresh/frequency change/Retry can attempt it again), is
///   surfaced in Settings with a Retry action, and does not churn the agent otherwise.

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

    /// Called from `refresh()` and when the user picks a frequency. No-ops (and performs no
    /// agent calls) whenever the recorded version is current.
    @MainActor
    static func runIfNeeded(servicing: any AutoCleanAgentServicing,
                            defaults: UserDefaults = .standard,
                            version: Int = AutoCleanAgentScheduleVersion.current) async -> Outcome {
        let stored = defaults.object(forKey: defaultsKey) as? Int
        if let stored, stored >= version { return .alreadyCurrent }
        guard servicing.status == .enabled else { return .inactive }
        do {
            // Tolerate the agent already being gone; a failed register is the error that matters.
            try? await servicing.unregister()
            try servicing.register()
            defaults.set(version, forKey: defaultsKey)
            return .migrated
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Marks the registered agent as current. Called when the user enables Auto Clean (a fresh
    /// `register()` installs the embedded plist) — no migration call needed afterwards.
    @MainActor
    static func recordRegistration(defaults: UserDefaults = .standard,
                                   version: Int = AutoCleanAgentScheduleVersion.current) {
        defaults.set(version, forKey: defaultsKey)
    }
}
