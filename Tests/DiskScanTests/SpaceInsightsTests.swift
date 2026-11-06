import Foundation
import Testing
@testable import DiskScan

@Suite struct SpaceInsightsTests {
    let base: URL
    let now = Date()

    init() throws {
        let raw = FileManager.default.temporaryDirectory.appending(path: "insights-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        base = URL(fileURLWithPath: String(cString: realpath(raw.path, nil)))
    }

    @discardableResult
    func file(_ rel: String, bytes: Int, daysOld: Double = 0) throws -> String {
        let u = base.appending(path: rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: u)
        if daysOld > 0 {
            let d = now.addingTimeInterval(-daysOld * 86_400)
            try FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: u.path)
        }
        return u.path
    }

    func scan() throws -> DiskNode {
        var o = ScanOptions()
        o.keepFilesLargerThan = 1000
        return try DiskScanner(options: o).scan(base).root
    }

    var options: SpaceInsights.Options {
        var o = SpaceInsights.Options()
        o.minFileSize = 50_000
        o.largeCache = 200_000
        o.largeLogs = 100_000
        o.manyFiles = 30
        o.grewBy = 100_000
        return o
    }

    @Test func oldBigFilesAreUnusedUnlessRecentlyOpened() throws {
        try file("Downloads/Xcode.xip", bytes: 120_000, daysOld: 400)
        try file("Movies/trip.mov", bytes: 120_000, daysOld: 400)
        try file("Downloads/new.dmg", bytes: 120_000)
        try file("Downloads/small.zip", bytes: 10_000, daysOld: 400)
        try file("Library/Application Support/App/data.bin", bytes: 120_000, daysOld: 400)
        try file("Pictures/All.photoslibrary/originals/a.heic", bytes: 120_000, daysOld: 400)
        try file(".Trash/x.dmg", bytes: 120_000, daysOld: 400)
        try file("LLM/model-00001.safetensors", bytes: 120_000, daysOld: 400)
        let tree = try scan()
        let r = SpaceInsights.find(in: tree, options: options, now: now) { path in
            path.hasSuffix("/Movies/trip.mov") ? now.addingTimeInterval(-86_400) : nil
        }
        #expect(r.unusedFiles.map(\.path) == [tree.path + "/Downloads/Xcode.xip"])
        #expect(r.unusedFiles.first?.kind == .installer)
        #expect(r.unusedBytes >= 120_000)
    }

    @Test func oversizedCachesLogsAndCrowdedFolders() throws {
        try file("Library/Caches/com.big.app/blob", bytes: 300_000)
        try file("Library/Caches/com.small.app/blob", bytes: 20_000)
        try file("Library/Logs/App/huge.log", bytes: 150_000)
        for i in 0..<40 { try file("Library/Application Support/Chatty/sessions/s\(i).json", bytes: 100) }
        let tree = try scan()
        let r = SpaceInsights.find(in: tree, options: options, now: now) { _ in nil }
        let byPath = Dictionary(uniqueKeysWithValues: r.bloatedFolders.map { ($0.path, $0) })
        let caches = try #require(byPath[tree.path + "/Library/Caches"])
        #expect(caches.reasons == [.largeCache] && caches.largestChild == "com.big.app")
        #expect(byPath[tree.path + "/Library/Logs"]?.reasons == [.largeLogs])
        #expect(byPath[tree.path + "/Library/Application Support/Chatty/sessions"]?.directFiles == 40)
        #expect(r.unusedFiles.isEmpty, "app data under Library is never suggested")
    }

    @Test func growthSinceThePreviousScan() throws {
        try file("Projects/a/keep.bin", bytes: 150_000)
        try file("Projects/b/stable.bin", bytes: 150_000)
        let before = ScanSnapshot(root: try scan(), date: now.addingTimeInterval(-7 * 86_400), depth: 6, minSize: 1)
        try file("Projects/a/more.bin", bytes: 400_000)
        let tree = try scan()
        let r = SpaceInsights.find(in: tree, previous: before, options: options, now: now) { _ in nil }
        let grew = r.bloatedFolders.filter { $0.reasons.contains(.grew) }
        #expect(grew.map(\.path) == [tree.path + "/Projects/a"])
        #expect((grew.first?.grownBy ?? 0) >= 400_000 && grew.first?.since == before.date)
    }

    @Test func kinds() {
        #expect(SpaceInsights.kind("a.DMG") == .diskImage)
        #expect(SpaceInsights.kind("b.tar.gz") == .archive)
        #expect(SpaceInsights.kind("Win.vmdk") == .virtualMachine)
        #expect(SpaceInsights.kind("x.bin") == .other)
    }
}
