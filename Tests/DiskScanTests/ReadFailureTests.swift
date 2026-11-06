import CSystemBridge
import Darwin
import Foundation
import Testing
@testable import DiskScan

@Suite struct ReadFailureTests {
    let home = "/Users/someone"
    func mine(_: String) -> uid_t? { getuid() }
    func root(_: String) -> uid_t? { 0 }

    @Test func permissionDeniedOutsideTheHomeFolderIsSystemProtection() {
        #expect(ReadFailure.classify(path: "/private/var/db/Spotlight", code: EPERM, home: home, ownerUID: root) == .protectedBySystem)
        #expect(ReadFailure.classify(path: "/System/Volumes/Data/private/var/db/oah", code: EPERM, home: home, ownerUID: root) == .protectedBySystem)
    }

    @Test func permissionDeniedInsideTheHomeFolderNeedsFullDiskAccess() {
        #expect(ReadFailure.classify(path: "/Users/someone/Library/Mail", code: EPERM, home: home, ownerUID: mine) == .inaccessible)
        // A whole-disk scan reaches the home folder through the Data volume.
        #expect(ReadFailure.classify(path: "/System/Volumes/Data/Users/someone/Library/Mail", code: EPERM, home: home, ownerUID: mine) == .inaccessible)
        #expect(ReadFailure.classify(path: "/Volumes/External/Photos", code: EPERM, home: home, ownerUID: mine) == .inaccessible)
    }

    @Test func folderOfAnotherAccountIsSystemProtection() {
        #expect(ReadFailure.classify(path: "/Users/other/Documents", code: EACCES, home: home, ownerUID: { _ in 4321 }) == .protectedBySystem)
        #expect(ReadFailure.classify(path: "/private/var/spool/postfix", code: EACCES, home: home, ownerUID: root) == .protectedBySystem)
        #expect(ReadFailure.classify(path: "/Users/someone/locked", code: EACCES, home: home, ownerUID: mine) == .inaccessible)
    }

    @Test func interruptedReadIsRetried() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "rf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scanner = DiskScanner()
        var calls = 0
        scanner.directoryEnumeration = { _, _, _ in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }
            return 0
        }
        let result = try scanner.scan(dir)
        #expect(calls == 2)
        #expect(result.progress.unreadableDirectories == 0)
        #expect(result.root.readError == 0)
    }

    @Test func mirrorMountIsSkippedSilently() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "rf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scanner = DiskScanner()
        scanner.directoryEnumeration = { _, _, _ in errno = ERANGE; return -1 }
        let result = try scanner.scan(dir)
        #expect(result.progress.unreadableDirectories == 0)
        #expect(result.progress.inaccessibleDirectories == 0)
    }

    @Test func oldSavedProgressDecodesWithoutProtectedCount() throws {
        let json = #"{"files":3,"directories":2,"bytes":10,"unreadableDirectories":1,"cloudOnlyDirectories":0}"#
        let p = try JSONDecoder().decode(ScanProgress.self, from: Data(json.utf8))
        #expect(p.protectedDirectories == 0)
        #expect(p.inaccessibleDirectories == 1)
    }
}
