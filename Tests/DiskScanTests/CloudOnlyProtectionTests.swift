import CSystemBridge
import Darwin
import Foundation
import Testing
@testable import DiskScan

/// Scratch tree in the temporary directory, cleaned up on dealloc.
private final class TempTree {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appending(path: "dataless-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: root) }
}

@Suite struct CloudOnlyProtectionTests {
    @Test func localFilesScanAndDuplicateNormally() throws {
        let fx = try TempTree()
        // Two identical 3 MB copies: detected as duplicates, counted as kept file nodes.
        let data = Data((0..<3_000_000).map { UInt8($0 % 241) })
        try data.write(to: fx.root.appending(path: "one.bin"))
        try data.write(to: fx.root.appending(path: "two.bin"))

        let result = try DiskScanner().scan(fx.root)
        #expect(result.progress.files == 2)
        #expect(result.progress.cloudOnlyDirectories == 0)

        let found = try DuplicateFinder.findChecked(paths: [fx.root.appending(path: "one.bin").path,
                                                            fx.root.appending(path: "two.bin").path],
                                                    minSize: 1000)
        #expect(found.groups.count == 1)
        #expect(found.groups[0].files.count == 2)
        #expect(found.cloudOnlyFiles == 0)
        #expect(found.unreadableFiles == 0)
    }

    @Test func datalessFolderIsSkippedAndNeverOpened() throws {
        let fx = try TempTree()
        let scanner = DiskScanner()
        var rootStat = stat()
        #expect(lstat(fx.root.path, &rootStat) == 0)
        var calls = 0
        // Fake the kernel boundary: report one cloud-only folder and one local 4 MB file.
        // A real dataless folder cannot be created from user space, so the attribute source is substituted.
        scanner.directoryEnumeration = { _, out, _ in
            calls += 1
            guard calls == 1 else { return 0 }
            var folder = MHDirEntry()
            setEntryName(&folder, name: "cloud-only-folder")
            folder.objType = 2 // VDIR
            folder.flags = UInt32(SF_DATALESS)
            folder.devID = rootStat.st_dev
            folder.linkCount = 1
            folder.hasFileAttrs = 1
            folder.fileID = 9901
            out[0] = folder

            var file = MHDirEntry()
            setEntryName(&file, name: "local.bin")
            file.objType = 1 // VREG
            file.devID = rootStat.st_dev
            file.allocSize = 4 << 20
            file.logicalSize = 4 << 20
            file.linkCount = 1
            file.hasFileAttrs = 1
            file.fileID = 9902
            out[1] = file
            return 2
        }

        let result = try scanner.scan(fx.root)

        #expect(result.progress.cloudOnlyDirectories == 1)
        #expect(result.progress.unreadableDirectories == 1) // results are reported as incomplete
        #expect(result.progress.files == 1)
        let folder = try #require(result.root.children.first { $0.name == "cloud-only-folder" })
        #expect(folder.isDirectory)
        #expect(folder.skippedCloudOnly)
        #expect(folder.readError == 0)
        #expect(result.root.size == 4 << 20)
    }

    @Test func folderListingBlockedByTheKernelIsReported() throws {
        let fx = try TempTree()
        let scanner = DiskScanner()
        scanner.directoryEnumeration = { _, _, _ in
            errno = EDEADLK
            return -1
        }

        let result = try scanner.scan(fx.root)

        #expect(result.progress.cloudOnlyDirectories == 1)
        #expect(result.progress.unreadableDirectories == 1)
        #expect(result.root.skippedCloudOnly)
        #expect(result.root.readError == EDEADLK)
    }

    @Test func unreadableFileIsExcludedFromDuplicateGroups() throws {
        let fx = try TempTree()
        let data = Data((0..<1_500_000).map { UInt8($0 % 251) })
        try data.write(to: fx.root.appending(path: "a.bin"))
        try data.write(to: fx.root.appending(path: "b.bin"))
        let locked = fx.root.appending(path: "c.bin")
        try data.write(to: locked)
        chmod(locked.path, 0)
        defer { chmod(locked.path, 0o600) }
        let result = try DuplicateFinder.findChecked(paths: ["a.bin", "b.bin", "c.bin"].map { fx.root.appending(path: $0).path },
                                                     minSize: 1000)
        #expect(result.groups.count == 1)
        #expect(Set(result.groups[0].files.map(\.path)) == Set([fx.root.appending(path: "a.bin").path,
                                                                fx.root.appending(path: "b.bin").path]))
        #expect(result.cloudOnlyFiles == 0)
        #expect(result.unreadableFiles == 1)
    }
}

private func setEntryName(_ entry: inout MHDirEntry, name: String) {
    withUnsafeMutableBytes(of: &entry.name) { raw in
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let utf8 = Array(name.utf8)
        let n = min(utf8.count, 255)
        for (i, byte) in utf8.prefix(n).enumerated() { bytes[i] = byte }
        bytes[n] = 0
    }
}
