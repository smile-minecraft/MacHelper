import AppKit
import Foundation
import Testing
@testable import Tweaks

@Suite struct WindowIdentityTests {
    @Test func idsRoundTripThroughTheirTextForm() {
        let identity = WindowIdentity(pid: 4321, index: 2)
        #expect(identity.description == "4321:2")
        #expect(WindowIdentity("4321:2") == identity)
        #expect(WindowIdentity("0:2") == nil)
        #expect(WindowIdentity("4321") == nil)
        #expect(WindowIdentity("4321:-1") == nil)
        #expect(WindowIdentity("4321:two") == nil)
        #expect(WindowIdentity("") == nil)
    }

    @Test func idsAreJSONStringsSoTheListOutputCanBePassedStraightBack() throws {
        let identities = [WindowIdentity(pid: 42, index: 0), WindowIdentity(pid: 42, index: 1)]
        let data = try JSONEncoder().encode(identities)
        #expect(String(decoding: data, as: UTF8.self) == #"["42:0","42:1"]"#)
        #expect(try JSONDecoder().decode([WindowIdentity].self, from: data) == identities)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WindowIdentity.self, from: Data(#""nope""#.utf8))
        }
    }

    @Test func framesKeepTheirScreenSpaceShape() {
        let frame = WindowFrame(CGRect(x: 10, y: 20, width: 400, height: 200))
        #expect(frame.rect == CGRect(x: 10, y: 20, width: 400, height: 200))
        #expect(frame.aspectRatio == 2)
        #expect(WindowFrame(.zero).aspectRatio == 0)
    }
}

@Suite struct WindowCatalogGroupingTests {
    @Test func appsKeepTheirWindowOrderAndEmptyAppsAreDropped() {
        let app = NSRunningApplication.current
        let pid = app.processIdentifier
        let snapshots = [
            WindowSnapshot(id: WindowIdentity(pid: pid, index: 1), app: app.localizedName ?? "",
                           bundleID: app.bundleIdentifier, title: "second", minimized: false,
                           visible: true, frame: nil),
            WindowSnapshot(id: WindowIdentity(pid: pid, index: 0), app: app.localizedName ?? "",
                           bundleID: app.bundleIdentifier, title: "first", minimized: true,
                           visible: false, frame: nil),
        ]
        let groups = WindowCatalog.groups(snapshots, apps: [app])
        #expect(groups.count == 1)
        #expect(groups.first?.windows.map(\.title) == ["second", "first"])
        #expect(groups.first?.id == pid)

        let empty = WindowSnapshot(id: WindowIdentity(pid: 999_999, index: 0), app: "Gone",
                                   bundleID: "example.gone", title: "", minimized: false,
                                   visible: true, frame: nil)
        #expect(WindowCatalog.groups([empty], apps: [app]).isEmpty)
    }
}
