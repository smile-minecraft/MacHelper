import Foundation
import Testing
@testable import CleanEngine

/// Rules for the local coding agents (Claude Code, Codex, OpenCode, Pi). Their caches, temp files
/// and logs are low risk and guarded by the agent's process name; their conversation history,
/// snapshots and databases are never preselected and go to the Trash.
@Suite struct AgentCLIRuleTests {
    static let tempRules = ["ai.claude-cache": "claude", "ai.codex-cache": "codex", "ai.codex-logs": "codex",
                            "ai.codex-temp": "codex", "ai.opencode-log": "opencode", "ai.pi-logs": "pi"]
    static let historyRules = ["ai.claude-transcripts": "claude", "ai.codex-sessions": "codex",
                               "ai.codex-thread-history": "codex", "ai.opencode-db": "opencode",
                               "ai.opencode-snapshot": "opencode", "ai.opencode-tool-output": "opencode",
                               "ai.pi-sessions": "pi"]

    private func sample(_ pattern: String) -> String {
        expandTilde(pattern).replacingOccurrences(of: "*", with: "x")
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

    @Test func historyRulesAskFirstAndGoToTheTrash() throws {
        let rules = try RuleSet.load(includeUserRules: false)
        let safety = PathSafety.forCleaning(whitelist: [])
        // Whole-file databases have no age (their mtime is the last use); everything else is
        // history of finished sessions and must be at least 30 days old.
        let noAge = ["ai.opencode-db", "ai.codex-thread-history"]
        for (id, cli) in Self.historyRules {
            let r = try #require(rules.first { $0.id == id }, "\(id) missing")
            #expect(r.risk != .low && r.action == .trash && !r.selectedByDefault, "\(id)")
            #expect(r.skipIfProcessRunning == [cli], "\(id) must pause while \(cli) runs")
            #expect(noAge.contains(id) ? r.minAgeDays == 0 : r.minAgeDays >= 30, "\(id)")
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

        try t.file(".local/share/opencode/opencode.db", bytes: 16)
        try t.file(".local/share/opencode/opencode.db-wal", bytes: 16)
        try t.file(".local/share/opencode/opencode.db-shm", bytes: 16)
        try t.file(".local/share/opencode/other.db", bytes: 16)
        let opencodeDB = expandGlob(t.path + "/.local/share/opencode/opencode.db*").map { ($0 as NSString).lastPathComponent }.sorted()
        #expect(opencodeDB == ["opencode.db", "opencode.db-shm", "opencode.db-wal"])
    }

    @Test func transcriptGlobsMatchFinishedHistoryNotLiveSessions() throws {
        let t = try TempDir()
        // Claude Code stores one transcript per session directly in the project folder; the
        // session's own subfolder (file history) stays.
        try t.file(".claude/projects/-proj/old.jsonl", bytes: 16)
        try t.file(".claude/projects/-proj/0600/file-history.jsonl", bytes: 16)
        let claude = expandGlob(t.path + "/.claude/projects/*/*.jsonl").map { ($0 as NSString).lastPathComponent }
        #expect(claude == ["old.jsonl"])

        // Codex groups sessions by year/month: each month folder is one candidate, so the
        // current month is kept fresh by its own writes.
        try t.file(".codex/sessions/2026/03/rollout.jsonl", bytes: 16)
        try t.file(".codex/sessions/2026/11/rollout.jsonl", bytes: 16)
        let months = expandGlob(t.path + "/.codex/sessions/*/*").sorted()
        #expect(months == [t.path + "/.codex/sessions/2026/03", t.path + "/.codex/sessions/2026/11"])
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
