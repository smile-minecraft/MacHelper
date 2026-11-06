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
            #expect(r.risk == .low && r.action == .delete)
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

@Suite struct DeletionPolicyTests {
    private func rule(risk: String, action: String? = nil) throws -> CleanRule {
        var json: [String: Any] = ["id": "r", "title": "r", "category": "test", "risk": risk, "paths": ["~/x/*"]]
        if let action { json["action"] = action }
        return try JSONDecoder().decode(CleanRule.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func actionFollowsRiskUnlessStated() throws {
        #expect(try rule(risk: "low").action == .delete)
        #expect(try rule(risk: "medium").action == .trash)
        #expect(try rule(risk: "high").action == .trash)
        #expect(try rule(risk: "low", action: "trash").action == .trash, "an explicit action wins")
    }

    @Test func alwaysTrashOverridesExceptForTheTrashItself() {
        let executor = CleanExecutor(safety: .forCleaning(), alwaysTrash: true)
        let cache = RemovalItem(path: MacHelperPaths.home.path + "/Library/Caches/x", source: "user.caches", bytes: 1, action: .delete)
        let trashed = RemovalItem(path: MacHelperPaths.home.path + "/.Trash/old", source: "user.trash", bytes: 1, action: .delete)
        #expect(executor.action(for: cache) == .trash)
        #expect(executor.action(for: trashed) == .delete)
        #expect(CleanExecutor(safety: .forCleaning(), permanent: true, alwaysTrash: true).action(for: cache) == .delete)
    }

    @Test func oldAutoCleanConfigStillDecodes() throws {
        let old = #"{"enabled":true,"frequency":"daily","permanent":false,"lastTrashedBytes":0,"lastFreedBytes":0,"lastItemCount":0}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(AutoCleanConfig.self, from: Data(old.utf8))
        #expect(config.enabled && config.trashInstead == nil)
    }
}
