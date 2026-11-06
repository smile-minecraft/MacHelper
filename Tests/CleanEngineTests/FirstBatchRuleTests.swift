import Foundation
import Testing
@testable import CleanEngine

@Suite struct FirstBatchRuleTests {
    private func rule(_ id: String, _paths paths: [String], processes: [String]) throws -> CleanRule {
        let json: [String: Any] = ["id": id, "title": id, "category": "test", "risk": "low", "paths": paths,
                                   "skipIfProcessRunning": processes]
        return try JSONDecoder().decode(CleanRule.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func seesItsOwnProcess() {
        let own = String(ProcessInfo.processInfo.processName.prefix(CleanScanner.processNameLength))
        #expect(CleanScanner.runningProcessNames().contains(own))
    }

    @Test func ruleIsSkippedWhileItsProcessRuns() throws {
        let t = try TempDir()
        try t.file("cache/pkg/a.bin", bytes: 20_000)
        let safety = PathSafety(protectedPaths: [], whitelist: [], allowedRoots: [t.path], minimumDepth: 2)
        let own = ProcessInfo.processInfo.processName
        let busy = try rule("busy", _paths: [t.path + "/cache/*"], processes: [own])
        let idle = try rule("idle", _paths: [t.path + "/cache/*"], processes: ["no-such-process-\(UUID().uuidString.prefix(6))"])

        let skipped = CleanScanner(rules: [busy], safety: safety).scan().results[0]
        #expect(skipped.candidates.isEmpty && skipped.skippedReason != nil)
        let found = CleanScanner(rules: [idle], safety: safety).scan().results[0]
        #expect(found.candidates.map(\.path) == [t.path + "/cache/pkg"])
    }

    @Test func newRulesAreLowRiskAndInHome() throws {
        let ids = ["browser.arc-service-worker", "dev.vscode", "dev.opencode", "dev.npm-logs", "dev.corepack",
                   "dev.bun", "dev.gh", "shell.zsh-cache", "xcode.xctestdevices"]
        let rules = try RuleSet.load(includeUserRules: false)
        let safety = PathSafety.forCleaning()
        for id in ids {
            let r = try #require(rules.first { $0.id == id }, "\(id) missing")
            #expect(r.risk == .low && r.action == .trash)
            #expect(r.title != "rule.\(id).title", "\(id) has no translation entry")
            for p in r.paths {
                // A representative match must be allowed by the cleaning safety rules (not protected, deep enough).
                let sample = expandTilde(p).replacingOccurrences(of: "*", with: "x")
                #expect(safety.check(sample) == .allowed, "\(id): \(p)")
            }
        }
    }

    @Test func clangTaskStaysInUserCache() throws {
        let path = try #require(MaintenanceCatalog.clangModuleCache)
        #expect(path.hasSuffix("/clang/ModuleCache") && path.contains("/var/folders/"))
        if let task = MaintenanceCatalog.all.first(where: { $0.id == "clang.module-cache" }) {
            #expect(!task.selectedByDefault && !task.requiresRoot)
        }
    }
}
