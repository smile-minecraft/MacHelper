import Foundation
import Testing
@testable import CleanEngine

/// The Uninstall page accepts an app bundle dropped from Finder. These tests cover which URLs that
/// drop accepts and which installed row a dropped bundle stands for, using throwaway bundles in a
/// temporary folder.
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

    /// A row of the installed list. The list itself is read from the real Applications folders, so
    /// the rows a drop is matched against are built here instead.
    private func row(_ path: String, bundleID: String) -> InstalledApp {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return InstalledApp(name: name, bundleID: bundleID, version: nil, path: path, size: 0, isAppStore: false,
                            lastUsed: nil, isRunning: false, teamID: nil, protectedReason: nil)
    }

    @Test func acceptsAnAppBundle() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try makeBundle(in: folder, name: "Dropped")

        #expect(AppUninstaller.isAppBundle(bundle))
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
    }

    @Test func rejectsWhatIsNotAnAppBundle() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let text = folder.appendingPathComponent("Note.txt")
        try Data("not an app".utf8).write(to: text)
        #expect(!AppUninstaller.isAppBundle(text))

        // A folder with the right extension but no bundle behind it.
        let empty = folder.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(!AppUninstaller.isAppBundle(empty))

        // A bundle without a bundle identifier.
        let broken = try makeBundle(in: folder, name: "Broken", bundleID: nil)
        #expect(!AppUninstaller.isAppBundle(broken))

        // A real bundle under another extension.
        let bundle = try makeBundle(in: folder, name: "Renamed")
        let renamed = folder.appendingPathComponent("Renamed.bundle")
        try FileManager.default.moveItem(at: bundle, to: renamed)
        #expect(!AppUninstaller.isAppBundle(renamed))

        #expect(!AppUninstaller.isAppBundle(URL(string: "https://example.com/Foo.app")!))
        #expect(!AppUninstaller.isAppBundle(folder.appendingPathComponent("Missing.app")))
    }

    @Test func aDroppedBundleSelectsItsOwnRow() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try makeBundle(in: folder, name: "Slack", bundleID: "com.example.slack")
        let installed = row(bundle.standardizedFileURL.path, bundleID: "com.example.slack")

        #expect(AppUninstaller.installedApp(forDroppedBundle: bundle, in: [installed]) == installed)
        // Finder can hand the URL over with a trailing slash.
        #expect(AppUninstaller.installedApp(forDroppedBundle: URL(fileURLWithPath: bundle.path + "/"),
                                            in: [installed]) == installed)
    }

    @Test func anotherCopyOfAnInstalledAppSelectsTheInstalledRow() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Slack is installed in /Applications and the user drags a second copy out of a DMG.
        let installed = row("/Applications/Slack.app", bundleID: "com.example.slack")
        let copy = try makeBundle(in: folder, name: "Slack", bundleID: "com.example.slack")

        #expect(AppUninstaller.installedApp(forDroppedBundle: copy, in: [installed]) == installed)

        // When both copies are in the list, the one in the Applications folder is the app.
        let outside = row(folder.appendingPathComponent("Other/Slack.app").path, bundleID: "com.example.slack")
        #expect(AppUninstaller.installedApp(forDroppedBundle: copy, in: [outside, installed]) == installed)
        #expect(AppUninstaller.installedApp(forDroppedBundle: copy, in: [installed, outside]) == installed)

        // With no Applications copy, the row that does exist is still the answer.
        #expect(AppUninstaller.installedApp(forDroppedBundle: copy, in: [outside]) == outside)
    }

    @Test func aBundleThatIsNotInstalledHasNoRow() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dropped = try makeBundle(in: folder, name: "Zoom", bundleID: "com.example.zoom")
        let installed = row("/Applications/Slack.app", bundleID: "com.example.slack")

        #expect(AppUninstaller.installedApp(forDroppedBundle: dropped, in: [installed]) == nil)
        #expect(AppUninstaller.installedApp(forDroppedBundle: dropped, in: []) == nil)

        // A folder that isn't a bundle can't stand for anything.
        let plain = folder.appendingPathComponent("Notes.app")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(AppUninstaller.installedApp(forDroppedBundle: plain, in: [installed]) == nil)
    }
}
