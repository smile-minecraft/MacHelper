import Foundation
import Testing
@testable import DiskScan

/// Reads the same volume facts the app reads, for the one opt-in sample below.
private struct MachineVolume {
    let identifier: String?
    let mountPath: String?
    let total: Int64
    let available: Int64
    let availableForImportant: Int64

    static func load(_ url: URL) -> MachineVolume? {
        let fresh = URL(fileURLWithPath: url.path)
        guard let v = try? fresh.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                          .volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeUUIDStringKey]),
              let total = v.volumeTotalCapacity, let available = v.volumeAvailableCapacity
        else { return nil }
        var info = statfs()
        let mountPath = statfs(fresh.path, &info) == 0
            ? withUnsafePointer(to: &info.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            : nil
        return MachineVolume(identifier: v.volumeUUIDString, mountPath: mountPath,
                             total: Int64(total), available: Int64(available),
                             availableForImportant: v.volumeAvailableCapacityForImportantUsage ?? Int64(available))
    }

    var spaceVolume: SpaceAccounting.Volume? {
        identifier.map { SpaceAccounting.Volume(identifier: $0, total: total, available: available,
                                                availableForImportantUsage: availableForImportant) }
    }
}

/// Not part of the normal run: these touch the real disk. Run with MH_REAL_DISK=1 to print a real
/// sample of the accounting and snapshot states for this machine.
@Suite struct RealDiskSampleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MH_REAL_DISK"] == "1"))
    func realMachineSample() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DiskScan")
        let result = try DiskScanner().scan(sourceDirectory)
        let machineVolume = try #require(MachineVolume.load(sourceDirectory))
        let scan = SpaceAccounting.Scan(rootPath: result.root.path,
                                        volumeIdentifier: machineVolume.identifier,
                                        coversVolume: machineVolume.mountPath == result.root.path,
                                        bytes: result.root.size,
                                        limits: SpaceAccounting.Limits(progress: result.progress),
                                        isLive: true, isComplete: !result.cancelled)
        let accounting = SpaceAccounting.evaluate(scan: scan, volume: machineVolume.spaceVolume)
        let snapshots = LocalSnapshots.query(for: sourceDirectory)

        print("REAL SAMPLE scan: \(result.root.path) \(result.root.size) bytes, \(result.progress.files) files")
        print("REAL SAMPLE volume: id=\(machineVolume.identifier ?? "nil") mount=\(machineVolume.mountPath ?? "nil") total=\(machineVolume.total) available=\(machineVolume.available) reclaimable=\(machineVolume.spaceVolume?.reclaimable ?? -1)")
        switch accounting {
        case .wholeVolume(let whole):
            print("REAL SAMPLE accounting: wholeVolume scanned=\(whole.scannedBytes) used=\(whole.volume.used) unattributed=\(whole.unattributedBytes) overcounted=\(whole.overcountedBytes)")
        case .subfolder(let folder):
            print("REAL SAMPLE accounting: subfolder scanned=\(folder.scannedBytes) volumeUsed=\(folder.volume.used)")
        case .partialScan(let partial):
            print("REAL SAMPLE accounting: partialScan scanned=\(partial.scannedBytes) gap=\(partial.gapBytes) inaccessible=\(partial.limits.inaccessibleDirectories) cloudOnly=\(partial.limits.cloudOnlyDirectories)")
        case .unmeasured(let unmeasured):
            print("REAL SAMPLE accounting: unmeasured reason=\(unmeasured.reason) scanned=\(String(describing: unmeasured.scannedBytes))")
        }
        switch snapshots {
        case .none:
            print("REAL SAMPLE snapshots: none")
        case .list(let dates, let total):
            print("REAL SAMPLE snapshots: \(total) total, dates=\(dates.map { $0.formatted(date: .abbreviated, time: .shortened) })")
        case .unavailable(let reason):
            print("REAL SAMPLE snapshots: unavailable \(reason)")
        }
        #expect(result.root.size > 0)
    }
}
