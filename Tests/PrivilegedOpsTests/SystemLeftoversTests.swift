import Darwin
import Foundation
import Testing
@testable import PrivilegedOps

@Suite struct SystemLeftoversTests {
    private func tempDir(_ tag: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    private func exists(_ p: String) -> Bool { var st = stat(); return lstat(p, &st) == 0 }

    @Test func validatesOnlyDirectChildrenOfFixedFolders() throws {
        #expect(try SystemLeftovers.validate("/Library/Caches/com.vendor.app").components == ["com.vendor.app"])
        #expect(try SystemLeftovers.validate("/Library/Application Support/Vendor/Product").components == ["Vendor", "Product"])
        #expect(try SystemLeftovers.validate("/Library/Audio/Plug-Ins/HAL/Thing.driver").area.dir == "/Library/Audio/Plug-Ins/HAL")
        for bad in ["/Library/Caches", "/Library/Caches/", "/Library/Caches/a/b", "/Library/Caches/../Keychains",
                    "/Library/Caches//x", "Library/Caches/x", "/System/Library/x", "/etc/sudoers", "/Library/Keychains/x",
                    "/Library/Application Support/A/B/C", "/Library/Caches/.hidden", "/Users/smile/Library/x"] {
            #expect(throws: SystemLeftovers.ValidationError.self, "\(bad)") { try SystemLeftovers.validate(bad) }
        }
    }

    @Test func refusesAppleSharedAndMacHelperNames() {
        for p in ["/Library/Caches/com.apple.iconservices", "/Library/Application Support/Apple/x", "/Library/Application Support/AppleUSB",
                  "/Library/LaunchDaemons/com.machelper.MacHelper.Helper.plist", "/Library/Application Support/MacHelper",
                  "/Library/Application Support/CrashReporter", "/Library/Application Support/Script Editor"] {
            #expect(throws: SystemLeftovers.ValidationError.protectedName(p)) { try SystemLeftovers.validate(p) }
        }
    }

    @Test func enforcesSuffixes() {
        #expect(throws: SystemLeftovers.ValidationError.self) { try SystemLeftovers.validate("/Library/LaunchDaemons/evil") }
        #expect(throws: SystemLeftovers.ValidationError.self) { try SystemLeftovers.validate("/private/var/db/receipts/x.txt") }
        #expect((try? SystemLeftovers.validate("/private/var/db/receipts/com.vendor.pkg.bom")) != nil)
    }

    @Test func movesIntoTrashAndRenamesOnCollision() throws {
        let area = try tempDir("area"), trash = try tempDir("trash")
        defer { try? FileManager.default.removeItem(atPath: area); try? FileManager.default.removeItem(atPath: trash) }
        let areas = [SystemLeftovers.Area(area)]
        try FileManager.default.createDirectory(atPath: area + "/com.vendor.app/sub", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: area + "/com.vendor.app/sub/file"))
        try FileManager.default.createDirectory(atPath: trash + "/com.vendor.app", withIntermediateDirectories: true)

        var called = false
        let me = SystemLeftovers.Owner(uid: getuid(), gid: getgid())
        let r = SystemLeftovers.moveToTrash(area + "/com.vendor.app", trash: trash, owner: me, areas: areas) { _ in called = true }
        #expect(r.error == nil)
        #expect(called)
        let name = try #require(r.trashedAs)
        #expect(name != "com.vendor.app" && name.hasPrefix("com.vendor ") && name.hasSuffix(".app"),
                "existing Trash item kept; the new one is renamed with the extension kept last")
        #expect(!exists(area + "/com.vendor.app"))
        #expect(exists(trash + "/" + name + "/sub/file"))
        #expect(exists(trash + "/com.vendor.app"))
    }

    @Test func beforeMoveCanCancel() throws {
        let area = try tempDir("area"), trash = try tempDir("trash")
        defer { try? FileManager.default.removeItem(atPath: area); try? FileManager.default.removeItem(atPath: trash) }
        try Data().write(to: URL(fileURLWithPath: area + "/job.plist"))
        struct Refused: Error {}
        let r = SystemLeftovers.moveToTrash(area + "/job.plist", trash: trash, owner: nil, areas: [SystemLeftovers.Area(area)]) { _ in throw Refused() }
        #expect(r.error != nil)
        #expect(exists(area + "/job.plist"))
    }

    @Test func linkedFoldersAndTrashAreRefused() throws {
        let area = try tempDir("area"), trash = try tempDir("trash"), outside = try tempDir("outside")
        defer { for d in [area, trash, outside] { try? FileManager.default.removeItem(atPath: d) } }
        try FileManager.default.createDirectory(atPath: outside + "/Product", withIntermediateDirectories: true)
        // Vendor folder is a link to somewhere else: refused, the target stays.
        try FileManager.default.createSymbolicLink(atPath: area + "/Vendor", withDestinationPath: outside)
        let nested = [SystemLeftovers.Area(area, maxDepth: 2)]
        let r = SystemLeftovers.moveToTrash(area + "/Vendor/Product", trash: trash, owner: nil, areas: nested)
        #expect(r.error != nil)
        #expect(exists(outside + "/Product"))

        // A Trash that is a link is refused too.
        try FileManager.default.createDirectory(atPath: area + "/Real", withIntermediateDirectories: true)
        let linkedTrash = trash + "/link"
        try FileManager.default.createSymbolicLink(atPath: linkedTrash, withDestinationPath: outside)
        let r2 = SystemLeftovers.moveToTrash(area + "/Real", trash: linkedTrash, owner: nil, areas: nested)
        #expect(r2.error != nil)
        #expect(exists(area + "/Real"))
    }

    @Test func aLinkLeafIsMovedAsALink() throws {
        let area = try tempDir("area"), trash = try tempDir("trash"), outside = try tempDir("outside")
        defer { for d in [area, trash, outside] { try? FileManager.default.removeItem(atPath: d) } }
        try Data("keep".utf8).write(to: URL(fileURLWithPath: outside + "/victim"))
        try FileManager.default.createSymbolicLink(atPath: area + "/leftover", withDestinationPath: outside + "/victim")
        let r = SystemLeftovers.moveToTrash(area + "/leftover", trash: trash, owner: nil, areas: [SystemLeftovers.Area(area)])
        #expect(r.error == nil)
        #expect(exists(outside + "/victim"), "the link's target is untouched")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: trash + "/leftover")) == outside + "/victim")
    }

    @Test func symlinkOnlyAreasNeedALinkIntoAnApp() throws {
        let area = try tempDir("bin"), trash = try tempDir("trash")
        defer { try? FileManager.default.removeItem(atPath: area); try? FileManager.default.removeItem(atPath: trash) }
        let bin = [SystemLeftovers.Area(area, symlinksOnly: true)]
        try Data().write(to: URL(fileURLWithPath: area + "/realtool"))
        try FileManager.default.createSymbolicLink(atPath: area + "/other", withDestinationPath: "/usr/bin/true")
        try FileManager.default.createSymbolicLink(atPath: area + "/apptool", withDestinationPath: "/Applications/Gone.app/Contents/MacOS/tool")
        #expect(SystemLeftovers.moveToTrash(area + "/realtool", trash: trash, owner: nil, areas: bin).error != nil)
        #expect(SystemLeftovers.moveToTrash(area + "/other", trash: trash, owner: nil, areas: bin).error != nil)
        #expect(SystemLeftovers.moveToTrash(area + "/apptool", trash: trash, owner: nil, areas: bin).error == nil)
        #expect(exists(area + "/realtool") && exists(area + "/other"))
    }

    @Test func trashMustBeOwnedByTheUser() throws {
        let area = try tempDir("area")
        defer { try? FileManager.default.removeItem(atPath: area) }
        try Data().write(to: URL(fileURLWithPath: area + "/x"))
        // /private/tmp is owned by root, not by the test user.
        let r = SystemLeftovers.moveToTrash(area + "/x", trash: "/private/tmp", owner: .init(uid: getuid(), gid: getgid()),
                                            areas: [SystemLeftovers.Area(area)])
        #expect(r.error?.contains("isn't owned") == true)
        #expect(exists(area + "/x"))
    }

    @Test func requestAndResultRoundTrip() throws {
        let r = SystemLeftovers.Result(items: [.init(path: "/Library/Caches/x", trashedAs: "x", error: nil)])
        #expect(try JSONDecoder().decode(SystemLeftovers.Result.self, from: JSONEncoder().encode(r)) == r)
    }
}

@Suite struct ProcessCountersTests {
    @Test func readsOwnProcess() throws {
        let me = try #require(ProcessCounters.read(getpid()))
        #expect(me.pid == getpid())
        #expect(me.footprint > 0)
        #expect(ProcessCounters.readAll().contains { $0.pid == getpid() })
    }
}
