import Foundation
import Testing
@testable import CleanEngine

private func app(_ name: String, _ id: String, path: String? = nil, team: String? = nil) -> InstalledApp {
    InstalledApp(name: name, bundleID: id, version: nil, path: path ?? "/Applications/\(name).app", size: 0, isAppStore: false,
                 lastUsed: nil, isRunning: false, teamID: team, protectedReason: nil)
}

@Suite struct LeftoverFinderTests {
    @Test func normalizationIgnoresCaseSpacesAndPunctuation() {
        #expect(LeftoverFinder.normalize("Hermes Agent") == "hermesagent")
        #expect(LeftoverFinder.normalize("hermes-agent") == "hermesagent")
        #expect(LeftoverFinder.normalize("Hermes_Agent") == "hermesagent")
    }

    @Test func baseNameDropsChannelAndVersion() {
        #expect(LeftoverFinder.baseName("Zed Nightly") == "Zed")
        #expect(LeftoverFinder.baseName("Bartender 6") == "Bartender")
        #expect(LeftoverFinder.baseName("Firefox Developer Edition") == "Firefox")
        #expect(LeftoverFinder.baseName("Hermes") == "Hermes")
    }

    @Test func versionedNames() {
        #expect(LeftoverFinder.isVersioned("anki2", of: "anki"))
        #expect(LeftoverFinder.isVersioned("sibelius2024", of: "sibelius"))
        #expect(!LeftoverFinder.isVersioned("ankiprogramfiles", of: "anki"))
        #expect(!LeftoverFinder.isVersioned("zed2", of: "zed"))          // too short to be safe
    }

    @Test func bundleIDAppearsAsDottedPart() {
        let f = LeftoverFinder(app: app("Foo", "com.foo.App"), otherApps: [])
        #expect(f.idEvidence("com.foo.app") == .bundleID)
        #expect(f.idEvidence("com.foo.app.shipit") == .bundleID)
        #expect(f.idEvidence("group.com.foo.app") == .bundleID)
        #expect(f.idEvidence("abcde12345.com.foo.app.shared") == .bundleID)
        #expect(f.idEvidence("com.foo.application") == nil)
        #expect(f.idEvidence("com.foo") == nil)
    }

    @Test func longerIDOfAnotherAppIsNotOurs() {
        let f = LeftoverFinder(app: app("Foo", "com.foo.App"), otherApps: [app("Foo Pro", "com.foo.App.Pro")])
        #expect(f.idEvidence("com.foo.app.pro") == nil)
        #expect(f.idEvidence("com.foo.app.pro.plist") == nil)
        #expect(f.idEvidence("com.foo.app.helper") == .bundleID)
    }

    @Test func familyIDFromVariantSuffix() {
        let f = LeftoverFinder(app: app("Hermes", "com.nousresearch.hermes.setup"), otherApps: [])
        #expect(f.familyIDs == ["com.nousresearch.hermes"])
        #expect(f.idEvidence("com.nousresearch.hermes") == .family)
        #expect(f.idEvidence("com.nousresearch.hermes.setup") == .bundleID)
        // The parent is shared when another installed app lives under it.
        let g = LeftoverFinder(app: app("Hermes", "com.nousresearch.hermes.setup"),
                               otherApps: [app("Hermes Studio", "com.nousresearch.hermes.studio")])
        #expect(g.familyIDs.isEmpty)
    }

    @Test func siblingBuildKeepsNameFolders() {
        let nightly = LeftoverFinder(app: app("Zed Nightly", "dev.zed.Zed-Nightly"), otherApps: [app("Zed", "dev.zed.Zed")])
        #expect(!nightly.names.contains("zed"))
        #expect(nightly.names.contains("zednightly"))
        let alone = LeftoverFinder(app: app("Zed Nightly", "dev.zed.Zed-Nightly"), otherApps: [])
        #expect(alone.names.contains("zed"))
    }

    @Test func commonNamesNeverMatch() {
        let f = LeftoverFinder(app: app("Code", "com.microsoft.VSCode"), otherApps: [])
        #expect(!f.names.contains("code"))
        #expect(f.match("Code", [.name]) == nil)
    }

    @Test func vendorOnlyWhenUnique() {
        let alone = LeftoverFinder(app: app("Hermes", "com.nousresearch.hermes.setup"), otherApps: [])
        #expect(alone.vendorUnique)
        #expect(alone.match("Nous Research", [.vendorFolder]) == .vendor)
        let shared = LeftoverFinder(app: app("Edge", "com.microsoft.edgemac"), otherApps: [app("Teams", "com.microsoft.teams2")])
        #expect(!shared.vendorUnique)
        #expect(shared.match("Microsoft", [.vendorFolder]) == nil)
    }

    @Test func crashReportsByExecutableOrName() {
        let f = LeftoverFinder(app: app("Hermes", "com.nousresearch.hermes.setup"), otherApps: [])
        #expect(f.match("Hermes-2026-10-24-120000.ips", [.crash]) == .name)
        #expect(f.match("Hermes_533B7E6E-F11A-5DC6-A5E9-432922B5D112.plist", [.crash]) == .name)
        #expect(f.match("Hermit-2026.ips", [.crash]) == nil)
    }

    @Test func independentCLIIsKept() {
        let f = LeftoverFinder(app: app("Claude", "com.anthropic.claudefordesktop"), otherApps: [])
        #expect(f.independentOwner(of: MacHelperPaths.home.path + "/.claude", name: "claude") != nil)
    }

    @Test func homeDataBoundaries() {
        let h = "/Users/x"
        #expect(RemovalArea.isRemovableHomeData("/Users/x/.hermes", home: h))
        #expect(RemovalArea.isRemovableHomeData("/Users/x/.config/hermes", home: h))
        #expect(RemovalArea.isRemovableHomeData("/Users/x/.local/bin/hermes", home: h))
        #expect(!RemovalArea.isRemovableHomeData("/Users/x/.ssh", home: h))
        #expect(!RemovalArea.isRemovableHomeData("/Users/x/.config", home: h))
        #expect(!RemovalArea.isRemovableHomeData("/Users/x/hermes", home: h))          // not a dot-folder
        #expect(!RemovalArea.isRemovableHomeData("/Users/x/.hermes/sub", home: h))
        #expect(!RemovalArea.isRemovableHomeData("/Users/x/Documents/.hermes", home: h))
    }

    @Test func removalAreas() {
        let h = MacHelperPaths.home.path
        #expect(RemovalArea(path: h + "/Library/Caches/com.foo.app") == .library)
        #expect(RemovalArea(path: h + "/Library/Nous Research") == .libraryRoot)
        #expect(RemovalArea(path: h + "/Library/Caches") == nil)
        #expect(RemovalArea(path: h + "/Library/Keychains") == nil)
        #expect(RemovalArea(path: h + "/.hermes") == .home)
        #expect(RemovalArea(path: h + "/Documents") == nil)
        #expect(RemovalArea(path: "/Library/Caches/x") == nil)
        if let c = RemovalArea.darwinUserDirs.first { #expect(RemovalArea(path: c + "/com.foo.app") == .darwin) }
        // Protected paths stay protected inside an allowed area.
        #expect(RemovalArea.library.safety.check(h + "/Library/Application Support/MacHelper") != .allowed)
    }

    @Test func extensionsAreStrippedOnlyWhenKnown() {
        #expect(LeftoverFinder.stripExtension("com.foo.app.plist") == "com.foo.app")
        #expect(LeftoverFinder.stripExtension("hermes.savedstate") == "hermes")
        #expect(LeftoverFinder.stripExtension("com.foo.bar") == "com.foo.bar")
    }

    @Test func uuidDetection() {
        #expect(LeftoverFinder.isUUID("0AFD3042-43E7-465B-99C7-6BC3AC77863D"))
        #expect(!LeftoverFinder.isUUID("com.foo.app"))
    }
}
