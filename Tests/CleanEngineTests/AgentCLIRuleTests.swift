import Foundation
import Testing
@testable import CleanEngine

/// Rules for the local coding agents (Claude Code, Codex, OpenCode). Their caches, temp files and
/// logs are low risk and guarded by the agent's process name; their session histories are never
/// preselected, go to the Trash, and are matched file by file so a session still being written is
/// never caught by its month folder's old date.
@Suite struct AgentCLIRuleTests {
    static let tempRules = ["ai.claude-cache": "claude", "ai.codex-cache": "codex", "ai.codex-logs": "codex",
                            "ai.codex-temp": "codex", "ai.opencode-log": "opencode"]
    static let historyRules = ["ai.claude-transcripts": "claude", "ai.codex-sessions": "codex",
                               "ai.opencode-tool-output": "opencode"]
    /// The desktop app shares the CLI's data folder and may run while no `opencode` process exists.
    static let openCodeRules = ["ai.opencode-log", "ai.opencode-tool-output"]
    static let openCodeDesktopBundleIDs = ["ai.opencode.desktop", "ai.opencode.desktop.beta", "ai.opencode.desktop.dev"]

    private func sample(_ pattern: String) -> String {
        expandTilde(pattern).replacingOccurrences(of: "*", with: "x")
    }

    /// The real rules, pointed at a synthetic home folder so no real agent data is ever read.
    private func syntheticRule(_ id: String, home: TempDir) throws -> CleanRule {
        var rule = try #require(try RuleSet.load(includeUserRules: false).first { $0.id == id }, "\(id) missing")
        rule.paths = rule.paths.map { $0.replacingOccurrences(of: "~", with: home.path) }
        rule.skipIfRunning = []
        rule.skipIfProcessRunning = []
        return rule
    }

    private func safety(_ t: TempDir) -> PathSafety {
        PathSafety(protectedPaths: [], whitelist: [], allowedRoots: [t.path], minimumDepth: 2)
    }

    @Test func tempRulesAreLowRiskAndGuarded() throws {
        let rules = try RuleSet.load(includeUserRules: false)
        let safety = PathSafety.forCleaning(whitelist: [])
        for (id, cli) in Self.tempRules {
            let r = try #require(rules.first { $0.id == id }, "\(id) missing")
            #expect(r.category == "ai", "\(id)")
            #expect(r.risk == .low && r.action == .delete && r.selectedByDefault, "\(id)")
            #expect(r.skipIfProcessRunning == [cli], "\(id) must pause while \(cli) runs")
            #expect(r.minAgeDays > 0, "\(id): temp files must be stale before they are touched")
            for p in r.paths { #expect(safety.check(sample(p)) == .allowed, "\(id): \(p)") }
        }
    }

    @Test func openCodeRulesAlsoPauseWhileTheDesktopAppRuns() throws {
        let rules = try RuleSet.load(includeUserRules: false)
        for id in Self.openCodeRules {
            let r = try #require(rules.first { $0.id == id }, "\(id) missing")
            #expect(r.skipIfRunning == Self.openCodeDesktopBundleIDs,
                    "\(id): the desktop app writes the same data folder as the CLI")
        }
    }

    @Test func historyRulesAskFirstAndGoToTheTrash() throws {
        let rules = try RuleSet.load(includeUserRules: false)
        let safety = PathSafety.forCleaning(whitelist: [])
        for (id, cli) in Self.historyRules {
            let r = try #require(rules.first { $0.id == id }, "\(id) missing")
            #expect(r.risk != .low && r.action == .trash && !r.selectedByDefault, "\(id)")
            #expect(r.skipIfProcessRunning == [cli], "\(id) must pause while \(cli) runs")
            #expect(r.minAgeDays >= 30, "\(id): only finished sessions are offered")
            for p in r.paths {
                #expect(safety.check(sample(p)) == .allowed, "\(id): \(p)")
                #expect(!p.contains("/bin/") && !p.contains("config") && !p.contains("auth"),
                        "\(id): \(p) must not match the agent's own program, config or credentials")
            }
        }
    }

    @Test func sqliteGlobsMatchLogDatabasesAndTheirSidecarsOnly() throws {
        let t = try TempDir()
        for f in ["logs_2.sqlite", "logs_2.sqlite-wal", "logs_2.sqlite-shm",
                  "state_5.sqlite", "memories_1.sqlite", "thread_history_1.sqlite"] {
            try t.file(".codex/\(f)", bytes: 16)
        }
        let codexLogs = expandGlob(t.path + "/.codex/logs_*.sqlite*").map { ($0 as NSString).lastPathComponent }.sorted()
        #expect(codexLogs == ["logs_2.sqlite", "logs_2.sqlite-shm", "logs_2.sqlite-wal"],
                "state, memories and thread history databases must not be matched")
    }

    @Test func sessionGlobsMatchFinishedHistoryNotLiveSessions() throws {
        let t = try TempDir()
        // Claude Code stores one transcript per session directly in the project folder; the
        // session's own subfolder (file history) stays.
        try t.file(".claude/projects/-proj/old.jsonl", bytes: 16)
        try t.file(".claude/projects/-proj/0600/file-history.jsonl", bytes: 16)
        let claude = expandGlob(t.path + "/.claude/projects/*/*.jsonl").map { ($0 as NSString).lastPathComponent }
        #expect(claude == ["old.jsonl"])

        // Codex files sessions as sessions/YYYY/MM/DD/rollout-*.jsonl: the pattern must select
        // session files, never a whole month folder whose date says nothing about the files inside.
        try t.file(".codex/sessions/2026/03/18/rollout-a.jsonl", bytes: 16)
        try t.file(".codex/sessions/2026/11/18/rollout-b.jsonl", bytes: 16)
        try t.file(".codex/sessions/2026/03/18/notes.txt", bytes: 16)
        let sessions = expandGlob(t.path + "/.codex/sessions/*/*/*/*.jsonl")
            .map { ($0 as NSString).lastPathComponent }.sorted()
        #expect(sessions == ["rollout-a.jsonl", "rollout-b.jsonl"], "only session files, nothing else")
    }

    @Test func codexSessionHistoryIsScannedFileByFileAndNeverPreselected() throws {
        let t = try TempDir()
        // The directory dates are all old; only the files' own mtimes separate finished sessions
        // from one that was resumed (appended) today inside an old month.
        let old = try t.file(".codex/sessions/2026/03/18/rollout-2026-03-18T09-00-00-a.jsonl",
                             bytes: 4_096, ageDays: 45)
        let resumed = try t.file(".codex/sessions/2026/03/18/rollout-2026-03-18T09-00-00-b.jsonl",
                                 bytes: 4_096, ageDays: 0)
        let current = try t.file(".codex/sessions/2026/11/18/rollout-2026-11-18T09-00-00-c.jsonl",
                                 bytes: 4_096, ageDays: 0)
        let archived = try t.file(".codex/archived_sessions/rollout-2026-01-01T09-00-00-d.jsonl",
                                  bytes: 4_096, ageDays: 45)

        let rule = try syntheticRule("ai.codex-sessions", home: t)
        let plan = CleanScanner(rules: [rule], safety: safety(t)).scan()
        let result = try #require(plan.results.first)
        #expect(result.skippedReason == nil)
        #expect(Set(result.candidates.map(\.path)) == Set([old, archived]),
                "a session appended today inside an old month must not be offered: \(resumed), \(current)")
        #expect(result.candidates.allSatisfy { !$0.selected }, "session history is never preselected")
        #expect(plan.removalItems.isEmpty, "unselected candidates never reach the executor")
    }

    @Test func processAppearingAfterTheScanStopsTheRemoval() throws {
        let t = try TempDir()
        let file = try t.file(".codex/tmp/old.bin", bytes: 4_096, ageDays: 10)

        // A guard name that no real process has while the scan runs, spelled with flipped case to
        // prove the match does not depend on the executable name's casing.
        let guardName = "mhguard" + UUID().uuidString.prefix(8).lowercased()
        var rule = try syntheticRule("ai.codex-temp", home: t)
        rule.skipIfProcessRunning = [guardName.uppercased()]

        let plan = CleanScanner(rules: [rule], safety: safety(t)).scan()
        let items = plan.removalItems
        try #require(items.count == 1, "the guarded rule produced candidates while nothing ran")
        #expect(items[0].path == file)
        #expect(items[0].skipIfProcessRunning == [guardName.uppercased()],
                "the plan must carry the rule's guard to the executor")

        // The agent appears only now, after the preview was built.
        let binDir = t.url.appending(path: "procbin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let exe = binDir.appending(path: guardName)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: exe)
        let agent = Process()
        agent.executableURL = exe
        agent.arguments = ["60"]
        try agent.run()
        defer { if agent.isRunning { agent.terminate() }; agent.waitUntilExit() }
        try #require(waitUntil { CleanScanner.runningProcessNames().contains(guardName) },
                     "the synthetic agent process never became visible")

        let backend = TestTrashBackend(trashDirectory: t.url.appending(path: "test-trash"))
        let log = OperationLog(url: t.url.appending(path: "operations.jsonl"))
        let executor = CleanExecutor.injected(safety: safety(t), log: log, removal: backend.backend)

        let preview = executor.execute(items, dryRun: true, command: "test")
        #expect(preview.items.map(\.result) == [.skipped], "a dry run reports the guard as skipped too")
        #expect(preview.items[0].message?.hasPrefix("guard:") == true)
        #expect(t.exists(".codex/tmp/old.bin"))

        let report = executor.execute(items, dryRun: false, command: "test")
        #expect(report.items.map(\.result) == [.skipped])
        #expect(report.items[0].message == "guard: \(guardName.uppercased()) is running")
        #expect(t.exists(".codex/tmp/old.bin"), "the file must survive while the agent runs")
        #expect(backend.trashedPaths.isEmpty && backend.deletedPaths.isEmpty)
        #expect(log.read().map(\.result) == ["skipped"], "the dry run above is not logged")

        // Once the agent is gone the same item can be removed; the guard is a pause, not a block.
        agent.terminate()
        agent.waitUntilExit()
        try #require(waitUntil { !CleanScanner.runningProcessNames().contains(guardName) },
                     "the synthetic agent process never went away")
        let after = executor.execute(items, dryRun: false, command: "test")
        #expect(after.items.map(\.result) == [.deleted])
        #expect(!t.exists(".codex/tmp/old.bin"))
        #expect(backend.deletedPaths == [file])
    }

    @Test func guardNamesMatchCaseInsensitively() throws {
        let t = try TempDir()
        try t.file("cache/pkg/a.bin", bytes: 20_000)
        // The scanner's own process: running for sure, and its name spelled in the other case.
        let own = ProcessInfo.processInfo.processName
        let rule = CleanRule(id: "case", title: "case", description: "", category: "test", risk: .low,
                             paths: [t.path + "/cache/*"], skipIfProcessRunning: [own.uppercased()])
        let result = CleanScanner(rules: [rule], safety: safety(t)).scan().results[0]
        #expect(result.candidates.isEmpty && result.skippedReason != nil,
                "a guard in upper case must still pause the rule")
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    @Test func everyRuleIsTranslatedInAllSixLanguages() throws {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()   // Tests/CleanEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let data = try Data(contentsOf: repoRoot.appending(path: "Sources/CleanEngine/Rules.xcstrings"))
        let table = try JSONDecoder().decode(XCStringsTable.self, from: data)
        for id in Set(Self.tempRules.keys).union(Self.historyRules.keys) {
            for suffix in ["title", "description"] {
                let key = "rule.\(id).\(suffix)"
                let entry = try #require(table.strings[key], "\(key) missing")
                for lang in ["en", "zh-Hant", "zh-Hans", "ja", "ko", "es"] {
                    let unit = try #require(entry.localizations[lang]?.stringUnit, "\(key): \(lang) missing")
                    #expect(unit.state == "translated" && !unit.value.isEmpty, "\(key): \(lang)")
                }
            }
        }
        // The rules this PR deliberately does not ship must not leave orphaned text behind.
        for id in ["ai.codex-thread-history", "ai.opencode-snapshot", "ai.opencode-db", "ai.pi-sessions", "ai.pi-logs"] {
            for suffix in ["title", "description"] {
                #expect(table.strings["rule.\(id).\(suffix)"] == nil, "rule.\(id).\(suffix) is orphaned")
            }
        }
    }
}

/// The subset of the .xcstrings shape the translation test needs.
private struct XCStringsTable: Decodable {
    var strings: [String: Entry]
    struct Entry: Decodable {
        var localizations: [String: Localization]
        struct Localization: Decodable {
            var stringUnit: StringUnit?
            struct StringUnit: Decodable {
                var state: String
                var value: String
            }
        }
    }
}
