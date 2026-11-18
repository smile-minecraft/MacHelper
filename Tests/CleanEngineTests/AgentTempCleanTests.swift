import Darwin
import Foundation
import Testing
@testable import CleanEngine

/// Tests for the opt-in sweep of expired agent test temp directories. Every filesystem test
/// builds its own isolated tree inside $TMPDIR and injects a directory-backed removal backend, so
/// the user's Trash, operations log and real temp folder are never touched.
@Suite struct AgentTempCleanTests {
    private let fileManager = FileManager.default

    /// Creates a UUID-named root in the real temp folder (candidates live directly inside it) and
    /// hands out isolated plumbing for one test. Callers clean up with `removeIfNeeded`.
    private func makeSandbox() throws -> (root: URL, trash: URL, log: URL) {
        let base = fileManager.temporaryDirectory.appending(path: "agent-temp-clean-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")
        let trash = base.appending(path: "trash")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        return (root, trash, base.appending(path: "operations.jsonl"))
    }

    private func options(root: URL, trash: URL, log: URL,
                         openFiles: @escaping @Sendable (UInt32) -> [String]? = { _ in [] },
                         retention: TimeInterval = AgentTempClean.defaultRetention,
                         now: Date = Date()) -> AgentTempClean.Options {
        let backend = TestTrashBackend(trashDirectory: trash)
        let safety = PathSafety(protectedPaths: [], whitelist: [],
                                allowedRoots: [root.path], minimumDepth: 1)
        var options = AgentTempClean.Options()
        options.tempRoot = root
        options.retention = retention
        options.now = now
        options.command = "autoclean"
        options.openFiles = openFiles
        options.log = OperationLog(url: log)
        options.executor = CleanExecutor.injected(safety: safety, log: OperationLog(url: log),
                                                  removal: backend.backend)
        return options
    }

    /// Creates a candidate tree: knownName/childFile.txt with the given mtime (nil = now).
    @discardableResult
    private func makeCandidate(_ root: URL, _ name: String, childMtime: Date? = nil,
                               contents: [String: String] = ["child.txt": "rebuildable"]) throws -> URL {
        let candidate = root.appending(path: name)
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        for (file, body) in contents {
            let url = candidate.appending(path: file)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            if let childMtime { try fileManager.setAttributes([.modificationDate: childMtime], ofItemAtPath: url.path) }
        }
        return candidate
    }

    private func age(_ url: URL, to date: Date) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: Configuration compatibility

    @Test func olderConfigFilesStillDecodeAgentTempCleanAsOff() throws {
        let old = #"{"enabled":true,"frequency":"daily","permanent":false,"trashInstead":true,"maintenanceTasks":[],"lastTrashedBytes":10,"lastFreedBytes":20,"lastItemCount":3}"#
        let dir = fileManager.temporaryDirectory.appending(path: "agent-temp-clean-\(UUID().uuidString)")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }
        let url = dir.appending(path: "autoclean.json")
        try Data(old.utf8).write(to: url)
        let config = AutoClean.load(from: url)
        #expect(config.agentTempClean == nil, "pre-update files decode with the sweep off")
        #expect(config.frequency == .daily)
        #expect(config.enabled)
        #expect(config.trashInstead == true)
        #expect(config.maintenanceTasks == [])
        #expect(config.lastItemCount == 3)
    }

    @Test func agentTempCleanRoundTrips() throws {
        var config = AutoCleanConfig()
        #expect(config.agentTempClean == nil)
        config.agentTempClean = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""agentTempClean":true"#) || text.contains(#""agentTempClean" : true"#))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AutoCleanConfig.self, from: data)
        #expect(decoded.agentTempClean == true)
        config.agentTempClean = nil
        let off = try encoder.encode(config)
        #expect(!String(decoding: off, as: UTF8.self).contains("agentTempClean"),
                "off serializes without the key so old files stay byte-compatible")
    }

    @Test func newFrequenciesHaveTheExpectedPeriods() {
        #expect(AutoCleanConfig.Frequency.every30Minutes.interval == 29 * 60)
        #expect(AutoCleanConfig.Frequency.hourly.interval == 59 * 60)
        #expect(AutoCleanConfig.Frequency.every3Hours.interval == 3 * 3600 - 180)
        #expect(AutoCleanConfig.Frequency.daily.interval == 23 * 3600)
        #expect(AutoCleanConfig.Frequency.weekly.interval == 7 * 86_400 - 3600)
    }

    @Test func dueBoundariesForEveryFrequency() {
        let now = Date()
        for frequency in AutoCleanConfig.Frequency.allCases {
            var config = AutoCleanConfig()
            config.enabled = true
            config.frequency = frequency
            // Not yet due one second before the boundary; due exactly at it.
            config.lastRun = now.addingTimeInterval(-frequency.interval + 1)
            #expect(config.isDue(now: now) == false, "\(frequency) not due right before the boundary")
            config.lastRun = now.addingTimeInterval(-frequency.interval)
            #expect(config.isDue(now: now) == true, "\(frequency) due exactly at the boundary")
            config.lastRun = nil
            #expect(config.isDue(now: now) == true, "\(frequency) due when never run")
        }
    }

    @Test func unknownFrequencyFallsBackToDefaults() throws {
        let dir = fileManager.temporaryDirectory.appending(path: "agent-temp-clean-\(UUID().uuidString)")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }
        let url = dir.appending(path: "autoclean.json")
        try Data(#"{"enabled":true,"frequency":"every-2-hours"}"#.utf8).write(to: url)
        let config = AutoClean.load(from: url)
        #expect(config.frequency == .weekly && config.enabled == false,
                "an undecodable config falls back to the safe default (off)")
    }

    // MARK: Name matching

    @Test func knownNamesMatchExactly() {
        for prefix in AgentTempClean.knownPrefixes {
            #expect(AgentTempClean.matchesKnownName(prefix + "A1b2C3"))
            #expect(!AgentTempClean.matchesKnownName(prefix + "A1b2C"), "five-char suffix rejected")
            #expect(!AgentTempClean.matchesKnownName(prefix + "A1b2C34"), "seven-char suffix rejected")
            #expect(!AgentTempClean.matchesKnownName(prefix + "A1b-C3"), "dash rejected")
            #expect(!AgentTempClean.matchesKnownName(prefix + "Aéb2C3"), "non-ASCII rejected")
            #expect(!AgentTempClean.matchesKnownName(prefix), "missing suffix rejected")
            #expect(!AgentTempClean.matchesKnownName(prefix + "A1b2C3\n"), "trailing newline rejected")
            #expect(!AgentTempClean.matchesKnownName(prefix + "A1b2C3\r\n"), "trailing CRLF rejected")
        }
        #expect(!AgentTempClean.matchesKnownName("cardiary-import-source-A1b2C3"), "Swift-style names are not allowlisted")
        #expect(!AgentTempClean.matchesKnownName("agent-contract-A1b2C3"), "generic agent prefix is not allowlisted")
        #expect(!AgentTempClean.matchesKnownName("../cardiary-host-A1b2C3"), "path separator rejected")
    }

    // MARK: Sweep behavior (isolated)

    @Test func movesVerifiedOldKnownDirectoryToTheTrash() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-10 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-host-Ab1Cd2", childMtime: old)
        try age(candidate, to: old)

        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log))
        #expect(result.verified)
        #expect(result.movedCount == 1)
        #expect(result.isSuccess)
        #expect(!fileManager.fileExists(atPath: candidate.path))
        let trashed = ((try? fileManager.contentsOfDirectory(atPath: s.trash.path)) ?? [])
        #expect(trashed.contains("cardiary-host-Ab1Cd2"))

        let log = OperationLog(url: s.log)
        let entries = log.read(limit: 10)
        #expect(entries.contains { $0.source == AgentTempClean.taskID && $0.result == "trashed" && $0.command == "autoclean" })
    }

    @Test func unknownAndMalformedNamesAreUntouched() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let a = try makeCandidate(s.root, "cardiary-unknown-Ab1Cd2")
        let b = try makeCandidate(s.root, "cardiary-host-ab1")
        let c = try makeCandidate(s.root, "cardiary-contract-Ab1Cd2-extra")
        for url in [a, b, c] { try age(url, to: old) }
        _ = try makeCandidate(s.root, "random-Ab1Cd2")

        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log))
        #expect(result.verified)
        #expect(result.movedCount == 0)
        #expect(result.skippedCount == 0, "unknown names are ignored entirely, not counted as skipped candidates")
        for url in [a, b, c] { #expect(fileManager.fileExists(atPath: url.path)) }
    }

    @Test func recentlyWrittenChildProtectsTheWholeCandidate() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-import-Ab1Cd2",
                                          childMtime: old,
                                          contents: ["old.txt": "ok", "fresh.txt": "written just now"])
        try "written just now".write(to: candidate.appending(path: "fresh.txt"),
                                     atomically: true, encoding: .utf8) // mtime = now; the only fresh entry
        try age(candidate, to: old)  // dir aged again; the fresh child must be what protects it

        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log))
        let skipped = result.items.filter { $0.result == .skipped }
        #expect(skipped.count == 1)
        #expect(skipped.first?.message?.contains("retention") == true)
        #expect(fileManager.fileExists(atPath: candidate.path))
    }

    @Test func topLevelMtimeAloneIsNotEnoughWhenANestedFileIsFresh() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-context-Ab1Cd2", contents: ["deep/nested.txt": "fresh"])
        try age(candidate, to: old)

        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log))
        #expect(result.movedCount == 0)
        #expect(fileManager.fileExists(atPath: candidate.path))
    }

    @Test func candidateWithOpenFileOrCwdIsSkipped() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let active = try makeCandidate(s.root, "cardiary-mcp-concurrent-IAZABa",
                                       childMtime: old,
                                       contents: ["tmp/mcp/concurrent-init/marker.txt": "busy"])
        let idle = try makeCandidate(s.root, "cardiary-mcp-concurrent-IAZABb", childMtime: old)
        for url in [active, idle] { try age(url, to: old) }
        let deepPath = active.appending(path: "tmp/mcp/concurrent-init").path

        // The active candidate has a process cwd deep inside it; only that candidate is protected.
        let options = options(root: s.root, trash: s.trash, log: s.log,
                              openFiles: { _ in [deepPath + "/out.log", deepPath] })
        let result = AgentTempClean.run(options: options)
        #expect(result.movedCount == 1)
        #expect(fileManager.fileExists(atPath: active.path), "candidate with an open deep cwd is skipped")
        #expect(!fileManager.fileExists(atPath: idle.path), "the other candidate moves")
        #expect(result.items.contains { $0.path == PathSafety.normalize(active.path) && $0.result == .skipped && ($0.message ?? "").contains("in use") })
    }

    @Test func lsofFailureSkipsEverything() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-host-Ab1Cd2")
        try age(candidate, to: old)

        let options = options(root: s.root, trash: s.trash, log: s.log, openFiles: { _ in nil })
        let result = AgentTempClean.run(options: options)
        #expect(!result.verified)
        #expect(result.movedCount == 0 && result.items.isEmpty)
        #expect(result.failure?.contains("lsof") == true)
        #expect(fileManager.fileExists(atPath: candidate.path))
    }

    @Test func symlinkCandidateIsSkipped() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let target = s.root.appending(path: "elsewhere")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let link = s.root.appending(path: "cardiary-host-Xy1Za2")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log))
        #expect(result.movedCount == 0)
        #expect(fileManager.fileExists(atPath: link.path))
        #expect(fileManager.fileExists(atPath: target.path))
        #expect(result.items.contains { $0.path == PathSafety.normalize(link.path) && $0.result == .skipped && $0.message == "not a directory" })
    }

    @Test func symlinkInsideCandidateIsNotFollowed() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let outside = s.root.deletingLastPathComponent().appending(path: "sentinel-\(UUID().uuidString).txt")
        try "keep me".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: outside) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-host-Ab1Cd2", childMtime: old)
        let link = candidate.appending(path: "outside-link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)
        // The symlink's own mtime must also be old, or the retention check (correctly) protects the candidate.
        let touch = Process()
        touch.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        touch.arguments = ["-h", "-t", "202001010000", link.path]
        try touch.run()
        touch.waitUntilExit()
        #expect(touch.terminationStatus == 0)
        try age(candidate, to: old)

        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log))
        #expect(result.movedCount == 1, "a nested symlink does not block the move")
        #expect(fileManager.fileExists(atPath: outside.path), "the symlink target outside the candidate is untouched")
    }

    @Test func nonDirectoryWithKnownNameIsSkipped() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let file = s.root.appending(path: "cardiary-contract-Qw1Er2")
        try "data".write(to: file, atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-30 * 86_400)
        try age(file, to: old)

        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log))
        #expect(result.movedCount == 0)
        #expect(fileManager.fileExists(atPath: file.path))
        #expect(result.items.contains { $0.path == PathSafety.normalize(file.path) && $0.result == .skipped })
    }

    @Test func earlierRemovalCannotInvalidateLaterCandidates() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-10 * 86_400)
        let first = try makeCandidate(s.root, "cardiary-host-Aaaaa1", childMtime: old)
        let later = try makeCandidate(s.root, "cardiary-host-Bbbbb2", childMtime: old)
        try age(first, to: old)
        try age(later, to: old)
        var options = options(root: s.root, trash: s.trash, log: s.log)
        options.useTrash = false
        let safety = PathSafety(protectedPaths: [], whitelist: [], allowedRoots: [s.root.path], minimumDepth: 1)
        options.executor = CleanExecutor.injected(safety: safety, log: OperationLog(url: s.log),
            removal: .custom(trash: { _ in Issue.record("unexpected Trash operation") }, delete: { url in
                if url.lastPathComponent == first.lastPathComponent {
                    try Data("new".utf8).write(to: later.appending(path: "child.txt"))
                }
                try FileManager.default.removeItem(at: url)
            }))

        let result = AgentTempClean.run(options: options)
        #expect(result.deletedCount == 1)
        #expect(result.items.contains { $0.path == PathSafety.normalize(later.path) && $0.result == .skipped })
        #expect(fileManager.fileExists(atPath: later.path))
    }

    @Test func emptyOldDirectoryMoves() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-host-Empty1", contents: [:])
        try age(candidate, to: old)

        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log))
        #expect(result.movedCount == 1)
        #expect(!fileManager.fileExists(atPath: candidate.path))
    }

    @Test func mountedFilesystemRootIsSkipped() throws {
        // st_dev of the candidate differs from the root's st_dev: we cannot fabricate a mount point
        // in a unit test, so this pins the check's placement instead — walkTree must reject on its own.
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let candidate = try makeCandidate(s.root, "cardiary-host-Mount1")
        var st = stat()
        #expect(lstat(candidate.path, &st) == 0)
        let fakeDifferentDev = rootDev(of: s.root) + 999
        let walk = AgentTempClean.walkTree(candidate.path, rootDev: fakeDifferentDev, rootMtime: Date())
        #expect(!walk.ok, "a tree on a different device fails verification")
        #expect(walk.error?.contains("mounted filesystem") == true || walk.error?.contains("could not") == true)
    }

    @Test func descendantMustBelongToExpectedUser() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let candidate = try makeCandidate(s.root, "cardiary-host-Owner1")
        let device = rootDev(of: candidate)
        let now = Date()
        #expect(AgentTempClean.walkTree(candidate.path, rootDev: device, rootMtime: now, expectedUID: getuid()).ok)
        let foreign = AgentTempClean.walkTree(candidate.path, rootDev: device, rootMtime: now, expectedUID: getuid() &+ 1)
        #expect(!foreign.ok)
        #expect(foreign.error?.contains("child.txt is owned by another user") == true)
    }

    private func rootDev(of url: URL) -> dev_t {
        var st = stat()
        _ = lstat(url.path, &st)
        return st.st_dev
    }

    @Test func deleteModeIsUsedWhenTrashSettingIsOff() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-host-Del123", childMtime: old)
        try age(candidate, to: old)

        var options = options(root: s.root, trash: s.trash, log: s.log)
        options.useTrash = false
        let backend = TestTrashBackend(trashDirectory: s.trash)
        let safety = PathSafety(protectedPaths: [], whitelist: [], allowedRoots: [s.root.path], minimumDepth: 1)
        options.executor = CleanExecutor.injected(safety: safety, log: OperationLog(url: s.log), removal: backend.backend)

        let result = AgentTempClean.run(options: options)
        #expect(result.deletedCount == 1)
        #expect(result.trashedCount == 0)
        #expect(!fileManager.fileExists(atPath: candidate.path))
        #expect(backend.deletedPaths == [PathSafety.normalize(candidate.path)])
        #expect(backend.trashedPaths.isEmpty)
        #expect(result.summary.contains("deleted 1 item"))
        #expect(!result.summary.contains("to the Trash"))
    }

    @Test func trashSettingKeepsTheDefaultRecoverableBehaviour() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-host-Trs123", childMtime: old)
        try age(candidate, to: old)

        let backend = TestTrashBackend(trashDirectory: s.trash)
        var options = options(root: s.root, trash: s.trash, log: s.log)   // useTrash defaults to true
        let safety = PathSafety(protectedPaths: [], whitelist: [], allowedRoots: [s.root.path], minimumDepth: 1)
        options.executor = CleanExecutor.injected(safety: safety, log: OperationLog(url: s.log), removal: backend.backend)

        let result = AgentTempClean.run(options: options)
        #expect(result.trashedCount == 1)
        #expect(result.deletedCount == 0)
        #expect(backend.trashedPaths == [PathSafety.normalize(candidate.path)])
        #expect(backend.deletedPaths.isEmpty)
        #expect(result.summary.contains("to the Trash"))
    }

    @Test func defaultOptionsFollowTheSettingMatrix() {
        var config = AutoCleanConfig()
        config.trashInstead = nil; config.permanent = false
        #expect(!AgentTempClean.defaultOptions(for: config).useTrash, "missing setting means delete, matching the low-risk rules")
        config.trashInstead = false
        #expect(!AgentTempClean.defaultOptions(for: config).useTrash)
        config.trashInstead = true
        #expect(AgentTempClean.defaultOptions(for: config).useTrash)
        config.permanent = true
        #expect(!AgentTempClean.defaultOptions(for: config).useTrash, "permanent wins over trashInstead")
        config.trashInstead = nil
        #expect(!AgentTempClean.defaultOptions(for: config).useTrash)
    }

    @Test func parseOpenFilesOutputKeepsNewlinesAndRejectsGarbage() {
        let bytes: [UInt8] = Array("p181\0".utf8) + [0x0A] + Array("fcwd\0".utf8) + Array("n/tmp/a\nb\0".utf8) + [0x0A] + Array("ftxt\0".utf8)
        #expect(AgentTempClean.parseOpenFilesOutput(Data(bytes)) == ["/tmp/a\nb"])

        let raw = Data("p1\0".utf8) + Array("n/x y\0".utf8)
        #expect(AgentTempClean.parseOpenFilesOutput(raw) == ["/x y"])

        #expect(AgentTempClean.parseOpenFilesOutput(Data([0x0A, 0x0A])) == [])
        #expect(AgentTempClean.parseOpenFilesOutput(Data()) == [])
        #expect(AgentTempClean.parseOpenFilesOutput(Data("q1\0".utf8)) == nil, "an unexpected field identifier rejects the output")
        #expect(AgentTempClean.parseOpenFilesOutput(Data("p1\0garbage".utf8)) == nil, "an unterminated/unknown field rejects the output")
    }

    @Test func openFileWithNewlineInPathIsListed() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let dir = s.root.appendingPathComponent("cardiary-context-Xy12AB", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("child\nwith\nnewline.log")
        try "data".write(to: file, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let paths = AgentTempClean.systemOpenFiles(uid: getuid())
        #expect(paths != nil)
        // What the sweep actually relies on: the open path appears, and its first component under
        // the root is the candidate. (Darwin lsof 4.91 renders the newlines inside the file name
        // as backslash-n; deep bytes are never compared by the in-use matching.)
        let rootPrefix = PathSafety.normalize(s.root.path) + "/"
        let listing = (paths ?? []).filter { $0.hasPrefix(rootPrefix) }
        #expect(listing.contains { $0.dropFirst(rootPrefix.count).hasPrefix("cardiary-context-Xy12AB") },
                "lsof must report this open file even though its name contains newlines")
        #expect(listing.contains { $0.contains("child\\nwith\\nnewline.log") },
                "Darwin lsof renders LF in names as a two-byte escape; observe and pin it")
    }

    @Test func cwdWithNewlineIsListed() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let dir = s.root.appendingPathComponent("cwd\nwith-newline", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        sleeper.currentDirectoryURL = dir
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }

        var found = false
        let deadline = Date().addingTimeInterval(5)
        let parentPrefix = PathSafety.normalize(s.root.path) + "/"
        while !found, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            found = AgentTempClean.systemOpenFiles(uid: getuid())?.contains {
                // First component only; the newline inside the directory name is escape-rendered.
                $0.hasPrefix(parentPrefix + "cwd")
            } ?? false
        }
        #expect(found, "lsof must list this user's process cwd even though the path contains a newline")
        let finalListing = AgentTempClean.systemOpenFiles(uid: getuid()) ?? []
        #expect(finalListing.contains { $0.contains("cwd\\nwith-newline") },
                "Darwin lsof renders LF in names as a two-byte escape; observe and pin it")
    }

    @Test func openFilesProbeRunsTwiceWhenSomethingIsRemoved() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-host-Pr1234", childMtime: old)
        try age(candidate, to: old)

        let counter = ProbeCounter()
        let openFiles: @Sendable (UInt32) -> [String]? = { _ in counter.next(); return [] }
        _ = try AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log, openFiles: openFiles))
        #expect(counter.count == 2, "one probe before planning, one right before removal")
    }

    @Test func openFilesProbeRunsOnceWhenNothingSurvives() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let candidate = try makeCandidate(s.root, "cardiary-host-Fr1234")   // children just written
        let counter = ProbeCounter()
        let openFiles: @Sendable (UInt32) -> [String]? = { _ in counter.next(); return [] }

        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log, openFiles: openFiles))
        #expect(result.movedCount == 0)
        #expect(counter.count == 1, "no final probe when no candidate survived the first pass")
    }

    @Test func openedBetweenProbesIsCaughtBeforeRemoval() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-host-Bt1234", childMtime: old)
        try age(candidate, to: old)
        let hit = candidate.appendingPathComponent("child.txt").path

        let counter = ProbeCounter()
        let openFiles: @Sendable (UInt32) -> [String]? = { _ in
            if counter.next() == 1 { return [] }
            return [hit]   // the process we adopted mid-scan opened its log file before removal
        }
        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log, openFiles: openFiles))
        #expect(result.movedCount == 0)
        #expect(fileManager.fileExists(atPath: candidate.path))
        #expect(result.items.contains { $0.path == PathSafety.normalize(candidate.path) && $0.result == .skipped && ($0.message ?? "").contains("re-checked before removal") })
    }

    @Test func changedBetweenProbesIsCaughtBeforeRemoval() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-host-Cw1234", childMtime: old)
        try age(candidate, to: old)

        let counter = ProbeCounter()
        let openFiles: @Sendable (UInt32) -> [String]? = { _ in
            if counter.next() == 1 { return [] }
            try? "fresh data".write(to: candidate.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)
            return []
        }
        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log, openFiles: openFiles))
        #expect(result.movedCount == 0)
        #expect(fileManager.fileExists(atPath: candidate.path))
        #expect(result.items.contains { $0.path == PathSafety.normalize(candidate.path) && $0.result == .skipped })
    }

    @Test func directoryReplacedBetweenProbesIsCaughtBeforeRemoval() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-host-Rp1234", childMtime: old)
        try age(candidate, to: old)

        let counter = ProbeCounter()
        let openFiles: @Sendable (UInt32) -> [String]? = { _ in
            if counter.next() == 1 { return [] }
            // A new run replaced the directory with a fresh one (same name, new inode).
            try? FileManager.default.removeItem(at: candidate)
            try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            try? "rebuildable".write(to: candidate.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: candidate.appendingPathComponent("child.txt").path)
            try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: candidate.path)
            return []
        }
        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log, openFiles: openFiles))
        #expect(result.movedCount == 0)
        #expect(fileManager.fileExists(atPath: candidate.path), "the replacement directory must survive")
        #expect(result.items.contains { $0.path == PathSafety.normalize(candidate.path) && $0.result == .skipped && ($0.message ?? "").contains("changed during the scan") })
    }

    @Test func tempRootReplacedBetweenProbesStandsDown() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-host-Rt1234", childMtime: old)
        try age(candidate, to: old)

        let counter = ProbeCounter()
        let openFiles: @Sendable (UInt32) -> [String]? = { _ in
            if counter.next() == 1 { return [] }
            // The temp root itself was replaced: rm -rf + recreate (same path, different inode).
            try? FileManager.default.removeItem(at: s.root)
            try? FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
            return []
        }
        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log, openFiles: openFiles))
        #expect(result.verified == false)
        #expect(result.failure?.contains("temp folder changed") == true)
        #expect(result.movedCount == 0)
        #expect(fileManager.fileExists(atPath: s.root.path))
        #expect(result.items.allSatisfy { $0.result == .skipped })
    }

    @Test func secondProbeFailureStandsDownBeforeRemoval() throws {
        let s = try makeSandbox()
        defer { try? fileManager.removeItem(at: s.root.deletingLastPathComponent()) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let candidate = try makeCandidate(s.root, "cardiary-host-Pf1234", childMtime: old)
        try age(candidate, to: old)

        let counter = ProbeCounter()
        let openFiles: @Sendable (UInt32) -> [String]? = { _ in
            if counter.next() == 1 { return [] }
            return nil   // the second probe cannot be trusted
        }
        let result = AgentTempClean.run(options: options(root: s.root, trash: s.trash, log: s.log, openFiles: openFiles))
        #expect(result.verified == false)
        #expect(result.failure?.contains("re-check which files are open") == true)
        #expect(result.movedCount == 0)
        #expect(fileManager.fileExists(atPath: candidate.path))
    }

    private final class ProbeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        @discardableResult
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: Scheduling-path integration

    @Test func scheduledRunCallsTheSweepOnlyWhenEnabled() throws {
        var config = AutoCleanConfig()
        config.enabled = true
        config.maintenanceTasks = []

        var called = false
        let result = AutoClean.run(config: config, rules: [],
                                   runTask: { TaskOutcome(id: $0.id, ok: true, dryRun: false, output: "") },
                                   agentTempClean: { _ in
                                       called = true
                                       return AgentTempClean.AgentTempCleanResult(verified: true, failure: nil, items: [])
                                   })
        #expect(!called, "agent temp sweep is off by default")
        #expect(!result.2.contains { $0.id == AgentTempClean.taskID })

        config.agentTempClean = true
        let seen = AutoClean.run(config: config, rules: [],
                                 runTask: { TaskOutcome(id: $0.id, ok: true, dryRun: false, output: "") },
                                 agentTempClean: { _ in
                                     called = true
                                     return AgentTempClean.AgentTempCleanResult(verified: true, failure: nil, items: [])
                                 })
        #expect(called)
        #expect(seen.2.contains { $0.id == AgentTempClean.taskID && $0.ok })
    }

    @Test func sweepItemsFoldIntoTheReportAndTheOutcomeShowsUp() throws {
        var config = AutoCleanConfig()
        config.enabled = true
        config.agentTempClean = true
        config.maintenanceTasks = []
        let sweepItem = ItemOutcome(path: "/private/var/folders/xx/testT/cardiary-host-Ab1Cd2",
                                    source: AgentTempClean.taskID, bytes: 1234, result: .trashed, message: nil)

        let (_, report, tasks) = AutoClean.run(config: config, rules: [],
                                               runTask: { TaskOutcome(id: $0.id, ok: true, dryRun: false, output: "") },
                                               agentTempClean: { _ in
                                                   AgentTempClean.AgentTempCleanResult(verified: true, failure: nil, items: [sweepItem])
                                               })
        #expect(report.items.contains { $0.path == sweepItem.path })
        #expect(report.trashedBytes == 1234)
        #expect(tasks.contains { $0.id == AgentTempClean.taskID && $0.ok && $0.output.contains("moved 1 item") })

        AutoClean.record(report, tasks: tasks, into: &config)
        #expect(config.lastItemCount == 1)
        #expect(config.lastTrashedBytes == 1234)
        #expect(config.lastError == nil)
    }

    @Test func unverifiableSweepLandsInTheLastError() throws {
        var config = AutoCleanConfig()
        config.enabled = true
        config.agentTempClean = true
        config.maintenanceTasks = []

        let (_, report, tasks) = AutoClean.run(config: config, rules: [],
                                               runTask: { TaskOutcome(id: $0.id, ok: true, dryRun: false, output: "") },
                                               agentTempClean: { _ in
                                                   AgentTempClean.AgentTempCleanResult(verified: false, failure: "could not check which files are open (lsof); nothing was touched", items: [])
                                               })
        let failureTask = tasks.first { $0.id == AgentTempClean.taskID }
        #expect(failureTask?.ok == false)

        AutoClean.record(report, tasks: tasks, into: &config)
        #expect(config.lastError?.contains("agent-temp.clean") == true)
        #expect(config.lastError?.contains("Scheduled task failed") == true)
    }
}
