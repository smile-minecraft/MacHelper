import Foundation
import Testing
@testable import CleanEngine

/// The Uninstall page accepts an app bundle dropped from Finder. These tests cover which URLs
/// that drop accepts and what row the app gets, using throwaway bundles in a temporary folder.
@Suite struct AppBundleDropTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("machelper-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A minimal macOS app bundle. `bundleID` nil leaves out the identifier, like a broken bundle.
    @discardableResult
    private func makeBundle(in folder: URL, name: String, bundleID: String? = "com.example.dropped",
                            version: String = "1.2.3") throws -> URL {
        let bundle = folder.appendingPathComponent("\(name).app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleName": name, "CFBundlePackageType": "APPL"]
        if let bundleID {
            info["CFBundleIdentifier"] = bundleID
            info["CFBundleShortVersionString"] = version
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/\(name)"))
        return bundle
    }

    @Test func acceptsAnAppBundle() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try makeBundle(in: folder, name: "Dropped")

        #expect(AppUninstaller.isAppBundle(bundle))
        let app = try #require(AppUninstaller.app(at: bundle))
        #expect(app.path == bundle.standardizedFileURL.path)
        #expect(app.bundleID == "com.example.dropped")
        #expect(app.name == "Dropped")
        #expect(app.version == "1.2.3")
        #expect(app.size > 0)
        #expect(app.canUninstall)
        #expect(!app.isRunning)
        #expect(!app.isAppStore)
    }

    @Test func acceptsTheFolderFormsFinderHandsOver() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let upper = folder.appendingPathComponent("Upper.APP")
        try FileManager.default.createDirectory(at: upper.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.upper", "CFBundleName": "Upper"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: upper.appendingPathComponent("Contents/Info.plist"))

        #expect(AppUninstaller.isAppBundle(upper))
        #expect(AppUninstaller.isAppBundle(URL(fileURLWithPath: upper.path + "/")))
        #expect(AppUninstaller.app(at: URL(fileURLWithPath: upper.path + "/"))?.bundleID == "com.example.upper")
    }

    @Test func rejectsWhatIsNotAnAppBundle() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let text = folder.appendingPathComponent("Note.txt")
        try Data("not an app".utf8).write(to: text)
        #expect(!AppUninstaller.isAppBundle(text))
        #expect(AppUninstaller.app(at: text) == nil)

        // A folder with the right extension but no bundle behind it.
        let empty = folder.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(!AppUninstaller.isAppBundle(empty))
        #expect(AppUninstaller.app(at: empty) == nil)

        // A bundle without a bundle identifier.
        let broken = try makeBundle(in: folder, name: "Broken", bundleID: nil)
        #expect(!AppUninstaller.isAppBundle(broken))
        #expect(AppUninstaller.app(at: broken) == nil)

        // A real bundle under another extension.
        let bundle = try makeBundle(in: folder, name: "Renamed")
        let renamed = folder.appendingPathComponent("Renamed.bundle")
        try FileManager.default.moveItem(at: bundle, to: renamed)
        #expect(!AppUninstaller.isAppBundle(renamed))
        #expect(AppUninstaller.app(at: renamed) == nil)

        #expect(!AppUninstaller.isAppBundle(URL(string: "https://example.com/Foo.app")!))
        #expect(!AppUninstaller.isAppBundle(folder.appendingPathComponent("Missing.app")))
    }

    @Test func keepsTheRulesTheAppListUses() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let apple = try #require(AppUninstaller.app(at: makeBundle(in: folder, name: "Notes", bundleID: "com.apple.Notes")))
        #expect(!apple.canUninstall)
        #expect(apple.protectedReason != nil)

        let own = try #require(AppUninstaller.app(at: makeBundle(in: folder, name: "MacHelper", bundleID: "com.machelper.MacHelper")))
        #expect(!own.canUninstall)
        #expect(own.protectedReason != nil)

        let store = try makeBundle(in: folder, name: "Store")
        let receipt = store.appendingPathComponent("Contents/_MASReceipt")
        try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
        try Data().write(to: receipt.appendingPathComponent("receipt"))
        #expect(try #require(AppUninstaller.app(at: store)).isAppStore)
    }
}
