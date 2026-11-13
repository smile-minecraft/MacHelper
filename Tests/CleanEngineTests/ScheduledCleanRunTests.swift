import Darwin
import Foundation
import Testing
@testable import CleanEngine

/// The scheduled cleaner entry point always scans the real home folder and writes the shared
/// operations log, so it cannot be called from a test. These tests are narrower: the first one
/// combines `CleanScanner` and `CleanExecutor` on a temporary tree with a trash-action rule and
/// checks that combination's behavior (what gets named, what gets moved, what stays). The second
/// one checks the default `AutoCleanConfig` values and three representative paths against
/// `PathSafety.forCleaning`.
///
/// Neither test calls `AutoClean.run`, so the entry point's own risk/`selectedByDefault` filtering
/// is not directly verified. `AutoCleanTests.onlyLowRiskRulesAreEligible` applies the same
/// predicate to the loaded rules itself and checks that the result excludes emptying the Trash and
/// only uses trash actions; it does not prove the entry point filters that way, and it does not
/// show every low-risk rule is selected by default.
///
/// The first test injects a backend that moves items into a directory inside its temporary tree,
/// so it exercises the real executor without touching the user's Trash or operations log.
@Suite struct ScheduledCleanRunTests {
    private func probeRule(_ id: String, _ paths: [String], risk: String = "low", selected: Bool = true) throws -> CleanRule {
        let json: [String: Any] = ["id": id, "title": id, "category": "test", "risk": risk, "paths": paths,
                                   "exclude": [], "minAgeDays": 0, "action": "trash", "selectedByDefault": selected]
        return try JSONDecoder().decode(CleanRule.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Mirrors `PathSafety.forCleaning()`'s shape as closely as a temporary tree allows: system
    /// paths stay verbatim (minus /private, /var and /tmp, which contain the temp tree itself),
    /// and home-protected paths get the home prefix. An earlier draft prefixed system paths with
    /// the home too, which made those checks meaningless.
    private func cleaningSafety(roots: [String]) -> PathSafety {
        let home = MacHelperPaths.home.path
        let system = PathSafety.systemPaths.filter { !["/private", "/var", "/tmp"].contains($0) }
        let protected = system
            + (PathSafety.protectedInHome + PathSafety.personalFolders).map { home + "/" + $0 }
        return PathSafety(protectedPaths: protected, whitelist: [], allowedRoots: roots, minimumDepth: 2)
    }

    @Test func movesOnlyTheRulesNamedItemsAndKeepsEverythingElse() throws {
        let t = try TempDir()
        try t.file("cache-target/old-cache.bin", bytes: 40_000)
        try t.file("cache-target/second-cache.bin", bytes: 20_000)
        try t.file("keep-here/notes.txt")
        try t.file("other-folder/unrelated.bin")

        let lowSelected = try probeRule("probe.low", [t.path + "/cache-target/*"])
        let logURL = t.url.appending(path: "operations.jsonl")
        let log = OperationLog(url: logURL)
        let safety = cleaningSafety(roots: [t.path])
        let plan = CleanScanner(rules: [lowSelected], safety: safety).scan()
        #expect(plan.selectedCandidates.count == 2, "both cached files matched")
        #expect(plan.selectedCandidates.allSatisfy { $0.path.hasPrefix(t.path + "/cache-target/") })
        let removed = plan.removalItems

        // The executor's Trash is this test's own directory, so nothing can reach the user's Trash.
        let testTrash = TestTrashBackend(trashDirectory: t.url.appending(path: "test-trash"))
        let executor = CleanExecutor.injected(safety: safety, log: log, removal: testTrash.backend)
        let report = executor.execute(removed, dryRun: false, command: "isolated-combination-check")

        try #require(report.items.count == 2)
        // Every rule here declares trash action, so the outcomes are trash entries; the executor
        // follows whatever action the rule declares, and permanent deletion is a separate switch.
        #expect(report.items.allSatisfy { $0.result == ItemOutcome.Result.trashed })
        #expect(report.trashedBytes == plan.selectedSize, "trash bytes match what the scan names")
        #expect(report.failures.isEmpty)
        #expect(!t.exists("cache-target/old-cache.bin"), "matched items are moved away")
        #expect(!t.exists("cache-target/second-cache.bin"))
        #expect(t.exists("keep-here/notes.txt"), "unrelated items stay")
        #expect(t.exists("other-folder/unrelated.bin"))

        // Both files really moved into the test's Trash directory, and nothing was deleted.
        #expect(testTrash.trashedPaths.sorted() == removed.map(\.path).sorted())
        #expect(testTrash.deletedPaths.isEmpty)
        #expect(testTrash.trashContents() == ["old-cache.bin", "second-cache.bin"])

        // The operations record went to the per-test log, not the shared one.
        let recorded = log.read()
        try #require(recorded.count == 2)
        let recordedByPath = Dictionary(uniqueKeysWithValues: recorded.map { ($0.path, $0) })
        for item in removed {
            let entry = try #require(recordedByPath[item.path])
            #expect(entry.command == "isolated-combination-check")
            #expect(entry.result == "trashed")
            #expect(entry.bytes == item.bytes)
            #expect(entry.source == item.source)
        }
    }

    @Test func offConfigAndSystemPathsStayUntouched() throws {
        // The default configuration is disabled and never due; this reads the config value directly.
        let c = AutoCleanConfig()   // enabled == false by default
        #expect(!c.isDue())
        #expect(c.nextRun == nil)

        // Three representative boundaries checked directly against `PathSafety.forCleaning`: a
        // path outside the home folder is not allowed, and protected home paths are refused. No
        // scan or execution runs here.
        let safety = PathSafety.forCleaning(whitelist: [])
        let home = MacHelperPaths.home.path
        #expect(safety.check("/Applications/Something.app") != .allowed)
        #expect(safety.check(home + "/Documents/live.txt") == .protected(home + "/Documents"))
        #expect(safety.check(MacHelperPaths.supportDirectory.path) == .protected(home + "/Library/Application Support/MacHelper"))
    }
}
