import Foundation
import Testing
@testable import Metrics

/// Stable identifiers used by the fake facts below. None of these values comes from this Mac.
private let rootMediaUUID = "99999999-9999-9999-9999-999999999999"
private let backupMediaUUID = "88888888-8888-8888-8888-888888888888"
private let localMediaUUID = "77777777-7777-7777-7777-777777777777"

/// Builds a fact without touching a real disk. Every test below drives the pure inventory with
/// these values; the only file-system tests create their own temporary directory or file.
private func fact(
    path: String,
    name: String? = "Disk",
    uuid: String? = "11111111-1111-1111-1111-111111111111",
    mediaUUID: String? = localMediaUUID,
    total: Int64? = 1_000,
    available: Int64? = 500,
    fileSystem: String = "apfs",
    device: String = "/dev/disk3s1",
    local: Bool = true,
    browsable: Bool = true
) -> MountedVolumeFacts {
    MountedVolumeFacts(
        mountPath: path,
        name: name,
        volumeUUID: uuid,
        mediaUUID: mediaUUID,
        totalBytes: total,
        availableBytes: available,
        fileSystemType: fileSystem,
        device: device,
        isLocal: local,
        isBrowsable: browsable)
}

private let root = fact(
    path: "/", name: "Macintosh HD", uuid: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
    mediaUUID: rootMediaUUID, total: 1_000_000, available: 400_000,
    fileSystem: "apfs", device: "/dev/disk3s1s1")

private let data = fact(
    path: "/System/Volumes/Data", name: "Macintosh HD - Data",
    uuid: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", mediaUUID: rootMediaUUID,
    total: 1_000_000, available: 400_000, fileSystem: "apfs", device: "/dev/disk3s5")

private let backup = fact(
    path: "/Volumes/Backup", name: "Backup",
    uuid: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", mediaUUID: backupMediaUUID,
    total: 2_000_000, available: 1_500_000, fileSystem: "apfs", device: "/dev/disk5s2")

@Suite struct DiskVolumeInventoryTests {
    @Test func separatesSystemDataAndLocalVolumes() {
        let volumes = DiskVolumeInventory.volumes(from: [backup, data, root])

        #expect(volumes.map(\.role) == [.system, .data, .local])
        #expect(volumes.map(\.mountPoint.path) == ["/", "/System/Volumes/Data", "/Volumes/Backup"])
        #expect(volumes[0].persistentID == DiskVolumePersistentID(
            volumeUUID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", mediaUUID: rootMediaUUID))
        #expect(volumes[1].persistentID == DiskVolumePersistentID(
            volumeUUID: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", mediaUUID: rootMediaUUID))
        #expect(volumes[2].persistentID == DiskVolumePersistentID(
            volumeUUID: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", mediaUUID: backupMediaUUID))
        #expect(volumes[0].capacitySharing == .sharedContainer("apfs:disk3"))
        #expect(volumes[1].capacitySharing == .sharedContainer("apfs:disk3"))
        #expect(volumes[2].capacitySharing == .sharedContainer("apfs:disk5"))
        #expect(volumes.allSatisfy { $0.isRecordable })
    }

    @Test func systemVolumeIsListedEvenWithoutIdentityOrCapacity() {
        let anonymous = fact(path: "/", name: nil, uuid: nil, mediaUUID: nil, total: nil, available: nil)
        let volumes = DiskVolumeInventory.volumes(from: [anonymous])

        #expect(volumes.count == 1)
        #expect(volumes[0].role == .system)
        #expect(volumes[0].name == nil)
        #expect(volumes[0].persistentID == nil)
        #expect(volumes[0].totalBytes == nil)
        #expect(volumes[0].availableBytes == nil)
        #expect(!volumes[0].isRecordable)
    }

    @Test func sameDeviceIsNotADataVolume() {
        // A second mount of the root filesystem, or a plain directory that statfs reports as
        // the root mount, must not become a second disk.
        let duplicate = fact(
            path: "/System/Volumes/Data", uuid: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            device: "/dev/disk3s1s1")
        let volumes = DiskVolumeInventory.volumes(from: [root, duplicate])

        #expect(volumes.map(\.role) == [.system])
    }

    @Test func differentContainerIsNotADataVolume() {
        let other = fact(
            path: "/System/Volumes/Data", uuid: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            device: "/dev/disk7s1")
        let volumes = DiskVolumeInventory.volumes(from: [root, other])

        #expect(volumes.map(\.role) == [.system])
    }

    @Test func nonAPFSDataPathIsNotADataVolume() {
        let other = fact(
            path: "/System/Volumes/Data", uuid: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            fileSystem: "hfs", device: "/dev/disk3s5")
        let volumes = DiskVolumeInventory.volumes(from: [root, other])

        #expect(volumes.map(\.role) == [.system])
    }

    @Test func dataVolumeNeedsARootVolumeToVerifySharing() {
        let volumes = DiskVolumeInventory.volumes(from: [data])

        #expect(volumes.isEmpty)
    }

    @Test func dataVolumeWithMissingCapacityKeepsItsRole() {
        let unmeasured = fact(
            path: "/System/Volumes/Data", uuid: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            mediaUUID: rootMediaUUID, total: nil, available: nil, device: "/dev/disk3s5")
        let volumes = DiskVolumeInventory.volumes(from: [root, unmeasured])

        #expect(volumes.map(\.role) == [.system, .data])
        #expect(volumes[1].persistentID != nil)
        #expect(volumes[1].totalBytes == nil)
        #expect(volumes[1].availableBytes == nil)
        #expect(!volumes[1].isRecordable)
    }

    @Test func volumeWithoutUUIDIsListedButNotRecordable() {
        let anonymous = fact(path: "/Volumes/Anonymous", name: "Anonymous", uuid: nil)
        let volumes = DiskVolumeInventory.volumes(from: [root, data, anonymous])

        #expect(volumes.count == 3)
        #expect(volumes[2].persistentID == nil)
        #expect(!volumes[2].isRecordable)
    }

    @Test func volumeWithoutMediaUUIDIsListedButNotRecordable() {
        // A volume UUID alone cannot tell a copied volume on another medium apart.
        let anonymous = fact(path: "/Volumes/Anonymous", name: "Anonymous", mediaUUID: nil)
        let volumes = DiskVolumeInventory.volumes(from: [root, data, anonymous])

        #expect(volumes.count == 3)
        #expect(volumes[2].persistentID == nil)
        #expect(!volumes[2].isRecordable)
    }

    @Test func missingCapacityIsNotFabricated() {
        let noCapacity = fact(path: "/Volumes/Empty", uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                              mediaUUID: "11111111-2222-3333-4444-555555555555",
                              total: nil, available: nil)
        let noAvailable = fact(path: "/Volumes/Partial", uuid: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
                               mediaUUID: "66666666-7777-8888-9999-000000000000",
                               total: 4_000, available: nil)
        let volumes = DiskVolumeInventory.volumes(from: [root, data, noCapacity, noAvailable])

        #expect(volumes.count == 4)
        #expect(volumes[2].totalBytes == nil && volumes[2].availableBytes == nil)
        #expect(!volumes[2].isRecordable)
        #expect(volumes[3].totalBytes == 4_000)
        #expect(volumes[3].availableBytes == nil)
        #expect(!volumes[3].isRecordable)
    }

    @Test func sameNameDifferentVolumesKeepDistinctIDs() {
        let first = fact(path: "/Volumes/One", name: "Backup",
                         uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                         mediaUUID: "11111111-2222-3333-4444-555555555555", device: "/dev/disk5s1")
        let second = fact(path: "/Volumes/Two", name: "Backup",
                          uuid: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
                          mediaUUID: "66666666-7777-8888-9999-000000000000", device: "/dev/disk6s1")
        let volumes = DiskVolumeInventory.volumes(from: [root, data, second, first])

        #expect(volumes.count == 4)
        #expect(volumes[2].name == "Backup" && volumes[3].name == "Backup")
        #expect(volumes[2].persistentID != volumes[3].persistentID)
        #expect(volumes[2].persistentID != nil && volumes[3].persistentID != nil)
    }

    @Test func remountKeepsPersistentIDEvenWhenPathAndDeviceChange() {
        let before = DiskVolumeInventory.volumes(from: [root, data, fact(
            path: "/Volumes/Before", uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            mediaUUID: "11111111-2222-3333-4444-555555555555", device: "/dev/disk5s1")])
        let after = DiskVolumeInventory.volumes(from: [root, data, fact(
            path: "/Volumes/After", uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            mediaUUID: "11111111-2222-3333-4444-555555555555", device: "/dev/disk7s1")])

        #expect(before.last?.persistentID == after.last?.persistentID)
        #expect(before.last?.persistentID != nil)
        #expect(before.last?.mountPoint.path == "/Volumes/Before")
        #expect(after.last?.mountPoint.path == "/Volumes/After")
    }

    @Test func sameVolumeUUIDOnDifferentMediaKeepsDistinctIDs() {
        // Two disks mounted at the same time may carry a copied volume UUID. The media UUID
        // tells them apart, so both stay recordable under their own identity.
        let first = fact(path: "/Volumes/One", name: "One",
                         uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                         mediaUUID: "11111111-2222-3333-4444-555555555555", device: "/dev/disk5s1")
        let second = fact(path: "/Volumes/Two", name: "Two",
                          uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                          mediaUUID: "66666666-7777-8888-9999-000000000000", device: "/dev/disk6s1")
        let volumes = DiskVolumeInventory.volumes(from: [root, data, second, first])

        #expect(volumes.count == 4)
        #expect(volumes[2].persistentID != nil && volumes[3].persistentID != nil)
        #expect(volumes[2].persistentID != volumes[3].persistentID)
        #expect(volumes[2].isRecordable && volumes[3].isRecordable)
    }

    @Test func sameVolumeUUIDOnDifferentMediaKeepsDistinctIDsAcrossSamples() {
        // The review's failing case: the two disks are mounted one after the other, so a
        // same-sample duplicate check alone cannot protect history. The media UUID must make
        // the two samples differ, and mounting the first disk again must return its own ID.
        let first = DiskVolumeInventory.volumes(from: [root, data, fact(
            path: "/Volumes/First", uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            mediaUUID: "11111111-2222-3333-4444-555555555555", device: "/dev/disk5s1")])
        let second = DiskVolumeInventory.volumes(from: [root, data, fact(
            path: "/Volumes/Second", uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            mediaUUID: "66666666-7777-8888-9999-000000000000", device: "/dev/disk6s1")])
        let firstAgain = DiskVolumeInventory.volumes(from: [root, data, fact(
            path: "/Volumes/First", uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            mediaUUID: "11111111-2222-3333-4444-555555555555", device: "/dev/disk5s1")])

        #expect(first.last?.persistentID != nil)
        #expect(second.last?.persistentID != nil)
        #expect(first.last?.persistentID != second.last?.persistentID)
        #expect(first.last?.persistentID == firstAgain.last?.persistentID)
    }

    @Test func duplicateIdentityIsListedButNotRecordable() {
        // Two mounts that report the same volume and media UUID are indistinguishable. Both
        // stay visible so the UI does not hide a disk, but neither gets to write history.
        let first = fact(path: "/Volumes/A", name: "A",
                         uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                         mediaUUID: "11111111-2222-3333-4444-555555555555")
        let second = fact(path: "/Volumes/B", name: "B",
                          uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                          mediaUUID: "11111111-2222-3333-4444-555555555555")
        let volumes = DiskVolumeInventory.volumes(from: [root, data, second, first])

        #expect(volumes.count == 4)
        #expect(volumes[2].mountPoint.path == "/Volumes/A")
        #expect(volumes[3].mountPoint.path == "/Volumes/B")
        #expect(volumes[2].persistentID == nil && volumes[3].persistentID == nil)
        #expect(!volumes[2].isRecordable && !volumes[3].isRecordable)
    }

    @Test func identicalStableIdentifiersCannotBeToldApart() {
        // Documented limit: when both media report the same volume UUID and the same media
        // UUID, no visible identifier distinguishes them. Mounted one at a time they share one
        // identity; this test pins the limit so a future change cannot claim otherwise.
        let first = DiskVolumeInventory.volumes(from: [root, data, fact(
            path: "/Volumes/First", uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            mediaUUID: "11111111-2222-3333-4444-555555555555", device: "/dev/disk5s1")])
        let second = DiskVolumeInventory.volumes(from: [root, data, fact(
            path: "/Volumes/Second", uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            mediaUUID: "11111111-2222-3333-4444-555555555555", device: "/dev/disk6s1")])

        #expect(first.last?.persistentID == second.last?.persistentID)
    }

    @Test func clonedSystemVolumeOnDifferentMediaIsRecordable() {
        // A copy of the system volume on another medium is another disk, not a second mount.
        let clone = fact(path: "/Volumes/Clone", name: "Clone",
                         uuid: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                         mediaUUID: "77777777-8888-9999-0000-111111111111", device: "/dev/disk9s1")
        let volumes = DiskVolumeInventory.volumes(from: [root, data, clone])

        #expect(volumes.count == 3)
        #expect(volumes[2].role == .local)
        #expect(volumes[2].persistentID != nil)
        #expect(volumes[2].persistentID != volumes[0].persistentID)
        #expect(volumes[2].isRecordable)
    }

    @Test func secondMountOfSystemVolumeIsNotAnotherDisk() {
        let copy = fact(path: "/Volumes/SystemCopy", name: "System Copy",
                        uuid: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                        mediaUUID: rootMediaUUID, device: "/dev/disk3s1s1")
        let volumes = DiskVolumeInventory.volumes(from: [root, data, copy])

        #expect(volumes.map(\.role) == [.system, .data])
        #expect(volumes[0].persistentID != nil)
    }

    @Test func duplicateOfSystemIdentityIsNotRecordable() {
        let copy = fact(path: "/Volumes/SystemCopy", name: "System Copy",
                        uuid: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                        mediaUUID: rootMediaUUID, device: "/dev/disk3s2")
        let volumes = DiskVolumeInventory.volumes(from: [root, data, copy])

        #expect(volumes.map(\.role) == [.system, .data, .local])
        #expect(volumes[0].persistentID != nil)
        #expect(volumes[2].persistentID == nil)
        #expect(!volumes[2].isRecordable)
    }

    @Test func unmountedVolumeIsAbsent() {
        let volumes = DiskVolumeInventory.volumes(from: [root, data])

        #expect(volumes.map(\.role) == [.system, .data])
        #expect(volumes.allSatisfy { $0.mountPoint.path != "/Volumes/Removed" })
    }

    @Test func hiddenNetworkAndNonVolumeMountsAreExcluded() {
        let network = fact(path: "/Volumes/Network", local: false)
        let hidden = fact(path: "/Volumes/Hidden", browsable: false)
        let systemVolume = fact(path: "/System/Volumes/VM", browsable: false)
        let privateMount = fact(path: "/private/var/tmp", browsable: true)
        let volumes = DiskVolumeInventory.volumes(
            from: [root, data, network, hidden, systemVolume, privateMount])

        #expect(volumes.map(\.role) == [.system, .data])
    }

    @Test func nonAPFSFilesystemsAreIndependentOrUnknown() {
        let exfat = fact(path: "/Volumes/ExFAT", uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                         mediaUUID: "11111111-2222-3333-4444-555555555555",
                         fileSystem: "exfat", device: "/dev/disk5s1")
        let fuse = fact(path: "/Volumes/FUSE", uuid: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
                        mediaUUID: "66666666-7777-8888-9999-000000000000",
                        fileSystem: "fusefs", device: "/dev/disk6s1")
        let volumes = DiskVolumeInventory.volumes(from: [root, data, exfat, fuse])

        #expect(volumes[2].capacitySharing == .independent)
        #expect(volumes[3].capacitySharing == .unknown)
    }

    @Test func apfsVolumeWithUnparsableDeviceHasUnknownSharing() {
        let broken = fact(path: "/Volumes/Broken", uuid: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                          mediaUUID: "11111111-2222-3333-4444-555555555555",
                          fileSystem: "apfs", device: "disk5s2")
        let volumes = DiskVolumeInventory.volumes(from: [root, data, broken])

        #expect(volumes[2].capacitySharing == .unknown)
        #expect(volumes[2].persistentID != nil)
    }

    @Test func apfsContainerComesFromTheVolumeDevice() {
        #expect(DiskVolumeInventory.apfsContainer("/dev/disk3s1s1") == "apfs:disk3")
        #expect(DiskVolumeInventory.apfsContainer("/dev/disk3s5") == "apfs:disk3")
        #expect(DiskVolumeInventory.apfsContainer("/dev/disk10s2") == "apfs:disk10")
        #expect(DiskVolumeInventory.apfsContainer("/dev/disk3s1s2") == "apfs:disk3")
        #expect(DiskVolumeInventory.apfsContainer("/dev/disk3") == nil)
        #expect(DiskVolumeInventory.apfsContainer("/dev/disk3s") == nil)
        #expect(DiskVolumeInventory.apfsContainer("/dev/disk3x1") == nil)
        #expect(DiskVolumeInventory.apfsContainer("disk3s1") == nil)
        #expect(DiskVolumeInventory.apfsContainer("/dev/mapper/foo") == nil)
    }

    @Test func persistentIDCombinesVolumeAndMediaAndNormalizesCase() {
        let lower = DiskVolumePersistentID(volumeUUID: "abcd", mediaUUID: "ef01")
        let upper = DiskVolumePersistentID(volumeUUID: "ABCD", mediaUUID: "EF01")

        #expect(lower == upper)
        #expect(lower.rawValue == "volume:ABCD/media:EF01")
        #expect(lower != DiskVolumePersistentID(volumeUUID: "ABCD", mediaUUID: "EF02"))
        #expect(lower != DiskVolumePersistentID(volumeUUID: "ABCE", mediaUUID: "EF01"))
    }

    @Test func systemAndDataShareOneCapacityPool() {
        let volumes = DiskVolumeInventory.volumes(from: [root, data])

        #expect(volumes[0].persistentID != volumes[1].persistentID)
        #expect(volumes[0].capacitySharing == volumes[1].capacitySharing)
        #expect(volumes[0].totalBytes == volumes[1].totalBytes)
        #expect(volumes[0].availableBytes == volumes[1].availableBytes)
    }

    @Test func emptyFactsProduceNoVolumes() {
        // A failed or empty read must not invent a system volume.
        #expect(DiskVolumeInventory.volumes(from: []).isEmpty)
    }

    @Test func missingRootMeansNoSystemOrDataRole() {
        let volumes = DiskVolumeInventory.volumes(from: [data, backup])

        #expect(volumes.map(\.role) == [.local])
        #expect(volumes[0].mountPoint.path == "/Volumes/Backup")
    }
}

@Suite struct MountedVolumeFactsTests {
    @Test func plainDirectoryIsNotAMountPoint() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "disk-volumes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MountedVolumeFacts.read(at: url, session: nil) == nil)
    }

    @Test func regularFileIsNotAMountPoint() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "disk-volumes-\(UUID().uuidString).txt")
        try Data("test".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MountedVolumeFacts.read(at: url, session: nil) == nil)
    }

    @Test func missingPathIsNotAMountPoint() {
        let url = URL(fileURLWithPath: "/no-such-volume-\(UUID().uuidString)")

        #expect(MountedVolumeFacts.read(at: url, session: nil) == nil)
    }

    @Test func factsNormalizeUUIDsAndCapacity() {
        let value = MountedVolumeFacts.facts(from: MountedVolumeObservation(
            mountPath: "/Volumes/Test",
            name: "Test",
            diskArbitrationVolumeUUID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            urlVolumeUUID: "ffffffff-ffff-ffff-ffff-ffffffffffff",
            mediaUUID: "99999999-9999-9999-9999-999999999999",
            totalBytes: 4_000,
            availableBytes: 1_500,
            fileSystemType: "apfs",
            device: "/dev/disk5s1"))

        #expect(value.volumeUUID == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        #expect(value.mediaUUID == "99999999-9999-9999-9999-999999999999")
        #expect(value.totalBytes == 4_000)
        #expect(value.availableBytes == 1_500)
        #expect(value.name == "Test")
        #expect(value.isLocal && value.isBrowsable)
    }

    @Test func apfsWithoutDiskArbitrationUUIDKeepsVolumeUUIDUnknown() {
        // URLResourceValues reports the APFS volume group UUID here, which the system and data
        // volumes share. Using it would merge their history, so it is not a fallback for APFS.
        let value = MountedVolumeFacts.facts(from: MountedVolumeObservation(
            mountPath: "/System/Volumes/Data",
            urlVolumeUUID: "ffffffff-ffff-ffff-ffff-ffffffffffff",
            mediaUUID: rootMediaUUID,
            fileSystemType: "apfs",
            device: "/dev/disk3s5"))

        #expect(value.volumeUUID == nil)
        #expect(value.mediaUUID == rootMediaUUID)
    }

    @Test func nonAPFSFallsBackToURLVolumeUUID() {
        let value = MountedVolumeFacts.facts(from: MountedVolumeObservation(
            mountPath: "/Volumes/USB",
            urlVolumeUUID: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
            mediaUUID: backupMediaUUID,
            fileSystemType: "exfat",
            device: "/dev/disk6s1"))

        #expect(value.volumeUUID == "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")
        #expect(value.mediaUUID == backupMediaUUID)
    }

    @Test func diskArbitrationVolumeUUIDWinsOverURLResourceValue() {
        let value = MountedVolumeFacts.facts(from: MountedVolumeObservation(
            mountPath: "/Volumes/Test",
            diskArbitrationVolumeUUID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            urlVolumeUUID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            mediaUUID: backupMediaUUID,
            fileSystemType: "hfs",
            device: "/dev/disk6s1"))

        #expect(value.volumeUUID == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    }

    @Test func zeroOrNegativeTotalCapacityBecomesUnknown() {
        for total in [Int64(0), -1, nil] as [Int64?] {
            let value = MountedVolumeFacts.facts(from: MountedVolumeObservation(
                mountPath: "/Volumes/Test",
                totalBytes: total,
                availableBytes: 0))
            #expect(value.totalBytes == nil)
            // The reported free space is still real even when the total is not.
            #expect(value.availableBytes == 0)
        }
    }

    @Test func negativeAvailableCapacityBecomesUnknown() {
        let value = MountedVolumeFacts.facts(from: MountedVolumeObservation(
            mountPath: "/Volumes/Test",
            totalBytes: 100,
            availableBytes: -1))

        #expect(value.totalBytes == 100)
        #expect(value.availableBytes == nil)
    }

    @Test func availableCapacityAboveTotalBecomesUnknown() {
        let value = MountedVolumeFacts.facts(from: MountedVolumeObservation(
            mountPath: "/Volumes/Test",
            totalBytes: 100,
            availableBytes: 101))

        #expect(value.totalBytes == 100)
        #expect(value.availableBytes == nil)
    }

    @Test func emptyNameBecomesUnknown() {
        let value = MountedVolumeFacts.facts(from: MountedVolumeObservation(
            mountPath: "/Volumes/Test",
            name: ""))

        #expect(value.name == nil)
    }

    @Test func missingMediaUUIDStaysUnknown() {
        let value = MountedVolumeFacts.facts(from: MountedVolumeObservation(
            mountPath: "/Volumes/Test",
            diskArbitrationVolumeUUID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            mediaUUID: nil))

        #expect(value.volumeUUID == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        #expect(value.mediaUUID == nil)
    }
}
