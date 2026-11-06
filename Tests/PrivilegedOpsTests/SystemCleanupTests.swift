import Darwin
import Foundation
import Testing
@testable import PrivilegedOps

/// Temporary tree whose files can be back-dated.
private struct Tree {
    let root: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "syscleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Resolve /var → /private/var so paths compare exactly.
        root = url.resolvingSymlinksInPath().path
    }

    @discardableResult
    func file(_ rel: String, bytes: Int = 4096, ageDays: Double) throws -> String {
        let path = root + "/" + rel
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: path))
        let date = Date().addingTimeInterval(-ageDays * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        return path
    }

    func exists(_ rel: String) -> Bool {
        var st = stat()
        return lstat(root + "/" + rel, &st) == 0
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

@Suite struct SystemCleanupTests {
    private func reportsTarget(_ root: String) -> SystemCleanupTarget {
        SystemCleanupTarget(id: "test.reports", root: root, maxDepth: 2, matches: SystemCleanup.isDiagnosticName)
    }

    @Test func allowlistIsFixedAndNarrow() {
        #expect(SystemCleanup.targets.map(\.id) == ["system.diagnostic-reports", "system.logs"])
        #expect(SystemCleanup.target("system.diagnostic-reports")?.root == "/Library/Logs/DiagnosticReports")
        #expect(SystemCleanup.target("system.logs")?.root == "/Library/Logs")
        #expect(SystemCleanup.target("system.logs")?.maxDepth == 1, "app subfolders of /Library/Logs are never entered")
        #expect(SystemCleanup.targets.allSatisfy { $0.minimumAge == 30 * 86_400 })
        #expect(SystemCleanup.targets.allSatisfy { !$0.root.hasPrefix("/Library/Caches") && !$0.root.hasPrefix("/System") })
    }

    @Test func unknownTargetRejectsWholeRequest() throws {
        #expect(throws: SystemCleanupError.unknownTarget("/etc")) {
            try SystemCleanup.run(SystemCleanupRequest(targetIDs: ["system.logs", "/etc"], dryRun: true))
        }
        #expect(throws: SystemCleanupError.unknownTarget("../system.logs")) {
            try SystemCleanup.resolve(["../system.logs"])
        }
        #expect(try SystemCleanup.resolve(["system.logs", "system.logs"]).count == 1, "duplicates collapse")
    }

    @Test func nameFilters() {
        for n in ["a.ips", "b_2026.crash", "c.cpu_resource.diag", "d.spin", "e.hang", "f.panic", "g.shutdownStall"] {
            #expect(SystemCleanup.isDiagnosticName(n), "\(n)")
        }
        for n in ["notes.txt", "x.plist", "x.log", "ips", ".DS_Store"] { #expect(!SystemCleanup.isDiagnosticName(n), "\(n)") }
        for n in ["install.log", "a.log.0", "a.log.3.gz", "b.log.bz2"] { #expect(SystemCleanup.isLogName(n), "\(n)") }
        for n in ["a.logx", "log", "a.log.gz.sh", "catalog.db", "a.log.sh"] { #expect(!SystemCleanup.isLogName(n), "\(n)") }
    }

    @Test func dryRunListsOnlyOldMatchingFilesAndDeletesNothing() throws {
        let t = try Tree(); defer { t.remove() }
        try t.file("old.ips", bytes: 8192, ageDays: 45)
        try t.file("Retired/older.diag", ageDays: 90)
        try t.file("recent.ips", ageDays: 3)
        try t.file("old-notes.txt", ageDays: 400)
        try t.file("Retired/deeper/too-deep.ips", ageDays: 90)

        let r = SystemCleanup.process(reportsTarget(t.root), dryRun: true)
        #expect(r.unavailable == nil)
        #expect(Set(r.files.map(\.path)) == [t.root + "/old.ips", t.root + "/Retired/older.diag"])
        #expect(r.count == 2)
        #expect(r.bytes >= 8192 + 4096)
        #expect(r.failures.isEmpty)
        for rel in ["old.ips", "Retired/older.diag", "recent.ips", "old-notes.txt", "Retired/deeper/too-deep.ips"] {
            #expect(t.exists(rel), "dry run keeps \(rel)")
        }
    }

    @Test func runDeletesOldMatchingFilesAndKeepsTheRest() throws {
        let t = try Tree(); defer { t.remove() }
        try t.file("old.ips", ageDays: 45)
        try t.file("Retired/older.diag", ageDays: 90)
        try t.file("recent.ips", ageDays: 3)
        try t.file("old-notes.txt", ageDays: 400)

        let r = SystemCleanup.process(reportsTarget(t.root), dryRun: false)
        #expect(r.count == 2)
        #expect(!t.exists("old.ips"))
        #expect(!t.exists("Retired/older.diag"))
        #expect(t.exists("Retired"), "folders are never removed")
        #expect(t.exists("recent.ips"))
        #expect(t.exists("old-notes.txt"))
    }

    @Test func depthOneStaysInTheTopFolder() throws {
        let t = try Tree(); defer { t.remove() }
        try t.file("install.log", ageDays: 60)
        try t.file("SomeApp/app.log", ageDays: 60)
        let target = SystemCleanupTarget(id: "test.logs", root: t.root, maxDepth: 1, matches: SystemCleanup.isLogName)
        let r = SystemCleanup.process(target, dryRun: false)
        #expect(r.files.map(\.path) == [t.root + "/install.log"])
        #expect(t.exists("SomeApp/app.log"))
    }

    @Test func symbolicLinksAreNeverFollowedOrDeleted() throws {
        let t = try Tree(); defer { t.remove() }
        let outside = try Tree(); defer { outside.remove() }
        try outside.file("victim.ips", ageDays: 90)
        try FileManager.default.createDirectory(atPath: t.root + "/reports", withIntermediateDirectories: true)
        // A linked subfolder and a linked file pointing outside the target.
        try FileManager.default.createSymbolicLink(atPath: t.root + "/reports/Retired", withDestinationPath: outside.root)
        try FileManager.default.createSymbolicLink(atPath: t.root + "/reports/link.ips", withDestinationPath: outside.root + "/victim.ips")

        let r = SystemCleanup.process(reportsTarget(t.root + "/reports"), dryRun: false)
        #expect(r.count == 0)
        #expect(outside.exists("victim.ips"))
        #expect(t.exists("reports/link.ips"), "the link itself is left alone too")

        // A root that is itself a symbolic link is refused outright.
        let linkedRoot = SystemCleanup.process(reportsTarget(t.root + "/reports/Retired"), dryRun: false)
        #expect(linkedRoot.unavailable != nil)
        #expect(outside.exists("victim.ips"))
    }

    @Test func hardLinkedFilesAreSkipped() throws {
        let t = try Tree(); defer { t.remove() }
        let original = try t.file("keep/original.ips", ageDays: 90)
        try FileManager.default.createDirectory(atPath: t.root + "/reports", withIntermediateDirectories: true)
        #expect(link(original, t.root + "/reports/alias.ips") == 0)
        let r = SystemCleanup.process(reportsTarget(t.root + "/reports"), dryRun: false)
        #expect(r.count == 0)
        #expect(t.exists("reports/alias.ips"))
    }

    @Test func missingOrRelativeRootIsUnavailable() {
        let missing = SystemCleanup.process(reportsTarget("/nonexistent-\(UUID().uuidString)"), dryRun: true)
        #expect(missing.unavailable != nil && missing.count == 0)
        let relative = SystemCleanup.process(reportsTarget("Library/Logs"), dryRun: true)
        #expect(relative.unavailable == "invalid root")
        let dotted = SystemCleanup.process(reportsTarget("/Library/Logs/../../etc"), dryRun: true)
        #expect(dotted.unavailable == "invalid root")
    }

    @Test func runUsesInjectedAllowlistAndClock() throws {
        let t = try Tree(); defer { t.remove() }
        try t.file("a.ips", ageDays: 10)
        let target = reportsTarget(t.root)
        let request = SystemCleanupRequest(targetIDs: ["test.reports"], dryRun: true)
        #expect(try SystemCleanup.run(request, allowlist: [target]).count == 0, "10 days old is too recent")
        let later = Date().addingTimeInterval(25 * 86_400)
        #expect(try SystemCleanup.run(request, allowlist: [target], now: later).count == 1)
    }

    @Test func requestAndResultRoundTrip() throws {
        let req = SystemCleanupRequest(targetIDs: ["system.logs"], dryRun: false)
        #expect(try JSONDecoder().decode(SystemCleanupRequest.self, from: JSONEncoder().encode(req)) == req)
        let res = SystemCleanupResult(targets: [.init(id: "system.logs", dryRun: false, files: [.init(path: "/Library/Logs/a.log", bytes: 4096)],
                                                      count: 3, bytes: 12_288, failures: [], unavailable: nil)])
        let back = try JSONDecoder().decode(SystemCleanupResult.self, from: JSONEncoder().encode(res))
        #expect(back == res)
        #expect(back.count == 3 && back.bytes == 12_288)
    }
}
