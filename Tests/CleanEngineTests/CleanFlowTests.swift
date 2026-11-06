import Darwin
import Foundation
import Testing
@testable import CleanEngine

@Suite struct AIToolRuleTests {
    static let ids = ["ai.omlx-logs", "ai.omlx-cache", "ai.ollama-logs", "ai.lmstudio-logs", "ai.lmstudio-cache"]

    @Test func rulesLoadTranslatedAndInHome() throws {
        let rules = try RuleSet.load(includeUserRules: false)
        let safety = PathSafety.forCleaning(whitelist: [])
        for id in Self.ids {
            let r = try #require(rules.first { $0.id == id }, "\(id) missing")
            #expect(r.category == "ai")
            #expect(r.title != "rule.\(id).title", "\(id) has no translation entry")
            for p in r.paths {
                let sample = expandTilde(p).replacingOccurrences(of: "*", with: "x").replacingOccurrences(of: "[0-9]", with: "1")
                #expect(safety.check(sample) == .allowed, "\(id): \(p)")
            }
        }
    }

    @Test func modelsAreNeverMatched() throws {
        let rules = try RuleSet.load(includeUserRules: false).filter { Self.ids.contains($0.id) }
        for r in rules { for p in r.paths { #expect(!p.lowercased().contains("model"), "\(r.id): \(p)") } }
        // The prompt cache is regenerable but slow to rebuild: never preselected, skipped while the server runs.
        let cache = try #require(rules.first { $0.id == "ai.omlx-cache" })
        #expect(!cache.selectedByDefault && cache.skipIfProcessRunning == ["omlx-server"])
    }

    @Test func ollamaKeepsTheCurrentLog() throws {
        let t = try TempDir()
        try t.file("logs/server.log")
        try t.file("logs/server-1.log")
        try t.file("logs/server-12.log")
        let found = expandGlob(t.path + "/logs/*-[0-9]*.log").map { ($0 as NSString).lastPathComponent }.sorted()
        #expect(found == ["server-1.log", "server-12.log"])
    }
}

@Suite struct ScanStopTests {
    private func rule(_ id: String, _ path: String) throws -> CleanRule {
        CleanRule(id: id, title: id, description: "", category: "test", risk: .low, paths: [path])
    }

    @Test func stopKeepsFinishedRules() throws {
        let t = try TempDir()
        try t.file("a/one/x.bin")
        try t.file("b/two/y.bin")
        let safety = PathSafety(protectedPaths: [], whitelist: [], allowedRoots: [t.path], minimumDepth: 2)
        let scanner = CleanScanner(rules: [try rule("a", t.path + "/a/*"), try rule("b", t.path + "/b/*")], safety: safety)
        var seen: [Int] = []
        let plan = scanner.scan(progress: { done, total in seen.append(done); #expect(total == 2) },
                                shouldStop: { seen.count >= 1 })
        #expect(plan.results.map(\.rule.id) == ["a"])
        #expect(plan.results[0].candidates.count == 1)
        #expect(scanner.scan().results.count == 2)
    }
}

@Suite struct CleanExclusionsTests {
    @Test func addRemoveKeepsComments() throws {
        let t = try TempDir()
        let file = t.url.appending(path: "sub/clean-whitelist.txt")
        let ex = CleanExclusions(file: file)
        #expect(ex.entries().isEmpty)
        try ex.add("~/Library/Caches/com.example.keep")
        try ex.add("~/Library/Caches/com.example.keep")   // no duplicate
        try ex.add("  ")                                   // ignored
        try ex.add("# not an entry")                       // comments can't be added as entries
        #expect(ex.entries() == ["~/Library/Caches/com.example.keep"])
        let text = try String(contentsOf: file, encoding: .utf8)
        try ("# mine\n" + text).write(to: file, atomically: true, encoding: .utf8)
        try ex.add("/Volumes/Data/*.tmp")
        try ex.remove("~/Library/Caches/com.example.keep")
        #expect(ex.entries() == ["/Volumes/Data/*.tmp"])
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("# mine\n"))
    }

    @Test func entriesUseTildeForHome() {
        let home = MacHelperPaths.home.path
        #expect(CleanExclusions.entry(for: home + "/Library/Caches/x") == "~/Library/Caches/x")
        #expect(CleanExclusions.entry(for: home + "x/y") == home + "x/y")
        #expect(CleanExclusions.entry(for: "/Volumes/A/b") == "/Volumes/A/b")
    }

    @Test func excludedPathIsSkippedByScanAndExecutor() throws {
        let t = try TempDir()
        let keep = try t.file("c/keep/a.bin")
        try t.file("c/go/b.bin")
        let safety = PathSafety(protectedPaths: [], whitelist: [t.path + "/c/keep"], allowedRoots: [t.path], minimumDepth: 2)
        let rule = CleanRule(id: "r", title: "r", description: "", category: "test", risk: .low, paths: [t.path + "/c/*"])
        let plan = CleanScanner(rules: [rule], safety: safety).scan()
        #expect(plan.results[0].candidates.map(\.path) == [t.path + "/c/go"])
        #expect(safety.check(keep) == .whitelisted(t.path + "/c/keep"))
    }
}

@Suite struct VolumeTrashTests {
    @Test func findsOnlyThisUsersTrashFolder() throws {
        let t = try TempDir()
        let vol = t.url.appending(path: "Drive")
        try t.file("Drive/.Trashes/\(getuid())/old.mov", bytes: 40_000)
        try t.file("Drive/.Trashes/\(getuid() + 1)/theirs.mov")
        try t.file("Drive/Movies/keep.mov")
        try t.file("NoTrash/file")
        let folders = VolumeTrash.trashFolders(volumes: [vol, t.url.appending(path: "NoTrash")])
        #expect(folders == [t.path + "/Drive/.Trashes/\(getuid())"])

        let safety = VolumeTrash.safety(trashFolders: folders, whitelist: [], protectedPaths: [])
        #expect(safety.check(folders[0] + "/old.mov") == .allowed)
        #expect(safety.check(folders[0]) != .allowed, "the Trash folder itself is never removed")
        #expect(safety.check(t.path + "/Drive/Movies/keep.mov") == .outsideAllowedRoots)
        #expect(safety.check(t.path + "/Drive/.Trashes/\(getuid() + 1)/theirs.mov") == .outsideAllowedRoots)

        let result = VolumeTrash.scan(trashFolders: folders, safety: safety)
        #expect(result.candidates.map { ($0.path as NSString).lastPathComponent } == ["old.mov"])
        #expect(result.candidates[0].note == "Drive" && !result.candidates[0].selected)
        #expect(result.rule.action == .delete && !result.rule.selectedByDefault)
    }

    @Test func realVolumesStayProtectedOutsideTheirTrash() {
        let safety = VolumeTrash.safety(trashFolders: ["/Volumes/X/.Trashes/501"], whitelist: [])
        #expect(safety.check("/Volumes/X/.Trashes/501/a") == .allowed)
        #expect(safety.check("/Volumes/X/Documents/a") == .outsideAllowedRoots)
        #expect(safety.check("/System/Library/x") != .allowed)
    }
}

@Suite struct ItemFilterTests {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    func item(_ path: String, _ size: UInt64, daysOld: Double?) -> CleanCandidate {
        CleanCandidate(ruleID: "r", path: path, size: size, modified: daysOld.map { now.addingTimeInterval(-$0 * 86_400) },
                       isDirectory: false, selected: true, note: nil)
    }

    @Test func filtersBySizeAgeAndText() {
        let big = item("/u/Library/Caches/com.Big.App", 2_000_000_000, daysOld: 100)
        let small = item("/u/Library/Caches/small", 5_000, daysOld: 2)
        let unknownAge = item("/u/x/unknown", 50_000_000, daysOld: nil)
        #expect(!ItemFilter().isActive)
        #expect(ItemFilter(minBytes: 10_000_000).matches(unknownAge, ruleTitle: "", now: now))
        #expect(!ItemFilter(minBytes: 10_000_000).matches(small, ruleTitle: "", now: now))
        #expect(ItemFilter(minAgeDays: 30).matches(big, ruleTitle: "", now: now))
        #expect(!ItemFilter(minAgeDays: 30).matches(unknownAge, ruleTitle: "", now: now), "unknown age never counts as old")
        #expect(ItemFilter(text: "big.app").matches(big, ruleTitle: "", now: now), "case-insensitive path match")
        #expect(ItemFilter(text: "Browsers").matches(small, ruleTitle: "Browsers", now: now), "rule title match")
        #expect(!ItemFilter(text: "nope").matches(small, ruleTitle: "Caches", now: now))
        #expect(ItemFilter(text: "  ").isActive == false)
    }

    @Test func sortsBySizeNameAndAge() {
        let a = item("/x/b-item", 10, daysOld: 1), b = item("/x/a-item", 30, daysOld: 50), c = item("/x/c-item", 20, daysOld: nil)
        #expect(ItemFilter(sort: .size).sorted([a, b, c]).map(\.size) == [30, 20, 10])
        #expect(ItemFilter(sort: .name).sorted([a, b, c]).map(\.path) == ["/x/a-item", "/x/b-item", "/x/c-item"])
        #expect(ItemFilter(sort: .oldest).sorted([a, b, c]).map(\.path) == ["/x/a-item", "/x/b-item", "/x/c-item"])
    }
}

@Suite struct HomebrewUpdatesTests {
    @Test func tokensAreValidated() {
        for ok in ["obs", "visual-studio-code", "font-sf-pro@2", "handlecusion/tokcat/tokcat", "c++"] { #expect(HomebrewUpdates.isValidToken(ok), "\(ok)") }
        for bad in ["", "-rf", "--greedy", "OBS", "a b", "a;rm", "$(x)", "a\nb"] { #expect(!HomebrewUpdates.isValidToken(bad), "\(bad)") }
    }

    @Test func parsesOutdatedAndInfo() throws {
        let outdated = #"{"formulae":[],"casks":[{"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false,"pinned_version":null},{"name":"gstreamer-runtime","installed_versions":["1.28.3"],"current_version":"1.28.6","pinned":true}]}"#
        let rows = try #require(HomebrewUpdates.parseOutdated(Data(outdated.utf8)))
        #expect(rows == [.init(token: "obs", installed: "33.0.0", current: "33.0.1", pinned: false),
                         .init(token: "gstreamer-runtime", installed: "1.28.3", current: "1.28.6", pinned: true)])
        #expect(HomebrewUpdates.parseOutdated(Data("Warning: x".utf8)) == nil)

        let info = #"{"casks":[{"token":"obs","name":["OBS"],"auto_updates":true,"artifacts":[{"uninstall":[{"quit":"com.obsproject.obs-studio","delete":"/Library/CoreMediaIO/Plug-Ins/DAL/obs-mac-virtualcam.plugin"}]},{"app":["OBS.app"]},{"zap":[{"trash":["~/Library/Application Support/obs-studio"]}]}]},{"token":"gstreamer-runtime","name":["GStreamer runtime package"],"auto_updates":null,"artifacts":[{"uninstall":[{"pkgutil":["org.freedesktop.gstreamer"]}]},{"pkg":["gstreamer.pkg"]}]}]}"#
        let d = HomebrewUpdates.parseInfo(Data(info.utf8))
        #expect(d["obs"] == .init(name: "OBS", autoUpdates: true, apps: ["OBS.app"], needsAdmin: false))
        #expect(d["gstreamer-runtime"]?.needsAdmin == true && d["gstreamer-runtime"]?.apps == [])
    }

    @Test func terminalCommandAndTail() {
        let c = OutdatedCask(token: "obs", name: "OBS", installedVersion: "1", currentVersion: "2", pinned: false,
                             autoUpdates: false, appNames: [], needsAdmin: true)
        #expect(c.terminalCommand == "brew upgrade --cask obs")
        #expect(HomebrewUpdates.tail((1...30).map(String.init).joined(separator: "\n"), lines: 3) == "28\n29\n30")
    }
}

@Suite struct AgentSkillTests {
    @Test func installUpdateAndRemoveOnlyOwnSkill() throws {
        let t = try TempDir()
        try FileManager.default.createDirectory(at: t.url.appending(path: ".claude"), withIntermediateDirectories: true)
        let targets = AgentSkill.targets(home: t.url)
        let claude = try #require(targets.first { $0.id == "claude" })
        let codex = try #require(targets.first { $0.id == "codex" })
        #expect(claude.detected && !codex.detected)
        #expect(AgentSkill.state(claude) == .notInstalled)

        try AgentSkill.install(claude, command: "machelper", fallback: "/Applications/MacHelper.app/Contents/MacOS/machelper-cli")
        #expect(AgentSkill.state(claude) == .installed)
        let text = try String(contentsOf: claude.file, encoding: .utf8)
        #expect(text.hasPrefix("---\nname: machelper\ndescription: "))
        #expect(text.contains("`machelper clean --json`") && text.contains("machelper-cli` instead"))

        // An older version is refreshed; a SKILL.md someone else wrote is never touched.
        try text.replacingOccurrences(of: "skill version \(AgentSkill.version)", with: "skill version 0").write(to: claude.file, atomically: true, encoding: .utf8)
        #expect(AgentSkill.state(claude) == .outdated)
        #expect(AgentSkill.refreshInstalled(command: "machelper", home: t.url).map(\.id) == ["claude"])
        #expect(AgentSkill.state(claude) == .installed)

        try FileManager.default.createDirectory(at: codex.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: machelper\n---\nmine".write(to: codex.file, atomically: true, encoding: .utf8)
        #expect(AgentSkill.state(codex) == .foreign)
        #expect(throws: (any Error).self) { try AgentSkill.install(codex, command: "machelper") }
        try AgentSkill.uninstall(codex)
        #expect(try String(contentsOf: codex.file, encoding: .utf8).hasSuffix("mine"))

        try AgentSkill.uninstall(claude)
        #expect(!FileManager.default.fileExists(atPath: claude.file.deletingLastPathComponent().path))
    }

    @Test func everyCommandInTheGuideExists() {
        // Guards against the skill drifting from the CLI: each `machelper <command>` it mentions is real.
        let known: Set<String> = ["clean", "purge", "optimize", "uninstall", "autoclean", "startup", "analyze", "insights", "duplicates",
                                  "guide", "skill", "status", "docker", "login-items", "doctor", "stats", "rules", "ignore", "updates",
                                  "security", "history", "monitor"]
        let md = AgentSkill.markdown(command: "machelper")
        let used = md.components(separatedBy: "`machelper ").dropFirst().compactMap { $0.split(separator: " ").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "`")) } }
        #expect(!used.isEmpty)
        for c in used where c != "<command>" { #expect(known.contains(c), "\(c)") }
    }
}
