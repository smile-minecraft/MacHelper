import Darwin
import Foundation
import Security
import Testing
@testable import PrivilegedOps

/// Deep clean: the fixed deep allowlist, protected files, and the administrator authorization gate.
@Suite struct DeepCleanTests {
    /// A scratch folder whose files can be back-dated.
    private struct Scratch {
        let root: String

        init() throws {
            let url = FileManager.default.temporaryDirectory.appending(path: "deepclean-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            root = url.resolvingSymlinksInPath().path
        }

        @discardableResult
        func file(_ rel: String, ageDays: Double) throws -> String {
            let path = root + "/" + rel
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 4096).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: path)
            return path
        }

        func exists(_ rel: String) -> Bool {
            var st = stat()
            return lstat(root + "/" + rel, &st) == 0
        }

        func remove() {
            // Clear the immutable flag a test may have set, or the folder can't be removed.
            _ = try? FileManager.default.subpathsOfDirectory(atPath: root).forEach { chflags(root + "/" + $0, 0) }
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    private func deepTarget(_ root: String, skipping: @escaping @Sendable (String) -> Bool = { _ in false }) -> SystemCleanupTarget {
        SystemCleanupTarget(id: "test.deep", root: root, maxDepth: 3, minimumAge: 7 * 86_400, requiresAuthorization: true,
                            skipsTopLevel: skipping, matches: SystemCleanup.anyFile)
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var forms: [Data?] = []
        func record(_ f: Data?) { lock.withLock { forms.append(f) } }
        var count: Int { lock.withLock { forms.count } }
        var last: Data? { lock.withLock { forms.last ?? nil } }
    }

    // MARK: Allowlist

    @Test func deepAllowlistIsFixedAndNeedsAuthorization() {
        #expect(SystemCleanup.deepTargets.map(\.id) == [
            "deep.system-caches", "deep.root-caches", "deep.var-log", "deep.diagnostic-reports",
            "deep.library-logs", "deep.temp", "deep.tmp", "deep.simulator-caches",
        ])
        #expect(SystemCleanup.deepTargets.allSatisfy { $0.requiresAuthorization })
        #expect(SystemCleanup.targets.allSatisfy { !$0.requiresAuthorization }, "standard targets keep working without a password")
        #expect(SystemCleanup.deepTargets.allSatisfy { $0.minimumAge >= 86_400 }, "nothing touched in the last day is ever deleted")
        for t in SystemCleanup.deepTargets {
            #expect(t.root.hasPrefix("/") && !t.root.split(separator: "/").contains(".."), "\(t.id)")
            #expect(!t.root.hasPrefix("/System") && !t.root.hasPrefix("/private/var/db") && !t.root.hasPrefix("/Users"),
                    "\(t.id) stays out of the system volume, the system databases and home folders")
        }
        #expect(SystemCleanup.target("deep.var-log")?.root == "/private/var/log")
        #expect(SystemCleanup.target("system.logs")?.requiresAuthorization == false)
    }

    /// A deep scan previews only the deep targets, so each standard target must be covered by one.
    @Test func everyStandardTargetIsCoveredByADeepOne() {
        let samples = ["a.ips", "b.crash", "c.diag", "install.log", "x.log.0", "x.log.3.gz", "notes.txt"]
        for standard in SystemCleanup.targets {
            let cover = SystemCleanup.deepTargets.first { d in
                d.root == standard.root && d.maxDepth >= standard.maxDepth && d.minimumAge <= standard.minimumAge
                    && samples.allSatisfy { !standard.matches($0) || d.matches($0) }
            }
            #expect(cover != nil, "\(standard.id) has a deep counterpart")
        }
    }

    @Test func appleOwnedCachesAndCurrentLogsAreLeftAlone() {
        #expect(SystemCleanup.isAppleOwned("com.apple.iconservices.store"))
        #expect(SystemCleanup.isAppleOwned("ColorSync"))
        #expect(!SystemCleanup.isAppleOwned("com.microsoft.autoupdate.helper"))
        for n in ["system.log.0.gz", "wifi.log.3.bz2", "keybagd.log.0", "x.asl"] { #expect(SystemCleanup.isRotatedLogName(n), "\(n)") }
        for n in ["system.log", "install.log", "wifi.log", "fsck_apfs.log", "notes.txt"] { #expect(!SystemCleanup.isRotatedLogName(n), "\(n)") }
    }

    // MARK: Walking

    @Test func skippedTopLevelEntriesKeepEverythingInside() throws {
        let s = try Scratch(); defer { s.remove() }
        try s.file("com.apple.store/a/cache.db", ageDays: 30)
        try s.file("com.vendor.updater/cache.db", ageDays: 30)
        let r = SystemCleanup.process(deepTarget(s.root, skipping: SystemCleanup.isAppleOwned), dryRun: false)
        #expect(r.files.map(\.path) == [s.root + "/com.vendor.updater/cache.db"])
        #expect(s.exists("com.apple.store/a/cache.db"))
    }

    @Test func immutableFilesAndFoldersAreSkipped() throws {
        let s = try Scratch(); defer { s.remove() }
        let locked = try s.file("locked.bin", ageDays: 30)
        try s.file("frozen/inside.bin", ageDays: 30)
        try s.file("plain.bin", ageDays: 30)
        #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chflags(s.root + "/frozen", UInt32(UF_IMMUTABLE)) == 0)

        let r = SystemCleanup.process(deepTarget(s.root), dryRun: false)
        #expect(r.files.map(\.path) == [s.root + "/plain.bin"])
        #expect(r.failures.isEmpty, "protected items are skipped, not reported as failures")
        #expect(s.exists("locked.bin") && s.exists("frozen/inside.bin"))
    }

    // MARK: Authorization gate

    @Test func deletingDeepTargetsWithoutAuthorizationDeletesNothing() throws {
        let s = try Scratch(); defer { s.remove() }
        try s.file("old.bin", ageDays: 30)
        let target = deepTarget(s.root)
        // No authorization in the request, default authorizer.
        #expect(throws: SystemCleanupError.authorizationRequired) {
            try SystemCleanup.run(SystemCleanupRequest(targetIDs: ["test.deep"], dryRun: false), allowlist: [target])
        }
        // An authorization is present but the default authorizer refuses everything.
        #expect(throws: SystemCleanupError.authorizationRequired) {
            try SystemCleanup.run(SystemCleanupRequest(targetIDs: ["test.deep"], dryRun: false, authorization: Data([1])), allowlist: [target])
        }
        #expect(s.exists("old.bin"))
    }

    @Test func refusedOrCancelledAuthorizationDeletesNothingEvenInMixedRequests() throws {
        let s = try Scratch(); defer { s.remove() }
        let plain = try Scratch(); defer { plain.remove() }
        try s.file("old.bin", ageDays: 30)
        try plain.file("old.ips", ageDays: 60)
        let standard = SystemCleanupTarget(id: "test.standard", root: plain.root, maxDepth: 1, matches: SystemCleanup.isDiagnosticName)
        let request = SystemCleanupRequest(targetIDs: ["test.standard", "test.deep"], dryRun: false, authorization: Data([1, 2, 3]))
        for refusal in [SystemCleanupError.authorizationCancelled, .authorizationDenied(-60005)] {
            #expect(throws: refusal) {
                try SystemCleanup.run(request, allowlist: [standard, deepTarget(s.root)], authorize: { _ in throw refusal })
            }
        }
        #expect(s.exists("old.bin"))
        #expect(plain.exists("old.ips"), "the check runs before any target in the request is touched")
    }

    @Test func grantedAuthorizationDeletesAndReceivesTheForm() throws {
        let s = try Scratch(); defer { s.remove() }
        try s.file("old.bin", ageDays: 30)
        try s.file("fresh.bin", ageDays: 1)
        let calls = Calls()
        let form = Data([9, 8, 7])
        let r = try SystemCleanup.run(SystemCleanupRequest(targetIDs: ["test.deep"], dryRun: false, authorization: form),
                                      allowlist: [deepTarget(s.root)], authorize: { calls.record($0) })
        #expect(calls.count == 1 && calls.last == form)
        #expect(r.count == 1 && !s.exists("old.bin") && s.exists("fresh.bin"))
    }

    @Test func previewsAndStandardTargetsNeverAsk() throws {
        let s = try Scratch(); defer { s.remove() }
        try s.file("old.bin", ageDays: 30)
        try s.file("old.ips", ageDays: 60)
        let calls = Calls()
        let preview = try SystemCleanup.run(SystemCleanupRequest(targetIDs: ["test.deep"], dryRun: true),
                                            allowlist: [deepTarget(s.root)], authorize: { calls.record($0) })
        #expect(preview.count == 2 && s.exists("old.bin"))
        let standard = SystemCleanupTarget(id: "test.standard", root: s.root, maxDepth: 1, matches: SystemCleanup.isDiagnosticName)
        _ = try SystemCleanup.run(SystemCleanupRequest(targetIDs: ["test.standard"], dryRun: false),
                                  allowlist: [standard], authorize: { calls.record($0) })
        #expect(calls.count == 0)
        #expect(!s.exists("old.ips"))
    }

    // MARK: Authorization helpers

    @Test func malformedExternalFormIsRefusedBeforeAnyDialog() {
        #expect(throws: SystemCleanupError.authorizationRequired) { try DeepCleanAuthorization.authorize(nil) }
        #expect(throws: SystemCleanupError.authorizationRequired) { try DeepCleanAuthorization.authorize(Data([1, 2, 3])) }
    }

    @Test func rightDefinitionCannotBeSatisfiedByRootAlone() {
        let d = DeepCleanAuthorization.definition
        #expect(d["class"] as? String == "rule")
        #expect(d["rule"] as? String == "authenticate-admin-nonshared")
        #expect(DeepCleanAuthorization.isExpected(d))
        #expect(!DeepCleanAuthorization.isExpected(["class": "allow"]), "a planted 'allow' right is replaced")
        #expect(!DeepCleanAuthorization.isExpected(["class": "rule", "rule": "allow"]))
        #expect(!DeepCleanAuthorization.isExpected(["class": "rule", "rule": ["is-root"]]))
        #expect(DeepCleanAuthorization.isExpected(["class": "rule", "rule": ["authenticate-admin-nonshared"]]))
    }

    @Test func appSessionMakesAnExternalFormOfTheRightSize() throws {
        let session = try DeepCleanAuthorization.Session()
        #expect(session.externalForm.count == MemoryLayout<AuthorizationExternalForm>.size)
    }

    @Test func requestDecodesWithoutAuthorizationField() throws {
        let old = Data(#"{"targetIDs":["system.logs"],"dryRun":true}"#.utf8)
        let r = try JSONDecoder().decode(SystemCleanupRequest.self, from: old)
        #expect(r.authorization == nil && r.targetIDs == ["system.logs"])
        let withForm = SystemCleanupRequest(targetIDs: ["deep.tmp"], dryRun: false, authorization: Data([1, 2]))
        #expect(try JSONDecoder().decode(SystemCleanupRequest.self, from: JSONEncoder().encode(withForm)) == withForm)
    }
}
