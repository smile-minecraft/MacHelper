import Foundation
import PrivilegedOps
import Testing
@testable import CleanEngine

@Suite struct SystemStartupToggleTests {
    private func item(_ label: String, scope: StartupItem.Scope, path: String? = nil) -> StartupItem {
        StartupItem(label: label, plistPath: path ?? "\(scope == .systemDaemon ? "/Library/LaunchDaemons" : "/Library/LaunchAgents")/\(label).plist",
                    scope: scope, program: "/usr/bin/true", arguments: [], runAtLoad: true, keepAlive: false, interval: nil,
                    isLoaded: false, pid: nil, isDisabled: false, programMissing: false, ownerName: nil, ownerPath: nil)
    }

    @Test func onlyYourOwnItemsCanBeRemoved() throws {
        #expect(StartupItem.Scope.userAgent.canRemove)
        #expect(!StartupItem.Scope.systemAgent.canRemove)
        #expect(!StartupItem.Scope.systemDaemon.canRemove)
        #expect(throws: StartupItemError.self) { try StartupItems.remove(item("com.vendor.agent", scope: .systemAgent)) }
        #expect(throws: StartupItemError.self) { try StartupItems.remove(item("com.vendor.daemon", scope: .systemDaemon)) }
    }

    @Test func daemonsGoThroughTheHelper() {
        #expect(StartupItem.Scope.systemDaemon.needsHelper)
        #expect(!StartupItem.Scope.systemAgent.needsHelper && !StartupItem.Scope.userAgent.needsHelper)
        do {
            try StartupItems.checkToggle(item("com.vendor.daemon", scope: .systemDaemon))
            Issue.record("daemon toggles must not run in-process")
        } catch StartupItemError.needsHelper(let l) {
            #expect(l == "com.vendor.daemon")
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test func protectedLabelsAreNeverSwitched() {
        for scope in StartupItem.Scope.allCases {
            let i = item("com.machelper.MacHelper.Helper", scope: scope)
            #expect(i.isProtected)
            do {
                try StartupItems.checkToggle(i)
                Issue.record("protected item accepted")
            } catch StartupItemError.protected { } catch { Issue.record("unexpected \(error)") }
        }
    }

    @Test func systemAgentsAreValidatedLikeTheHelperDoes() {
        // Not directly inside /Library/LaunchAgents → refused before launchctl runs.
        let outside = item("com.vendor.agent", scope: .systemAgent, path: "/tmp/com.vendor.agent.plist")
        #expect(throws: SystemJobControl.ValidationError.notInDirectory("/tmp/com.vendor.agent.plist")) {
            try StartupItems.checkToggle(outside)
        }
    }

    @Test func realSystemAgentsPassValidationReadOnly() {
        // Read-only: every listed third-party agent in /Library/LaunchAgents validates to its own label.
        for i in StartupItems.list(installed: []) where i.scope == .systemAgent && !i.isProtected {
            if (try? SystemJobControl.validate(plistPath: i.plistPath, kind: .agent)) != nil {
                #expect((try? StartupItems.checkToggle(i)) != nil, "\(i.label)")
            }
        }
    }
}

@Suite struct SystemCleanupCatalogTests {
    @Test func everyHelperTargetHasTextAndIsLowRisk() {
        #expect(SystemCleanupCatalog.all.map(\.id) == SystemCleanup.targets.map(\.id))
        for info in SystemCleanupCatalog.all {
            #expect(info.title != info.id)
            #expect(info.risk == .low)
            #expect(info.description.contains("30"))
        }
    }

    @Test func recordWritesDeletionsSummaryAndFailures() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "syslog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OperationLog(url: dir.appending(path: "operations.jsonl"))
        let result = SystemCleanupResult(targets: [
            .init(id: "system.diagnostic-reports", dryRun: false,
                  files: [.init(path: "/Library/Logs/DiagnosticReports/a.ips", bytes: 4096)],
                  count: 3, bytes: 12_288, failures: [.init(path: "/Library/Logs/DiagnosticReports/b.ips", message: "Operation not permitted")],
                  unavailable: nil),
            .init(id: "system.logs", dryRun: true, files: [.init(path: "/Library/Logs/x.log", bytes: 1)], count: 1, bytes: 1,
                  failures: [], unavailable: nil),
        ])
        SystemCleanupCatalog.record(result, log: log)
        let entries = log.read()
        #expect(entries.count == 3, "dry-run targets are not recorded")
        #expect(entries.allSatisfy { $0.command == "clean" && $0.source == "system.diagnostic-reports" })
        let deleted = entries.filter { $0.result == "deleted" }
        #expect(deleted.reduce(0) { $0 + $1.bytes } == 12_288, "listed + summary bytes add up to the total")
        #expect(deleted.contains { $0.path == "/Library/Logs/DiagnosticReports" && $0.message == "2 more files" })
        #expect(entries.filter { $0.result == "failed" }.count == 1)
    }
}
