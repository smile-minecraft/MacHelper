import Foundation
import Testing
@testable import Theming

@Suite struct IconPackTests {
    private func temp(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func png(_ url: URL, bytes: Int = 64) throws { try Data(repeating: 0x89, count: bytes).write(to: url) }

    @Test func catalogCoversEveryBuiltInAsset() {
        let assets = ["battery", "cpu", "disk", "empty.box", "empty.clean", "empty.scan", "fans", "gpu", "health", "mascot", "memory",
                      "monitor", "network", "optimize", "overview", "power", "settings", "ssd", "startup", "temperature", "uninstall"]
        for a in assets { #expect(IconCatalog.ids.contains(a), "\(a)") }
        #expect(IconCatalog.ids.contains("app"))
        #expect(IconCatalog.assetName("app") == nil && IconCatalog.assetName("cpu") == "px.cpu")
        #expect(IconCatalog.id(forAssetName: "px.empty.box") == "empty.box" && IconCatalog.id(forAssetName: "cpu") == "cpu")
        #expect(Set(IconCatalog.entries.map(\.id)).count == IconCatalog.entries.count)
    }

    @Test func readsOnlyKnownIconsInSupportedFormats() throws {
        let root = try temp("icons"); defer { try? FileManager.default.removeItem(at: root) }
        let pack = root.appending(path: "Retro")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try png(pack.appending(path: "cpu.png"))
        try png(pack.appending(path: "cpu.svg"))         // svg wins over png
        try png(pack.appending(path: "fans.PNG"))
        try png(pack.appending(path: "notanicon.png"))   // unknown id
        try png(pack.appending(path: "gpu.exe"))         // unsupported
        try png(pack.appending(path: "memory.png"), bytes: IconPackLibrary.maxFileSize + 1)
        try Data(#"{"name": "Retro Pack", "pixelated": true, "extra": 1}"#.utf8).write(to: pack.appending(path: "pack.json"))

        let packs = IconPackLibrary(root: root).packs()
        let p = try #require(packs.first)
        #expect(packs.count == 1)
        #expect(p.name == "Retro Pack" && p.pixelated == true)
        #expect(Set(p.files.keys) == ["cpu", "fans"])
        #expect(p.files["cpu"]?.pathExtension == "svg")
    }

    @Test func importCopiesOnlyIconFilesIntoAFreshFolder() throws {
        let root = try temp("icons"), src = try temp("My Pack")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: src) }
        try png(src.appending(path: "cpu.png"))
        try png(src.appending(path: "script.sh"))
        try FileManager.default.createDirectory(at: src.appending(path: "sub"), withIntermediateDirectories: true)
        try png(src.appending(path: "sub/fans.png"))

        let lib = IconPackLibrary(root: root)
        let first = try lib.importPack(from: src)
        let second = try lib.importPack(from: src)
        #expect(first.id != second.id, "a second import gets its own folder")
        let copied = try FileManager.default.contentsOfDirectory(atPath: first.directory.path)
        #expect(copied == ["cpu.png"], "only icon files are copied; scripts and subfolders are not")
        try lib.deletePack(id: first.id)
        #expect(lib.packs().map(\.id) == [second.id])
    }

    @Test func importRejectsFoldersWithoutIcons() throws {
        let root = try temp("icons"), src = try temp("empty")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: src) }
        try png(src.appending(path: "readme.txt"))
        #expect(throws: IconPackLibrary.PackError.self) { try IconPackLibrary(root: root).importPack(from: src) }
        #expect(throws: IconPackLibrary.PackError.self) { try IconPackLibrary(root: root).importPack(from: src.appending(path: "readme.txt")) }
    }

    @Test func overridesReplaceAndRestoreSingleIcons() throws {
        let root = try temp("icons"), src = try temp("pics")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: src) }
        let lib = IconPackLibrary(root: root)
        try png(src.appending(path: "mine.png"))
        try png(src.appending(path: "mine.jpg"))
        try lib.setOverride("cpu", from: src.appending(path: "mine.png"))
        try lib.setOverride("cpu", from: src.appending(path: "mine.jpg"))   // replaces, never two files for one id
        #expect(lib.overrides()?.files["cpu"]?.pathExtension == "jpg")
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.overridesDirectory.path).count == 1)
        #expect(lib.packs().isEmpty, "the overrides folder is not listed as a pack")
        #expect(throws: IconPackLibrary.PackError.unknownIcon("nope")) { try lib.setOverride("nope", from: src.appending(path: "mine.png")) }
        try png(src.appending(path: "x.exe"))
        #expect(throws: IconPackLibrary.PackError.self) { try lib.setOverride("cpu", from: src.appending(path: "x.exe")) }
        try lib.removeOverride("cpu")
        #expect(lib.overrides()?.files["cpu"] == nil)
    }

    @Test func folderNamesAreSafe() {
        #expect(IconPackLibrary.safeFolderName("../../etc") == "-..-etc")
        #expect(IconPackLibrary.safeFolderName("_overrides") == "overrides")
        #expect(IconPackLibrary.safeFolderName("...") == "Icons")
        #expect(IconPackLibrary.safeFolderName("像素 Pack_1") == "像素 Pack_1")
        #expect(!IconPackLibrary.safeFolderName("a/b").contains("/"))
    }

    @Test func iconSetSettingRoundTrips() throws {
        var s = AppearanceSettings()
        #expect(s.iconSet == .pixel)
        s.iconSet = .pack("Retro")
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(s)).iconSet == .pack("Retro"))
        let old = try JSONDecoder().decode(AppearanceSettings.self, from: Data(#"{"style":"pixel"}"#.utf8))
        #expect(old.iconSet == .pixel, "settings saved before icon sets existed still load")
    }
}
