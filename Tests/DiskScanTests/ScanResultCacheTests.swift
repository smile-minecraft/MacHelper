import Darwin
import Foundation
import Testing
@testable import DiskScan

/// Scratch tree and cache directory, both under one temporary base so tests stay isolated.
private final class Scratch {
    let base: URL
    let cacheDirectory: URL
    let fm = FileManager.default

    init() throws {
        base = fm.temporaryDirectory.appending(path: "scanresultcache-\(UUID().uuidString)")
        cacheDirectory = base.appending(path: "cache")
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: base) }

    func tree(_ name: String) throws -> URL {
        let dir = base.appending(path: name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func file(_ rel: String, bytes: Int, under root: URL) throws -> URL {
        let url = root.appending(path: rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: url)
        return url
    }

    func scanOptions() -> ScanOptions {
        var options = ScanOptions()
        options.keepFilesLargerThan = 512   // keep small fixtures cheap
        return options
    }

    func scan(at root: URL) throws -> ScanResult {
        try DiskScanner(options: scanOptions()).scan(root)
    }

    func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }
}

/// Recursively compares a live-scanned tree with its restored copy.
private func expectNodesEqual(_ original: DiskNode, _ restored: DiskNode) {
    #expect(restored.name == original.name)
    #expect(restored.isDirectory == original.isDirectory)
    #expect(restored.restoredFromCache)
    #expect(restored.size == original.size)
    #expect(restored.fileCount == original.fileCount)
    #expect(restored.smallFilesSize == original.smallFilesSize)
    #expect(restored.smallFilesCount == original.smallFilesCount)
    #expect(restored.readError == original.readError)
    #expect(abs(restored.modified.timeIntervalSince(original.modified)) < 0.001)
    #expect(restored.path == original.path)
    #expect(restored.children.count == original.children.count)
    for (o, r) in zip(original.children, restored.children) { expectNodesEqual(o, r) }
}

private func allNodes(_ root: DiskNode) -> [DiskNode] {
    var nodes: [DiskNode] = []
    root.forEach { nodes.append($0) }
    return nodes
}

@Suite struct ScanResultCacheTests {

    @Test(.enabled(if: getuid() != 0))
    func roundTripPreservesTreeAndScanTime() throws {
        let fx = try Scratch()
        let root = try fx.tree("fixture")
        try fx.file("top.bin", bytes: 4096, under: root)
        try fx.file("plain.txt", bytes: 128, under: root)   // below the keep threshold: folded into smallFiles
        try fx.file("檔案-掃描-測試.bin", bytes: 2048, under: root)
        try fx.file("a/sub.bin", bytes: 4096, under: root)
        try fx.file("a/deep/deep.bin", bytes: 6144, under: root)
        try fx.file("a/deep/" + String(repeating: "longname-", count: 20) + ".bin", bytes: 1024, under: root)
        try fx.file("locked/hidden.bin", bytes: 2048, under: root)
        try fx.fm.createDirectory(at: root.appending(path: "cloud-only-folder"), withIntermediateDirectories: true)
        let lockedPath = root.appending(path: "locked").path
        chmod(lockedPath, 0)
        defer { chmod(lockedPath, 0o755) }

        let scannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let scan = try fx.scan(at: root)
        #expect(scan.progress.unreadableDirectories == 1)
        // Simulate a skipped cloud-only folder on the scanned tree; no real cloud data is involved.
        let cloudFolder = try #require(scan.root.children.first { $0.name == "cloud-only-folder" })
        cloudFolder.skippedCloudOnly = true

        let snapshot = ScanResultSnapshot(result: scan, scannedAt: scannedAt)
        let cache = ScanResultCache(directory: fx.cacheDirectory)
        try cache.save(snapshot)

        let restored = try #require(cache.load(rootPath: fx.resolved(root)))
        #expect(restored.schemaVersion == ScanResultSnapshot.currentSchemaVersion)
        #expect(restored.rootPath == fx.resolved(root))
        #expect(abs(restored.scannedAt.timeIntervalSince(scannedAt)) < 0.001)
        #expect(abs(restored.elapsed - scan.elapsed) < 0.001)
        #expect(restored.progress.files == scan.progress.files)
        #expect(restored.progress.directories == scan.progress.directories)
        #expect(restored.progress.bytes == scan.progress.bytes)
        #expect(restored.progress.unreadableDirectories == scan.progress.unreadableDirectories)

        let tree = try #require(restored.rebuildTree())
        #expect(!scan.root.restoredFromCache)
        let restoredCloudFolder = try #require(tree.children.first { $0.name == "cloud-only-folder" })
        #expect(restoredCloudFolder.skippedCloudOnly)
        expectNodesEqual(scan.root, tree)
    }

    @Test func differentLocationsDoNotOverwriteEachOther() throws {
        let fx = try Scratch()
        let rootA = try fx.tree("loc-a"), rootB = try fx.tree("loc-b")
        try fx.file("a.bin", bytes: 4096, under: rootA)
        try fx.file("b.bin", bytes: 8192, under: rootB)
        let cache = ScanResultCache(directory: fx.cacheDirectory)
        let scanA = try fx.scan(at: rootA), scanB = try fx.scan(at: rootB)
        try cache.save(ScanResultSnapshot(result: scanA))
        try cache.save(ScanResultSnapshot(result: scanB))

        let loadedA = try #require(cache.load(rootPath: fx.resolved(rootA)))
        let loadedB = try #require(cache.load(rootPath: fx.resolved(rootB)))
        #expect(loadedA.rootPath == fx.resolved(rootA))
        #expect(loadedB.rootPath == fx.resolved(rootB))
        #expect(loadedA.root.size != 0)
        #expect(loadedB.root.size != 0)
    }

    @Test func clearRemovesOnlyThatLocation() throws {
        let fx = try Scratch()
        let rootA = try fx.tree("loc-a"), rootB = try fx.tree("loc-b")
        try fx.file("a.bin", bytes: 4096, under: rootA)
        try fx.file("b.bin", bytes: 8192, under: rootB)
        let cache = ScanResultCache(directory: fx.cacheDirectory)
        try cache.save(ScanResultSnapshot(result: try fx.scan(at: rootA)))
        try cache.save(ScanResultSnapshot(result: try fx.scan(at: rootB)))

        try cache.clear(rootPath: fx.resolved(rootA))

        #expect(cache.load(rootPath: fx.resolved(rootA)) == nil)
        let loadedB = try #require(cache.load(rootPath: fx.resolved(rootB)))
        #expect(loadedB.rootPath == fx.resolved(rootB))
    }

    @Test func clearingMissingCacheDoesNotFail() throws {
        let fx = try Scratch()
        let cache = ScanResultCache(directory: fx.cacheDirectory)
        try cache.clear(rootPath: "/no/such/location/anywhere")
    }

    @Test func damagedCacheFilesAreRejected() throws {
        let fx = try Scratch()
        let root = try fx.tree("fixture")
        try fx.file("a.bin", bytes: 4096, under: root)
        let cache = ScanResultCache(directory: fx.cacheDirectory)
        let snapshot = ScanResultSnapshot(result: try fx.scan(at: root), scannedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try cache.save(snapshot)

        // First prove the valid cache can be read back, then damage it in turn.
        let valid = try #require(cache.load(rootPath: fx.resolved(root)))
        #expect(valid.schemaVersion == ScanResultSnapshot.currentSchemaVersion)
        #expect(valid.rootPath == fx.resolved(root))
        #expect(abs(valid.scannedAt.timeIntervalSince(snapshot.scannedAt)) < 0.001)

        let file = cache.fileURL(for: fx.resolved(root))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let encoded = try encoder.encode(snapshot)
        let raw = String(decoding: encoded, as: UTF8.self)

        let variants: [(String, Data)] = [
            ("garbage bytes", Data("definitely not json".utf8)),
            ("empty file", Data()),
            ("rootPath pointing elsewhere", Data(raw.replacingOccurrences(of: snapshot.rootPath, with: "/somewhere/else").utf8)),
            ("unsupported schemaVersion", Data(raw.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":999"#).utf8)),
        ]
        for (name, data) in variants {
            try data.write(to: file, options: .atomic)
            #expect(cache.load(rootPath: fx.resolved(root)) == nil, "expected rejection for: \(name)")
        }
    }

    @Test(.enabled(if: getuid() != 0))
    func failedSaveKeepsPreviousSnapshot() throws {
        let fx = try Scratch()
        let root = try fx.tree("fixture")
        try fx.file("a.bin", bytes: 4096, under: root)
        let cache = ScanResultCache(directory: fx.cacheDirectory)
        let scan = try fx.scan(at: root)
        let scannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try cache.save(ScanResultSnapshot(result: scan, scannedAt: scannedAt))

        chmod(fx.cacheDirectory.path, 0o500)   // read-only directory: saving must fail, not corrupt
        defer { chmod(fx.cacheDirectory.path, 0o700) }
        #expect(throws: (any Error).self) {
            try cache.save(ScanResultSnapshot(result: scan, scannedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        }

        chmod(fx.cacheDirectory.path, 0o700)
        let loaded = try #require(cache.load(rootPath: fx.resolved(root)))
        #expect(abs(loaded.scannedAt.timeIntervalSince(scannedAt)) < 0.001)
    }

    @Test func cancelledScanDoesNotDisturbSavedSnapshot() throws {
        let fx = try Scratch()
        let root = try fx.tree("fixture")
        try fx.file("a.bin", bytes: 4096, under: root)

        // Baseline: a completed scan is saved as the "previous result".
        let previous = try fx.scan(at: root)
        let scannedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ScanResultSnapshot(result: previous, scannedAt: scannedAt)
        let cache = ScanResultCache(directory: fx.cacheDirectory)
        try cache.save(snapshot)

        // Change-comparison data lives apart from this cache; plant a sentinel copy of it.
        let changeFile = fx.base.appending(path: "change-snapshot.json")
        let changeEncoder = JSONEncoder()
        changeEncoder.dateEncodingStrategy = .iso8601
        let changeBytes = try changeEncoder.encode(ScanSnapshot(root: previous.root))
        try changeBytes.write(to: changeFile)

        // Record the previous snapshot's files and bytes before the cancelled save is attempted.
        let cacheFile = cache.fileURL(for: fx.resolved(root))
        let filesBefore = try fx.fm.contentsOfDirectory(atPath: fx.cacheDirectory.path).sorted()
        let bytesBefore = fx.fm.fileExists(atPath: cacheFile.path) ? try Data(contentsOf: cacheFile) : nil

        // A scan that ends cancelled must be refused by the persistence entry point itself.
        let scanner = DiskScanner(options: fx.scanOptions())
        scanner.cancel()
        let cancelled = try scanner.scan(root)
        #expect(cancelled.cancelled)
        #expect(throws: ScanCacheError.cancelledScan) {
            try cache.save(result: cancelled, scannedAt: Date(timeIntervalSince1970: 1_800_000_000))
        }

        // The refusal must not touch anything: sentinel intact, no stray files and no changed bytes.
        #expect(try Data(contentsOf: changeFile) == changeBytes)
        #expect(try fx.fm.contentsOfDirectory(atPath: fx.cacheDirectory.path).sorted() == filesBefore)
        if let bytesBefore {
            #expect(try Data(contentsOf: cacheFile) == bytesBefore)
        }

        // The previous snapshot is still the one on record (fails until save/load are implemented).
        let loaded = try #require(cache.load(rootPath: fx.resolved(root)))
        #expect(abs(loaded.scannedAt.timeIntervalSince(scannedAt)) < 0.001)
    }

    @Test func restoredTreeRefusesRemovalAndDuplicateScan() throws {
        let fx = try Scratch()
        let root = try fx.tree("fixture")
        try fx.file("a/data.bin", bytes: 4096, under: root)
        let scan = try fx.scan(at: root)
        let cache = ScanResultCache(directory: fx.cacheDirectory)
        try cache.save(ScanResultSnapshot(result: scan))

        let restored = try #require(cache.load(rootPath: fx.resolved(root)))
        let tree = try #require(restored.rebuildTree())

        #expect(!ScanCacheSafety.isLiveScan(tree))
        var fileNode: DiskNode?
        tree.forEach { if !$0.isDirectory { fileNode = $0 } }
        let file = try #require(fileNode)
        #expect(!ScanCacheSafety.isLiveScan(file))

        // Callers gate their own work: nothing may run when the tree is not a live scan.
        var contentReadCalls = 0
        if ScanCacheSafety.isLiveScan(tree) {
            tree.forEach { if !$0.isDirectory { contentReadCalls += 1 } }
        }
        #expect(contentReadCalls == 0)
    }

    @Test func freshScanAuthorizesRemovalAndDuplicateScan() throws {
        let fx = try Scratch()
        let root = try fx.tree("fixture")
        try fx.file("a/data.bin", bytes: 4096, under: root)
        let scan = try fx.scan(at: root)

        #expect(ScanCacheSafety.isLiveScan(scan.root))
        var contentReadCalls = 0
        if ScanCacheSafety.isLiveScan(scan.root) {
            scan.root.forEach { if !$0.isDirectory { contentReadCalls += 1 } }
        }
        #expect(contentReadCalls > 0)
    }

    @Test func cacheLivesApartFromChangeComparisonSnapshots() throws {
        let fx = try Scratch()
        let cache = ScanResultCache(directory: fx.cacheDirectory)
        #expect(ScanResultCache.defaultDirectoryName == "scan-results")
        #expect(ScanSnapshot.directory.lastPathComponent == "scans")
        #expect(cache.directory != ScanSnapshot.directory)
    }

    @Test(.enabled(if: getuid() != 0))
    func cacheIsStoredOwnerOnly() throws {
        let fx = try Scratch()
        let root = try fx.tree("fixture")
        try fx.file("a/data.bin", bytes: 4096, under: root)
        let cache = ScanResultCache(directory: fx.cacheDirectory)
        try cache.save(ScanResultSnapshot(result: try fx.scan(at: root)))

        let file = cache.fileURL(for: fx.resolved(root))
        let fileAttrs = try #require(try? FileManager.default.attributesOfItem(atPath: file.path))
        let dirAttrs = try #require(try? FileManager.default.attributesOfItem(atPath: fx.cacheDirectory.path))
        #expect(fileAttrs[.posixPermissions] as? Int == 0o600)
        #expect(dirAttrs[.posixPermissions] as? Int == 0o700)
    }
}
