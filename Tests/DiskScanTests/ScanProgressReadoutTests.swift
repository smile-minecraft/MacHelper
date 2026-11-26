import Foundation
import Testing
@testable import DiskScan

@Suite struct ScanProgressReadoutTests {
    private func counters(files: Int, directories: Int, bytes: UInt64) -> ScanProgress {
        ScanProgress(files: files, directories: directories, bytes: bytes, unreadableDirectories: 0)
    }

    /// A page with no scan behind it shows zero, not another scan's totals.
    @Test func startsAtZero() {
        let readout = ScanProgressReadout()
        #expect(readout.progress.files == 0)
        #expect(readout.progress.directories == 0)
        #expect(readout.progress.bytes == 0)
    }

    /// The scanning page polls while the scan runs. A reading that is smaller than the one on
    /// screen — a stale poll, or one that overtook a later one — must not make the displayed size
    /// and file count step backwards, which is what made the numbers on screen jump.
    @Test func readingsOnlyGrow() {
        var readout = ScanProgressReadout()
        readout.update(counters(files: 120, directories: 8, bytes: 4_000))
        readout.update(counters(files: 400, directories: 20, bytes: 12_500))
        readout.update(counters(files: 300, directories: 15, bytes: 9_000))
        #expect(readout.progress.files == 400)
        #expect(readout.progress.directories == 20)
        #expect(readout.progress.bytes == 12_500)
    }

    /// Counters that a later reading leaves at zero are kept, not cleared: the scan still had the
    /// unreadable folders it already counted.
    @Test func everyCounterKeepsItsLargestValue() {
        var readout = ScanProgressReadout()
        readout.update(ScanProgress(files: 1, directories: 1, bytes: 1, unreadableDirectories: 2,
                                    cloudOnlyDirectories: 1, protectedDirectories: 1))
        readout.update(ScanProgress(files: 2, directories: 2, bytes: 2, unreadableDirectories: 0,
                                    cloudOnlyDirectories: 0, protectedDirectories: 0))
        #expect(readout.progress.unreadableDirectories == 2)
        #expect(readout.progress.cloudOnlyDirectories == 1)
        #expect(readout.progress.protectedDirectories == 1)
        #expect(readout.progress.files == 2)
        // The unreadable folders stay classified the way the scan counted them.
        #expect(readout.progress.inaccessibleDirectories == 0)
    }

    /// A new scan starts from zero and may legitimately be smaller than the scan before it.
    @Test func resetLetsANewScanStartSmaller() {
        var readout = ScanProgressReadout()
        readout.update(counters(files: 900, directories: 60, bytes: 900_000))
        readout.reset()
        #expect(readout.progress.files == 0)
        #expect(readout.progress.bytes == 0)
        readout.update(counters(files: 3, directories: 1, bytes: 512))
        #expect(readout.progress.files == 3)
        #expect(readout.progress.bytes == 512)
    }
}
