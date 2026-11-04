import Darwin
import Foundation
import Testing
@testable import CleanEngine

final class TempDir {
    let url: URL
    var path: String { url.path }
    init() throws {
        let raw = FileManager.default.temporaryDirectory.appending(path: "clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // realpath gives /private/var/…, the same form the engine normalizes to
        // (URL.resolvingSymlinksInPath would strip /private instead).
        url = URL(fileURLWithPath: String(cString: realpath(raw.path, nil)))
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ rel: String, bytes: Int = 10_000, ageDays: Double = 0) throws -> String {
        let u = url.appending(path: rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: u)
        if ageDays > 0 { try setAge(rel, days: ageDays) }
        return u.path
    }

    func dir(_ rel: String, ageDays: Double = 0) throws {
        try FileManager.default.createDirectory(at: url.appending(path: rel), withIntermediateDirectories: true)
        if ageDays > 0 { try setAge(rel, days: ageDays) }
    }

    func setAge(_ rel: String, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.appending(path: rel).path)
    }

    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: url.appending(path: rel).path) }
}

private func rule(_ id: String, _ paths: [String], exclude: [String] = [], minAge: Int = 0,
                  action: String = "delete", selected: Bool = true) throws -> CleanRule {
    let json: [String: Any] = ["id": id, "title": id, "category": "test", "risk": "low", "paths": paths,
                               "exclude": exclude, "minAgeDays": minAge, "action": action, "selectedByDefault": selected]
    return try JSONDecoder().decode(CleanRule.self, from: JSONSerialization.data(withJSONObject: json))
}

@Suite struct PathSafetyTests {
    func safety(_ t: TempDir, whitelist: [String] = []) -> PathSafety {
        PathSafety(protectedPaths: [t.path + "/keep", "/System"], whitelist: whitelist, allowedRoots: [t.path], minimumDepth: 2)
    }

    @Test func verdicts() throws {
        let t = try TempDir()
        let s = safety(t)
        #expect(s.check(t.path + "/a/b") == .allowed)
        #expect(s.check(t.path + "/a") == .tooShallow)
        #expect(s.check(t.path + "/keep/x/y") == .protected(t.path + "/keep"))
        #expect(s.check("/System/Library/x") == .protected("/System"))
        #expect(s.check("/usr/local/x") == .outsideAllowedRoots)
    }

    @Test func refusesItemsThatContainProtectedData() throws {
        let t = try TempDir()
        let s = PathSafety(protectedPaths: [t.path + "/a/b/keep"], whitelist: [], allowedRoots: [t.path], minimumDepth: 1)
        #expect(s.check(t.path + "/a/b") == .protected(t.path + "/a/b/keep"))
    }

    @Test func whitelistWins() throws {
        let t = try TempDir()
        let s = safety(t, whitelist: [t.path + "/a/*"])
        #expect(s.check(t.path + "/a/b") == .whitelisted(t.path + "/a/*"))
    }

    @Test func symlinkedParentIsResolved() throws {
        let t = try TempDir()
        try t.dir("keep/inner")
        try FileManager.default.createSymbolicLink(atPath: t.path + "/a", withDestinationPath: t.path + "/keep")
        // a/inner looks allowed, but really lives in keep/.
        #expect(safety(t).check(t.path + "/a/inner") == .protected(t.path + "/keep"))
    }
}

@Suite struct BuiltInRuleTests {
    @Test func rulesLoadAndAreSane() throws {
        let rules = try RuleSet.load(includeUserRules: false)
        #expect(rules.count >= 25)
        #expect(Set(rules.map(\.id)).count == rules.count, "rule ids must be unique")
        for r in rules {
            for p in r.paths { #expect(p.hasPrefix("~/"), "\(r.id): rules must stay in the home folder") }
            #expect(r.paths.allSatisfy { !$0.hasSuffix("~/") && $0 != "~/*" }, "\(r.id): too broad")
            if r.risk == .high { #expect(!r.selectedByDefault, "\(r.id): high risk must not be preselected") }
            if r.action == .delete { #expect(r.id == "user.trash", "\(r.id): only emptying the Trash deletes permanently") }
        }
    }

    @Test func detectorsLoad() throws {
        let d = try ArtifactDetector.loadBuiltIn()
        #expect(d.contains { $0.id == "node" && $0.artifacts.contains("node_modules") })
    }
}

@Suite struct CleanScannerTests {
    @Test func globsExcludesAgeAndOverlap() throws {
        let t = try TempDir()
        try t.file("Caches/app1/data.bin", bytes: 50_000)
        try t.file("Caches/app2/data.bin", bytes: 20_000)
        try t.file("Caches/com.apple.thing/data.bin")
        try t.file("Caches/special/x.bin")
        try t.file("Old/new.dmg")
        try t.file("Old/old.dmg", ageDays: 30)

        let safety = PathSafety(protectedPaths: [], whitelist: [], allowedRoots: [t.path], minimumDepth: 2)
        let rules = [
            try rule("specific", [t.path + "/Caches/special"]),
            try rule("caches", [t.path + "/Caches/*"], exclude: [t.path + "/Caches/com.apple.*"]),
            try rule("old", [t.path + "/Old/*.dmg"], minAge: 7),
        ]
        let plan = CleanScanner(rules: rules, safety: safety).scan()
        let byRule = Dictionary(uniqueKeysWithValues: plan.results.map { ($0.rule.id, $0.candidates.map { ($0.path as NSString).lastPathComponent }) })

        #expect(byRule["specific"] == ["special"])
        #expect(byRule["caches"] == ["app1", "app2"])          // excluded com.apple.*, special claimed earlier, sorted by size
        #expect(byRule["old"] == ["old.dmg"])                  // new.dmg too young
        #expect(plan.results.first { $0.rule.id == "caches" }!.totalSize >= 70_000)
    }

    @Test func refusedPathsAreReported() throws {
        let t = try TempDir()
        try t.file("keep/x/file.bin")
        let safety = PathSafety(protectedPaths: [t.path + "/keep"], whitelist: [], allowedRoots: [t.path], minimumDepth: 1)
        let plan = CleanScanner(rules: [try rule("r", [t.path + "/keep/*"])], safety: safety).scan()
        #expect(plan.results[0].candidates.isEmpty)
        #expect(plan.results[0].refused == [t.path + "/keep/x"])
    }
}

@Suite struct CleanExecutorTests {
    @Test func dryRunRemovesNothing() throws {
        let t = try TempDir()
        let f = try t.file("a/b/file.bin")
        let safety = PathSafety(protectedPaths: [], whitelist: [], allowedRoots: [t.path], minimumDepth: 2)
        let log = OperationLog(url: t.url.appending(path: "log.jsonl"))
        let report = CleanExecutor(safety: safety, log: log)
            .execute([RemovalItem(path: f, source: "r", bytes: 1, action: .delete)], dryRun: true, command: "test")
        #expect(report.items.first?.result == .wouldDelete)
        #expect(t.exists("a/b/file.bin"))
        #expect(log.read().isEmpty, "dry runs are not logged")
    }

    @Test func deletesAndLogs() throws {
        let t = try TempDir()
        let f = try t.file("a/b/file.bin")
        let safety = PathSafety(protectedPaths: [], whitelist: [], allowedRoots: [t.path], minimumDepth: 2)
        let log = OperationLog(url: t.url.appending(path: "log.jsonl"))
        let report = CleanExecutor(safety: safety, log: log)
            .execute([RemovalItem(path: f, source: "r", bytes: 10, action: .delete)], dryRun: false, command: "test")
        #expect(report.freedBytes == 10)
        #expect(!t.exists("a/b/file.bin"))
        #expect(log.read().first?.result == "deleted")
    }

    @Test func safetyIsRecheckedAtExecution() throws {
        let t = try TempDir()
        let f = try t.file("keep/b/file.bin")
        let safety = PathSafety(protectedPaths: [t.path + "/keep"], whitelist: [], allowedRoots: [t.path], minimumDepth: 1)
        let report = CleanExecutor(safety: safety, log: OperationLog(url: t.url.appending(path: "l")))
            .execute([RemovalItem(path: f, source: "r", bytes: 1, action: .delete)], dryRun: false, command: "test")
        #expect(report.items.first?.result == .skipped)
        #expect(t.exists("keep/b/file.bin"))
    }
}

@Suite struct ArtifactScannerTests {
    @Test func findsArtifactsAndRespectsSafety() throws {
        let t = try TempDir()
        try t.file("web/package.json")
        try t.file("web/node_modules/left-pad/index.js", bytes: 40_000)
        try t.setAge("web/node_modules", days: 30)
        try t.setAge("web/node_modules/left-pad", days: 30)
        try t.file("rs/Cargo.toml")
        try t.file("rs/target/debug/app", bytes: 80_000)            // recent → not selected
        try t.file("nested/package.json")
        try t.file("nested/node_modules/.git/HEAD")                 // nested repo → skipped
        try t.file("svc/docker-compose.yml")
        try t.file("svc/volumes/py/requirements.txt")
        try t.file("svc/volumes/py/.venv/lib.py")                   // live container data → never found

        let detectors = try ArtifactDetector.loadBuiltIn()
        // The temp dir is under /private (a protected system path), so use a fixture-scoped policy.
        let safety = PathSafety(protectedPaths: ["/System"], whitelist: [], allowedRoots: [t.path], minimumDepth: 1)
        let result = ArtifactScanner(detectors: detectors).scan(roots: [t.path], safety: safety)
        let found = Dictionary(uniqueKeysWithValues: result.artifacts.map { ($0.path.replacingOccurrences(of: t.path + "/", with: ""), $0) })

        #expect(Set(found.keys) == ["web/node_modules", "rs/target"])
        #expect(found["web/node_modules"]?.selected == true)
        #expect(found["rs/target"]?.selected == false)
        #expect(found["rs/target"]?.recentlyUsed == true)
        #expect(result.skipped.map(\.path) == [t.path + "/nested/node_modules"])
    }
}

@Suite struct AutoCleanTests {
    @Test func dueLogic() {
        var c = AutoCleanConfig()
        #expect(!c.isDue(), "disabled is never due")
        c.enabled = true
        #expect(c.isDue(), "never run → due")
        let now = Date()
        c.lastRun = now.addingTimeInterval(-3600)
        c.frequency = .daily
        #expect(!c.isDue(now: now))
        c.lastRun = now.addingTimeInterval(-24 * 3600)
        #expect(c.isDue(now: now))
        c.frequency = .weekly
        #expect(!c.isDue(now: now))
    }

    @Test func roundTrip() throws {
        let t = try TempDir()
        var c = AutoCleanConfig()
        c.enabled = true
        c.lastRun = Date(timeIntervalSince1970: 1_800_000_000)
        let url = t.url.appending(path: "autoclean.json")
        try AutoClean.save(c, to: url)
        #expect(AutoClean.load(from: url) == c)
        #expect(AutoClean.load(from: t.url.appending(path: "missing.json")) == AutoCleanConfig())
    }

    @Test func onlyLowRiskRulesAreEligible() throws {
        let rules = try RuleSet.load(includeUserRules: false)
        let eligible = rules.filter { $0.risk <= AutoClean.maxRisk && $0.selectedByDefault }
        #expect(!eligible.contains { $0.id == "user.trash" }, "scheduled cleaning never empties the Trash")
        #expect(eligible.allSatisfy { $0.action == .trash })
    }
}

@Suite struct UninstallerTests {
    @Test func bundleIDHeuristic() {
        #expect(AppUninstaller.looksLikeBundleID("com.example.App"))
        #expect(AppUninstaller.looksLikeBundleID("org.mozilla.firefox"))
        #expect(!AppUninstaller.looksLikeBundleID("Google"))
        #expect(!AppUninstaller.looksLikeBundleID("com.example"))
        #expect(!AppUninstaller.looksLikeBundleID("my folder.v2.old"))
    }

    @Test func installedAppsAreListedAndAppleAppsProtected() {
        let apps = AppUninstaller.installedApps(measureSizes: false)
        #expect(!apps.isEmpty)
        for a in apps where a.bundleID.hasPrefix("com.apple.") { #expect(!a.canUninstall) }
    }

    @Test func safetyBoundaries() {
        let home = MacHelperPaths.home.path
        let s = AppUninstaller.leftoverSafety
        #expect(s.check(home + "/Library/Caches/com.example.App") == .allowed)
        #expect(s.check(home + "/Library/Preferences/com.example.App.plist") == .allowed)
        #expect(s.check(home + "/Library/Preferences") == .tooShallow)
        #expect(s.check(home + "/Library/Keychains/login.keychain-db") != .allowed)
        #expect(s.check(home + "/Documents/x/y") != .allowed)
        let b = AppUninstaller.bundleSafety
        #expect(b.check("/Applications/Example.app") == .allowed)
        #expect(b.check("/Applications") != .allowed)
        #expect(b.check("/System/Applications/Notes.app") != .allowed)
    }
}
