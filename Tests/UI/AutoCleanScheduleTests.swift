import CleanEngine
import Foundation
import Testing
@testable import UpdatesFeature

/// A scripted background-agent service for the schedule migration. Records every call so a test
/// can assert exactly how many registration operations the migration performs.
@MainActor
private final class FakeAgentServicing: AutoCleanAgentServicing {
    var status: AutoCleanAgentStatus
    var unregisterError: Error?
    var registerError: Error?
    var duringUnregister: (() async -> Void)?
    private(set) var calls: [String] = []

    init(status: AutoCleanAgentStatus) {
        self.status = status
    }

    func register() throws {
        calls.append("register")
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() async throws {
        calls.append("unregister")
        if let unregisterError { throw unregisterError }
        await duringUnregister?()
        status = .notRegistered
    }
}

private struct DummyError: Error {
    let message: String
}

@MainActor
@Suite struct AutoCleanScheduleTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "autoclean-schedule-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test func alreadyCurrentMakesNoAgentCalls() async {
        let (defaults, _) = freshDefaults()
        defaults.set(AutoCleanAgentScheduleVersion.current, forKey: AutoCleanScheduleMigration.defaultsKey)
        let service = FakeAgentServicing(status: .enabled)

        let outcome = await AutoCleanScheduleMigration.runIfNeeded(servicing: service, defaults: defaults)
        #expect(outcome == .alreadyCurrent)
        #expect(service.calls.isEmpty, "a current install must not re-register the agent")
    }

    @Test func freshRegistrationMarksTheVersion() async {
        let (defaults, suite) = freshDefaults()
        AutoCleanScheduleMigration.recordRegistration(defaults: defaults)
        let service = FakeAgentServicing(status: .enabled)

        let outcome = await AutoCleanScheduleMigration.runIfNeeded(servicing: service, defaults: defaults)
        #expect(outcome == .alreadyCurrent)
        #expect(service.calls.isEmpty)
        #expect(defaults.integer(forKey: AutoCleanScheduleMigration.defaultsKey) == AutoCleanAgentScheduleVersion.current)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func oldOrMissingMarkerMigrationReRegistersTheAgent() async throws {
        let (defaults, suite) = freshDefaults()   // marker absent == pre-migration install
        let service = FakeAgentServicing(status: .enabled)

        let outcome = await AutoCleanScheduleMigration.runIfNeeded(servicing: service, defaults: defaults)
        #expect(outcome == .migrated)
        #expect(service.calls == ["unregister", "register"], "an older registered agent moves to the embedded plist exactly once")
        #expect(defaults.integer(forKey: AutoCleanScheduleMigration.defaultsKey) == AutoCleanAgentScheduleVersion.current)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func unregisterFailureStopsMigration() async {
        let (defaults, suite) = freshDefaults()
        let service = FakeAgentServicing(status: .enabled)
        service.unregisterError = DummyError(message: "unregister denied")

        let outcome = await AutoCleanScheduleMigration.runIfNeeded(servicing: service, defaults: defaults)
        guard case .failed = outcome else { Issue.record("unregister error was swallowed"); return }
        #expect(service.calls == ["unregister"])
        #expect(defaults.object(forKey: AutoCleanScheduleMigration.defaultsKey) == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func failedRegisterKeepsMarkerAndReportsError_thenRetrySucceeds() async throws {
        let (defaults, suite) = freshDefaults()
        let service = FakeAgentServicing(status: .enabled)
        service.registerError = DummyError(message: "connection refused")

        let first = await AutoCleanScheduleMigration.runIfNeeded(servicing: service, defaults: defaults)
        guard case .failed(let message) = first else { Issue.record("expected a failed outcome, got \(first)"); return }
        #expect(message.isEmpty == false)
        #expect(defaults.object(forKey: AutoCleanScheduleMigration.defaultsKey) == nil, "a failed migration must not mark the install current")

        service.registerError = nil
        let reopenedDefaults = try #require(UserDefaults(suiteName: suite))
        let second = await AutoCleanScheduleMigration.runIfNeeded(servicing: service, defaults: reopenedDefaults)
        #expect(second == .migrated)
        #expect(defaults.integer(forKey: AutoCleanScheduleMigration.defaultsKey) == AutoCleanAgentScheduleVersion.current)
        #expect(service.calls == ["unregister", "register", "register"], "retry only registers the missing agent")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func offDuringMigrationPreventsReregistration() async throws {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "autoclean.json")
        var config = AutoCleanConfig()
        config.enabled = true
        try AutoClean.save(config, to: configURL)
        let service = FakeAgentServicing(status: .enabled)
        let model = AutoCleanModel(agent: service, configURL: configURL, defaults: defaults)
        service.duringUnregister = { [weak model] in
            guard let model else { return }
            #expect(model.isUpdatingSchedule)
            await model.refreshScheduleMigration()
            model.enabled = false
            await model.refreshScheduleMigration()
        }

        await model.refreshScheduleMigration()
        #expect(service.calls == ["unregister"])
        #expect(model.agentStatus == .notRegistered)
        #expect(!model.isUpdatingSchedule)
        #expect(!AutoClean.load(from: configURL).enabled)
        #expect(model.scheduleMigrationError == nil)

        let reopened = AutoCleanModel(agent: service, configURL: configURL, defaults: defaults)
        await reopened.refreshScheduleMigration()
        #expect(service.calls == ["unregister"])
    }

    @Test(arguments: [AutoCleanAgentStatus.notRegistered, .requiresApproval, .notFound, .unknown])
    func inactiveAgentIsNotMigrated(status: AutoCleanAgentStatus) async {
        let (defaults, suite) = freshDefaults()
        let service = FakeAgentServicing(status: status)

        let outcome = await AutoCleanScheduleMigration.runIfNeeded(servicing: service, defaults: defaults)
        #expect(outcome == .inactive)
        #expect(service.calls.isEmpty)
        #expect(defaults.object(forKey: AutoCleanScheduleMigration.defaultsKey) == nil)
        defaults.removePersistentDomain(forName: suite)
    }
}
