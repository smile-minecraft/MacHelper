import Darwin
import Foundation
import Testing
@testable import DiskScan

/// Builds a fixture tree in the temporary directory (APFS on the boot volume).
private final class Fixture {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appending(path: "diskscan-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appending(path: "a/b/c"), withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: root) }

    @discardableResult
    func file(_ rel: String, bytes: Int) throws -> URL {
        let url = root.appending(path: rel)
        // Random content so APFS cannot compress or dedupe it.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: url)
        return url
    }

    func allocated(_ url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }
}

@Suite struct DiskScannerTests {
    @Test func sizesAndStructure() throws {
        let fx = try Fixture()
        let big1 = try fx.file("big1.bin", bytes: 3 << 20)
        let big2 = try fx.file("a/b/big2.bin", bytes: 2 << 20)
        var smallTotal: UInt64 = 0
        for i in 0..<20 { smallTotal += fx.allocated(try fx.file("a/small\(i).txt", bytes: 3000)) }

        let result = try DiskScanner().scan(fx.root)
        let root = result.root

        #expect(result.progress.files == 22)
        #expect(root.fileCount == 22)
        #expect(root.size == fx.allocated(big1) + fx.allocated(big2) + smallTotal)

        // Large files are nodes, small ones are aggregated in their directory.
        let a = try #require(root.children.first { $0.name == "a" })
        #expect(a.smallFilesCount == 20)
        #expect(a.smallFilesSize == smallTotal)
        #expect(root.largestFiles(limit: 5).map(\.name) == ["big1.bin", "big2.bin"])

        // Children sorted largest first; paths reconstruct correctly.
        #expect(root.children.first?.name == "big1.bin")
        let b = try #require(a.children.first { $0.name == "b" })
        #expect(b.path == fx.root.resolvingSymlinksInPath().appending(path: "a/b").path)
    }

    @Test func hardLinksCountedOnce() throws {
        let fx = try Fixture()
        let original = try fx.file("orig.bin", bytes: 2 << 20)
        try fx.fm.linkItem(at: original, to: fx.root.appending(path: "a/link.bin"))

        let root = try DiskScanner().scan(fx.root).root
        #expect(root.fileCount == 2)
        #expect(root.size == fx.allocated(original))
    }

    @Test func clonesCountedOnce() throws {
        let fx = try Fixture()
        let original = try fx.file("orig.bin", bytes: 4 << 20)
        let clone = fx.root.appending(path: "a/clone.bin")
        // clonefile(2): shares all blocks with the original on APFS.
        guard clonefile(original.path, clone.path, 0) == 0 else {
            print("clonefile unsupported here (errno \(errno)); skipping")
            return
        }
        let root = try DiskScanner().scan(fx.root).root
        let naive = fx.allocated(original) * 2
        #expect(root.size < naive)
        #expect(root.size >= fx.allocated(original))
    }

    @Test func symlinksNotFollowed() throws {
        let fx = try Fixture()
        try fx.file("a/target.bin", bytes: 2 << 20)
        try fx.fm.createSymbolicLink(at: fx.root.appending(path: "loop"), withDestinationURL: fx.root)
        let result = try DiskScanner().scan(fx.root)
        // The symlink is one (tiny) file; the loop is not descended.
        #expect(result.progress.files == 2)
        #expect(result.progress.directories == 4) // root, a, a/b, a/b/c
    }

    @Test func unreadableDirectoryIsReportedNotFatal() throws {
        let fx = try Fixture()
        try fx.file("a/b/c/x.bin", bytes: 2 << 20)
        let locked = fx.root.appending(path: "a/b")
        chmod(locked.path, 0)
        defer { chmod(locked.path, 0o755) }
        let result = try DiskScanner().scan(fx.root)
        #expect(result.progress.unreadableDirectories == 1)
        let b = result.root.children.first { $0.name == "a" }?.children.first { $0.name == "b" }
        #expect(b?.readError == EACCES)
    }
}

@Suite struct ChartLayoutTests {
    private func tree() throws -> (Fixture, DiskNode) {
        let fx = try Fixture()
        try fx.file("a/big.bin", bytes: 6 << 20)
        try fx.file("a/b/mid.bin", bytes: 3 << 20)
        try fx.file("c.bin", bytes: 2 << 20)
        for i in 0..<5 { try fx.file("tiny\(i).txt", bytes: 2000) }
        return (fx, try DiskScanner().scan(fx.root).root)
    }

    @Test func sunburstCoversCircleAndHitTests() throws {
        let (fx, root) = try tree()
        _ = fx
        let layout = SunburstLayout(center: root)
        let ring1 = layout.arcs.filter { $0.depth == 1 }
        #expect(abs((ring1.map { $0.end - $0.start }.reduce(0, +)) - 1) < 0.01)
        #expect(ring1.first?.node?.name == "a")
        // a/ holds ~75 % of the space, so 10 % around the circle on ring 1 is "a".
        #expect(layout.arc(atFraction: 0.1, depth: 1)?.node?.name == "a")
        #expect(layout.arc(atFraction: 0.1, depth: 2)?.node?.name == "big.bin")
        #expect(layout.arc(atFraction: 0.1, depth: 9) == nil)
    }

    @Test func tinyItemsMergeIntoOther() throws {
        let (fx, root) = try tree()
        _ = fx
        let layout = SunburstLayout(center: root, minFraction: 0.2)
        let others = layout.arcs.filter(\.isOther)
        #expect(!others.isEmpty)
        #expect(others.contains { $0.depth == 1 && $0.otherCount >= 5 })
    }

    @Test func polarConversion() {
        let size = CGSize(width: 200, height: 200)
        let top = SunburstLayout.polar(CGPoint(x: 100, y: 10), in: size, maxDepth: 4)
        #expect(top?.depth == 4)
        #expect(abs((top?.fraction ?? 1) - 0) < 0.01)
        let right = SunburstLayout.polar(CGPoint(x: 190, y: 100), in: size, maxDepth: 4)
        #expect(abs((right?.fraction ?? 0) - 0.25) < 0.01)
        #expect(SunburstLayout.polar(CGPoint(x: 100, y: 100), in: size, maxDepth: 4)?.depth == 0)
        #expect(SunburstLayout.polar(CGPoint(x: 0, y: 0), in: size, maxDepth: 4) == nil)
    }

    @Test func treemapFillsBounds() throws {
        let (fx, root) = try tree()
        _ = fx
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let cells = TreemapLayout(center: root, bounds: bounds).cells.filter { $0.depth == 1 }
        let area = cells.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        #expect(abs(area - 120_000) < 600)
        #expect(cells.allSatisfy { bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.rect) })
    }

    @Test func detachUpdatesTotals() throws {
        let (fx, root) = try tree()
        _ = fx
        let total = root.size
        let big = try #require(root.descendant(atPath: root.path + "/a/big.bin"))
        let bigSize = big.size
        big.detachFromTree()
        #expect(root.size == total - bigSize)
        #expect(root.descendant(atPath: root.path + "/a/big.bin") == nil)
    }
}

@Suite struct DuplicateFinderTests {
    @Test func findsCopiesAndIgnoresHardLinks() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Data((0..<300_000).map { UInt8($0 % 251) })
        var b = a; b[150_000] ^= 0xFF                  // same size, same head/tail, different middle
        try a.write(to: dir.appending(path: "a.bin"))
        try a.write(to: dir.appending(path: "a-copy.bin"))
        try b.write(to: dir.appending(path: "b.bin"))
        try FileManager.default.linkItem(at: dir.appending(path: "a.bin"), to: dir.appending(path: "a-link.bin"))
        let paths = ["a.bin", "a-copy.bin", "b.bin", "a-link.bin"].map { dir.appending(path: $0).path }
        let groups = DuplicateFinder.find(paths: paths, minSize: 1000)
        #expect(groups.count == 1)
        #expect(groups[0].files.count == 2)          // a + copy (hard link collapsed into a)
        #expect(groups[0].reclaimable == 300_000)
    }

    @Test func snapshotChangesKeepDeepestCause() throws {
        let old = try JSONDecoder().decode(ScanSnapshot.self, from: Data(#"{"root":"/r","date":0,"sizes":{"/r":1000000000,"/r/a":600000000,"/r/a/b":500000000}}"#.utf8))
        let new = try JSONDecoder().decode(ScanSnapshot.self, from: Data(#"{"root":"/r","date":0,"sizes":{"/r":2000000000,"/r/a":1600000000,"/r/a/b":1500000000,"/r/c":100000000}}"#.utf8))
        let changes = new.changes(since: old)
        #expect(changes.map(\.path) == ["/r/a/b", "/r/c"])
        #expect(changes[0].delta == 1_000_000_000)
    }

    @Test func kinds() {
        #expect(FileKind.of("movie.MOV") == .video)
        #expect(FileKind.of("Installer.dmg") == .diskImage)
        #expect(FileKind.of("README") == .other)
    }
}
