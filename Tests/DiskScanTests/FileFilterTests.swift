import Foundation
import Testing
@testable import DiskScan

/// Builds a directory node with the given children and runs the size/count rollup.
private func directory(_ name: String, modified: Date, parent: DiskNode?, rootPath: String? = nil, children: [DiskNode]) -> DiskNode {
    let node = DiskNode(name: name, isDirectory: true, modified: modified, parent: parent, rootPath: rootPath)
    for child in children { child.parent = node }
    node.children = children
    node.finalize()
    return node
}

private func file(_ name: String, size: UInt64, modified: Date, parent: DiskNode?) -> DiskNode {
    let node = DiskNode(name: name, isDirectory: false, modified: modified, parent: parent)
    node.size = size
    return node
}

private func smallTree(now: Date) -> DiskNode {
    let nested = directory("nested", modified: now, parent: nil, children: [
        file("Report.PDF", size: 4_000, modified: now.addingTimeInterval(-40 * 86_400), parent: nil),
        file("notes.txt", size: 2_000, modified: now.addingTimeInterval(-10 * 86_400), parent: nil),
    ])
    let top = directory("Photos", modified: now, parent: nil, children: [
        file("clip.mov", size: 8_000, modified: now.addingTimeInterval(-5 * 86_400), parent: nil),
    ])
    let root = directory("root", modified: now, parent: nil, rootPath: "/fixture", children: [nested, top])
    // `directory` fixes parent links for its own children; roots were built with parent nil by design.
    return root
}

@Suite struct FileFilterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func textMatchesNameCaseInsensitively() {
        let root = smallTree(now: now)
        let filter = FileFilter(text: "report")
        let result = filter.evaluate(in: root, now: now)
        #expect(result.files.map(\.name) == ["Report.PDF"])
    }

    @Test func textMatchesPathCaseInsensitively() {
        let root = smallTree(now: now)
        let inNested = FileFilter(text: "nested/").evaluate(in: root, now: now)
        #expect(inNested.files.map(\.name).sorted() == ["Report.PDF", "notes.txt"])
        let inPhotos = FileFilter(text: "photos/clip").evaluate(in: root, now: now)
        #expect(inPhotos.files.map(\.name) == ["clip.mov"])
        let nowhere = FileFilter(text: "pictures").evaluate(in: root, now: now)
        #expect(nowhere.files.isEmpty)
    }

    @Test func minBytesBoundaryIsInclusive() {
        let root = smallTree(now: now)
        let atBoundary = FileFilter(minBytes: 2_000).evaluate(in: root, now: now)
        #expect(atBoundary.files.map(\.name).sorted() == ["Report.PDF", "clip.mov", "notes.txt"])
        let aboveBoundary = FileFilter(minBytes: 2_001).evaluate(in: root, now: now)
        #expect(aboveBoundary.files.map(\.name).sorted() == ["Report.PDF", "clip.mov"])
    }

    @Test func kindFilterSelectsMatchingKindOnly() {
        let root = smallTree(now: now)
        let documents = FileFilter(kind: .document).evaluate(in: root, now: now)
        #expect(documents.files.map(\.name).sorted() == ["Report.PDF", "notes.txt"])
        let videos = FileFilter(kind: .video).evaluate(in: root, now: now)
        #expect(videos.files.map(\.name) == ["clip.mov"])
    }

    @Test func ageFilterUsesStrictCutoff() {
        let root = smallTree(now: now)
        let older = FileFilter(olderThanDays: 30).evaluate(in: root, now: now)
        #expect(older.files.map(\.name) == ["Report.PDF"])
        let recent = FileFilter(olderThanDays: 3).evaluate(in: root, now: now)
        #expect(recent.files.map(\.name).sorted() == ["Report.PDF", "clip.mov", "notes.txt"])
        // A modification exactly at the cutoff does not count as "older than".
        let exact = DiskNode(name: "exact.pdf", isDirectory: false, modified: now.addingTimeInterval(-30 * 86_400), parent: nil)
        exact.size = 10
        #expect(FileFilter(olderThanDays: 30).matches(exact, now: now) == false)
    }

    @Test func conditionsAreAnded() {
        let root = smallTree(now: now)
        // Matches text and age, but not kind.
        let mismatchKind = FileFilter(text: "report", kind: .video, olderThanDays: 30).evaluate(in: root, now: now)
        #expect(mismatchKind.files.isEmpty)
        // Matches text and kind, but not size.
        let mismatchSize = FileFilter(text: "report", minBytes: 100_000, kind: .document, olderThanDays: 30).evaluate(in: root, now: now)
        #expect(mismatchSize.files.isEmpty)
        // Matches all four.
        let match = FileFilter(text: "report", minBytes: 1_000, kind: .document, olderThanDays: 30).evaluate(in: root, now: now)
        #expect(match.files.map(\.name) == ["Report.PDF"])
    }

    @Test func directoriesNeverMatchButAreReportedAsContaining() {
        let root = smallTree(now: now)
        let filter = FileFilter(text: "report")
        let nested = root.children.first { $0.name == "nested" }!
        #expect(filter.matches(nested, now: now) == false)
        let result = filter.evaluate(in: root, now: now)
        #expect(result.containingFolders.contains(ObjectIdentifier(root)))
        #expect(result.containingFolders.contains(ObjectIdentifier(nested)))
        let photos = root.children.first { $0.name == "Photos" }!
        #expect(!result.containingFolders.contains(ObjectIdentifier(photos)))
        #expect(result.matching == Set(result.files.map(ObjectIdentifier.init)))
    }

    @Test func filesAreRankedBySizeDescending() {
        let root = smallTree(now: now)
        let result = FileFilter().evaluate(in: root, now: now)
        #expect(result.files.map(\.size) == result.files.map(\.size).sorted(by: >))
        #expect(result.files.count == 3)
    }

    @Test func filterIsAppliedBeforeRankingBeyondFiveThousandFiles() {
        // More than 5,000 large videos outrank every document, so a top-N-by-size pre-filter
        // (the previous approach) would contain no documents at all. The filter must run first.
        let videoCount = 6_001
        var videoChildren: [DiskNode] = []
        videoChildren.reserveCapacity(videoCount)
        for i in 0..<videoCount {
            let v = file(String(format: "video-%05d.mov", i), size: UInt64(9_000 - i), modified: now, parent: nil)
            videoChildren.append(v)
        }
        let documents = directory("documents", modified: now, parent: nil, children: [
            file("big.pdf", size: 1_000, modified: now, parent: nil),
            file("mid.pdf", size: 900, modified: now, parent: nil),
            file("small.pdf", size: 800, modified: now, parent: nil),
        ])
        let videos = directory("videos", modified: now, parent: nil, children: videoChildren)
        let root = directory("root", modified: now, parent: nil, rootPath: "/fixture", children: [videos, documents])

        let result = FileFilter(kind: .document).evaluate(in: root, now: now)
        #expect(result.files.map(\.name) == ["big.pdf", "mid.pdf", "small.pdf"])
        #expect(result.matching.count == 3)
        // Unfiltered, every kept file is reported.
        #expect(FileFilter().evaluate(in: root, now: now).files.count == videoCount + 3)
    }

    @Test func inactiveFilterEvaluatesEverything() {
        let root = smallTree(now: now)
        let filter = FileFilter()
        #expect(filter.isActive == false)
        let result = filter.evaluate(in: root, now: now)
        #expect(result.files.count == 3)
        #expect(FileFilter(text: " ").isActive == false)
        #expect(FileFilter(minBytes: 1).isActive)
        #expect(FileFilter(kind: .video).isActive)
        #expect(FileFilter(olderThanDays: 30).isActive)
        #expect(FileFilter(text: "a").isActive)
    }

    @Test func cacheReturnsMemoizedResultUntilInputsChange() {
        let root = smallTree(now: now)
        let cache = FileFilterCache()
        let filter = FileFilter(text: "report")

        let first = cache.result(for: root, revision: 1, filter: filter)
        let second = cache.result(for: root, revision: 1, filter: filter)
        #expect(first === second)

        let otherRevision = cache.result(for: root, revision: 2, filter: filter)
        #expect(otherRevision !== first)
        let otherFilter = cache.result(for: root, revision: 1, filter: FileFilter(text: "notes"))
        #expect(otherFilter !== first)

        cache.invalidate()
        let afterInvalidate = cache.result(for: root, revision: 1, filter: filter)
        #expect(afterInvalidate !== first)
        // The memoized result is the same object the charts keep reading, not a fresh walk.
        #expect(afterInvalidate.files.map(\.name) == ["Report.PDF"])
    }
}
