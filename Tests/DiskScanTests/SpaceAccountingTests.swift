import Foundation
import Testing
@testable import DiskScan

@Suite struct SpaceAccountingTests {
    /// Used = 600 KB, reclaimable = 60 KB.
    let volume = SpaceAccounting.Volume(identifier: "VOL-A", total: 1_000_000, available: 400_000,
                                        availableForImportantUsage: 460_000)

    func scan(bytes: UInt64, coversVolume: Bool = true, identifier: String? = "VOL-A",
              inaccessible: Int = 0, cloudOnly: Int = 0, protected: Int = 0,
              isLive: Bool = true, isComplete: Bool = true) -> SpaceAccounting.Scan {
        SpaceAccounting.Scan(rootPath: "/scan", volumeIdentifier: identifier, coversVolume: coversVolume,
                             bytes: bytes,
                             limits: SpaceAccounting.Limits(inaccessibleDirectories: inaccessible,
                                                            cloudOnlyDirectories: cloudOnly,
                                                            protectedDirectories: protected),
                             isLive: isLive, isComplete: isComplete)
    }

    @Test func wholeVolumeLeavesUnattributedBytes() throws {
        let result = SpaceAccounting.evaluate(scan: scan(bytes: 450_000), volume: volume)
        guard case .wholeVolume(let whole) = result else {
            Issue.record("expected wholeVolume, got \(result)")
            return
        }
        #expect(whole.volume.used == 600_000)
        #expect(whole.scannedBytes == 450_000)
        #expect(whole.unattributedBytes == 150_000)
        #expect(whole.overcountedBytes == 0)
        // The only reclaimable figure is the one macOS reports, never the gap.
        #expect(whole.volume.reclaimable == 60_000)
    }

    @Test func unreadableFoldersMakeAWholeVolumeScanPartial() {
        let result = SpaceAccounting.evaluate(scan: scan(bytes: 450_000, inaccessible: 2), volume: volume)
        guard case .partialScan(let partial) = result else {
            Issue.record("expected partialScan, got \(result)")
            return
        }
        #expect(partial.gapBytes == 150_000)
        #expect(partial.limits.isComplete == false)
    }

    @Test func cloudOnlyFoldersMakeAWholeVolumeScanPartial() {
        let result = SpaceAccounting.evaluate(scan: scan(bytes: 450_000, cloudOnly: 3), volume: volume)
        guard case .partialScan = result else {
            Issue.record("expected partialScan, got \(result)")
            return
        }
    }

    @Test func protectedFoldersDoNotMakeAScanPartial() {
        let result = SpaceAccounting.evaluate(scan: scan(bytes: 450_000, protected: 12), volume: volume)
        guard case .wholeVolume(let whole) = result else {
            Issue.record("expected wholeVolume, got \(result)")
            return
        }
        #expect(whole.limits.protectedDirectories == 12)
        #expect(whole.unattributedBytes == 150_000)
    }

    @Test func subfolderIsNotSubtractedFromVolumeUsage() {
        let result = SpaceAccounting.evaluate(scan: scan(bytes: 100_000, coversVolume: false), volume: volume)
        guard case .subfolder(let folder) = result else {
            Issue.record("expected subfolder, got \(result)")
            return
        }
        #expect(folder.scannedBytes == 100_000)
        #expect(folder.volume.used == 600_000)
    }

    @Test func differentVolumeIsNotCompared() {
        let result = SpaceAccounting.evaluate(scan: scan(bytes: 450_000, identifier: "VOL-B"), volume: volume)
        guard case .unmeasured(let unmeasured) = result else {
            Issue.record("expected unmeasured, got \(result)")
            return
        }
        #expect(unmeasured.reason == .differentVolume)
        #expect(unmeasured.scannedBytes == 450_000)
    }

    @Test func savedScanIsNotComparedWithTodaysVolumeReading() {
        let result = SpaceAccounting.evaluate(scan: scan(bytes: 450_000, isLive: false), volume: volume)
        guard case .unmeasured(let unmeasured) = result else {
            Issue.record("expected unmeasured, got \(result)")
            return
        }
        #expect(unmeasured.reason == .savedScan)
    }

    @Test func stoppedScanIsNotCompared() {
        let result = SpaceAccounting.evaluate(scan: scan(bytes: 450_000, isComplete: false), volume: volume)
        guard case .unmeasured(let unmeasured) = result else {
            Issue.record("expected unmeasured, got \(result)")
            return
        }
        #expect(unmeasured.reason == .incompleteScan)
    }

    @Test func missingVolumeFiguresAreUnmeasured() {
        let result = SpaceAccounting.evaluate(scan: scan(bytes: 450_000), volume: nil)
        guard case .unmeasured(let unmeasured) = result else {
            Issue.record("expected unmeasured, got \(result)")
            return
        }
        #expect(unmeasured.reason == .volumeUnavailable)
        #expect(unmeasured.scannedBytes == 450_000)
    }

    @Test func missingVolumeIdentifierIsUnmeasured() {
        let result = SpaceAccounting.evaluate(scan: scan(bytes: 450_000, identifier: nil), volume: volume)
        guard case .unmeasured(let unmeasured) = result else {
            Issue.record("expected unmeasured, got \(result)")
            return
        }
        #expect(unmeasured.reason == .volumeUnavailable)
    }

    @Test func noScanIsUnmeasured() {
        let result = SpaceAccounting.evaluate(scan: nil, volume: volume)
        guard case .unmeasured(let unmeasured) = result else {
            Issue.record("expected unmeasured, got \(result)")
            return
        }
        #expect(unmeasured.reason == .noScan)
        #expect(unmeasured.scannedBytes == nil)
    }

    @Test func scanLargerThanVolumeUsageDoesNotProduceANegativeDifference() {
        let result = SpaceAccounting.evaluate(scan: scan(bytes: 650_000), volume: volume)
        guard case .wholeVolume(let whole) = result else {
            Issue.record("expected wholeVolume, got \(result)")
            return
        }
        #expect(whole.unattributedBytes == 0)
        #expect(whole.overcountedBytes == 50_000)
    }
}
