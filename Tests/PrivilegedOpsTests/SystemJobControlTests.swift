import Foundation
import Testing
@testable import PrivilegedOps

@Suite struct SystemJobControlTests {
    private func folder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "jobs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    private func writePlist(_ dir: String, _ name: String, label: Any?) throws -> String {
        var job: [String: Any] = ["ProgramArguments": ["/usr/bin/true"]]
        if let label { job["Label"] = label }
        let path = dir + "/" + name
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func validate(_ path: String, _ dir: String) throws -> String {
        try SystemJobControl.validate(plistPath: path, kind: .daemon, directory: dir, requireRootOwner: false)
    }

    @Test func fixedFolders() {
        #expect(SystemJobControl.Kind.agent.directory == "/Library/LaunchAgents")
        #expect(SystemJobControl.Kind.daemon.directory == "/Library/LaunchDaemons")
    }

    @Test func readsLabelFromThePlist() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try writePlist(dir, "com.vendor.updater.plist", label: "com.vendor.updater")
        #expect(try validate(path, dir) == "com.vendor.updater")
    }

    @Test func refusesPathsOutsideTheFolder() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        let nested = try writePlist(dir + "/sub", "x.plist", label: "com.vendor.x")
        #expect(throws: SystemJobControl.ValidationError.notInDirectory(nested)) { try validate(nested, dir) }
        let dotted = dir + "/sub/../x.plist"
        #expect(throws: SystemJobControl.ValidationError.notInDirectory(dotted)) { try validate(dotted, dir) }
        #expect(throws: SystemJobControl.ValidationError.notInDirectory("/etc/x.plist")) { try validate("/etc/x.plist", dir) }
    }

    @Test func refusesBadFileNames() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let txt = try writePlist(dir, "job.txt", label: "com.vendor.x")
        #expect(throws: SystemJobControl.ValidationError.badFileName(txt)) { try validate(txt, dir) }
        let hidden = try writePlist(dir, ".hidden.plist", label: "com.vendor.x")
        #expect(throws: SystemJobControl.ValidationError.badFileName(hidden)) { try validate(hidden, dir) }
    }

    @Test func refusesSymbolicLinks() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let elsewhere = try folder(); defer { try? FileManager.default.removeItem(atPath: elsewhere) }
        let real = try writePlist(elsewhere, "real.plist", label: "com.vendor.real")
        let link = dir + "/linked.plist"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(throws: SystemJobControl.ValidationError.notRegularFile(link)) { try validate(link, dir) }

        // A linked folder is refused even if the file inside is fine.
        let linkedDir = dir + "/LinkedDaemons"
        try FileManager.default.createSymbolicLink(atPath: linkedDir, withDestinationPath: elsewhere)
        #expect(throws: SystemJobControl.ValidationError.notInDirectory(linkedDir + "/real.plist")) {
            try validate(linkedDir + "/real.plist", linkedDir)
        }
    }

    @Test func refusesProtectedAndMalformedLabels() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let apple = try writePlist(dir, "a.plist", label: "com.apple.something")
        #expect(throws: SystemJobControl.ValidationError.protectedLabel("com.apple.something")) { try validate(apple, dir) }
        let ours = try writePlist(dir, "b.plist", label: "com.machelper.MacHelper.Helper")
        #expect(throws: SystemJobControl.ValidationError.protectedLabel("com.machelper.MacHelper.Helper")) { try validate(ours, dir) }
        let injected = try writePlist(dir, "c.plist", label: "x; rm -rf /")
        #expect(throws: SystemJobControl.ValidationError.badLabel("x; rm -rf /")) { try validate(injected, dir) }
        let slash = try writePlist(dir, "d.plist", label: "gui/501/x")
        #expect(throws: SystemJobControl.ValidationError.badLabel("gui/501/x")) { try validate(slash, dir) }
        let none = try writePlist(dir, "e.plist", label: nil)
        #expect(throws: SystemJobControl.ValidationError.unreadable(none)) { try validate(none, dir) }
        let notString = try writePlist(dir, "f.plist", label: 42)
        #expect(throws: SystemJobControl.ValidationError.unreadable(notString)) { try validate(notString, dir) }
    }

    @Test func requiresRootOwnerByDefault() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try writePlist(dir, "mine.plist", label: "com.vendor.mine")
        // Tests run as a normal user, so the file is not root-owned.
        #expect(throws: SystemJobControl.ValidationError.notOwnedByRoot(path)) {
            try SystemJobControl.validate(plistPath: path, kind: .daemon, directory: dir)
        }
    }

    @Test func commandsOnlyEnableOrDisable() {
        let off = SystemJobControl.commands(label: "com.vendor.x", plistPath: "/Library/LaunchDaemons/x.plist", domain: "system", enabled: false)
        #expect(off.required == ["disable", "system/com.vendor.x"])
        #expect(off.bestEffort == ["bootout", "system/com.vendor.x"])
        let on = SystemJobControl.commands(label: "com.vendor.x", plistPath: "/Library/LaunchDaemons/x.plist", domain: "system", enabled: true)
        #expect(on.required == ["enable", "system/com.vendor.x"])
        #expect(on.bestEffort == ["bootstrap", "system", "/Library/LaunchDaemons/x.plist"])
        let verbs = Set([off.required[0], off.bestEffort[0], on.required[0], on.bestEffort[0]])
        #expect(verbs.isDisjoint(with: ["remove", "unload", "kill", "submit"]))
    }

    @Test func realSystemDaemonsValidateOrAreRefusedSafely() throws {
        // Read-only check against this Mac's /Library/LaunchDaemons: every third-party plist either
        // validates to its own Label or is refused; nothing is changed.
        let dir = SystemJobControl.Kind.daemon.directory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".plist") {
            let path = dir + "/" + name
            if let label = try? SystemJobControl.validate(plistPath: path, kind: .daemon) {
                #expect(!label.hasPrefix("com.apple."))
                let job = NSDictionary(contentsOfFile: path)
                #expect(job?["Label"] as? String == label)
            }
        }
    }
}
