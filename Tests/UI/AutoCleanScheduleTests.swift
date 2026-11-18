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

    @Test func pendingRegistrationResumesEvenWhenTheVersionIsCurrent() async {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        // An updated install that disabled Auto Clean keeps the current-version marker. Then a
        // re-enable failed mid-registration: the intent marker is set, the agent is gone. The
        // resume path must win over the version check, or that user is never re-registered.
        defaults.set(AutoCleanAgentScheduleVersion.current, forKey: AutoCleanScheduleMigration.defaultsKey)
        AutoCleanScheduleMigration.markPending(defaults: defaults)
        let service = FakeAgentServicing(status: .notRegistered)

        let outcome = await AutoCleanScheduleMigration.runIfNeeded(servicing: service, defaults: defaults)

        #expect(outcome == .migrated)
        #expect(service.calls == ["register"])
    }

    @Test func failedReenableRegistrationIsRetriedOnRefresh() async throws {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appending(path: "autoclean.json")
        var config = AutoCleanConfig()
        config.enabled = false
        try AutoClean.save(config, to: configURL)
        // An install that already saw the current schedule: only the resume path can recover
        // a registration that fails while re-enabling.
        defaults.set(AutoCleanAgentScheduleVersion.current, forKey: AutoCleanScheduleMigration.defaultsKey)
        let service = FakeAgentServicing(status: .notRegistered)
        service.registerError = DummyError(message: "connection refused")
        let model = AutoCleanModel(agent: service, configURL: configURL, defaults: defaults)

        model.enabled = true
        while !service.calls.contains("register") { await Task.yield() }
        while model.isUpdatingSchedule { await Task.yield() }
        #expect(model.message?.isEmpty == false, "the failed registration is surfaced")
        #expect(service.calls == ["register", "register"],
                "the enable operation itself retries once through the pending marker")
        #expect(model.scheduleMigrationError?.isEmpty == false, "the second failure surfaces with a Retry action")

        service.registerError = nil
        await model.refreshScheduleMigration()
        #expect(service.calls == ["register", "register", "register"], "a refresh must resume the interrupted registration")
        #expect(model.agentStatus == .enabled)
        #expect(model.scheduleMigrationError == nil)
        #expect(defaults.integer(forKey: AutoCleanScheduleMigration.defaultsKey) == AutoCleanAgentScheduleVersion.current)
    }

    @Test func shippedPlistMatchesCurrentScheduleVersion() throws {
        // The migration only moves existing installs to the plist embedded in the app bundle, so
        // the shipped trigger and `AutoCleanAgentScheduleVersion.current` must change together —
        // otherwise existing installs silently keep their old trigger forever.
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/Launchd/com.machelper.MacHelper.AutoClean.plist")
        let data = try Data(contentsOf: plist)
        let contents = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let interval = contents?["StartInterval"] as? Int
        // Schedule version history: 1 = hourly (3600 s), 2 = every 30 minutes (1800 s).
        let expected: [Int: Int] = [1: 3600, 2: 1800]
        let target = try #require(expected[AutoCleanAgentScheduleVersion.current],
                                   "bump the version together with the plist, or existing installs never migrate")
        #expect(interval == target)
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
