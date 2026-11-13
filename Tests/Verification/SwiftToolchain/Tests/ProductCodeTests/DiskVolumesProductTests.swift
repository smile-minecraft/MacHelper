import Foundation
import Testing
@testable import ProductCode

/// 這些測試只餵入假的 `MountedVolumeObservation` 與 `MountedVolumeFacts`，不會讀取真正的磁碟、
/// 掛載任何磁碟區，也不會呼叫 `DiskVolumeSampler.sample()`。

private func fact(
    _ mountPath: String,
    device: String,
    name: String? = nil,
    volumeUUID: String? = nil,
    mediaUUID: String? = nil,
    total: Int64? = nil,
    available: Int64? = nil,
    fileSystem: String = "apfs",
    isLocal: Bool = true,
    isBrowsable: Bool = true
) -> MountedVolumeFacts {
    MountedVolumeFacts(
        mountPath: mountPath,
        name: name,
        volumeUUID: volumeUUID,
        mediaUUID: mediaUUID,
        totalBytes: total,
        availableBytes: available,
        fileSystemType: fileSystem,
        device: device,
        isLocal: isLocal,
        isBrowsable: isBrowsable)
}

@Suite("容量邊界的正規化")
struct CapacityNormalizationTests {
    @Test("不合格的總容量與可用容量都變成 nil")
    func rejectsUnusableCapacities() {
        #expect(MountedVolumeFacts.facts(from: MountedVolumeObservation(mountPath: "/", totalBytes: 0)).totalBytes == nil)
        #expect(MountedVolumeFacts.facts(from: MountedVolumeObservation(mountPath: "/", totalBytes: -1)).totalBytes == nil)
        #expect(MountedVolumeFacts.facts(from: MountedVolumeObservation(mountPath: "/", totalBytes: 100, availableBytes: -1)).availableBytes == nil)
        #expect(MountedVolumeFacts.facts(from: MountedVolumeObservation(mountPath: "/", totalBytes: 100, availableBytes: 101)).availableBytes == nil)
    }

    @Test("可用容量等於總容量是合法讀數")
    func keepsBoundaryReading() {
        let facts = MountedVolumeFacts.facts(from: MountedVolumeObservation(
            mountPath: "/", totalBytes: 100, availableBytes: 100))
        #expect(facts.totalBytes == 100)
        #expect(facts.availableBytes == 100)
    }
}

@Suite("身分與名稱的正規化")
struct IdentityNormalizationTests {
    @Test("APFS 缺少 Disk Arbitration UUID 時不拿 URL 的 UUID 代替")
    func apfsNeedsDiskArbitrationUUID() {
        let facts = MountedVolumeFacts.facts(from: MountedVolumeObservation(
            mountPath: "/Volumes/Fake",
            diskArbitrationVolumeUUID: nil,
            urlVolumeUUID: "url-uuid",
            mediaUUID: "media-uuid"))
        #expect(facts.volumeUUID == nil)
        #expect(facts.mediaUUID == "MEDIA-UUID")
    }

    @Test("非 APFS 才用 URLResourceValues 的 UUID，且一律轉大寫")
    func nonAPFSUsesURLUUID() {
        let facts = MountedVolumeFacts.facts(from: MountedVolumeObservation(
            mountPath: "/Volumes/Fake",
            urlVolumeUUID: "url-uuid",
            fileSystemType: "exfat"))
        #expect(facts.volumeUUID == "URL-UUID")
    }

    @Test("Disk Arbitration 的 UUID 優先於 URLResourceValues")
    func diskArbitrationWins() {
        let facts = MountedVolumeFacts.facts(from: MountedVolumeObservation(
            mountPath: "/",
            diskArbitrationVolumeUUID: "da-uuid",
            urlVolumeUUID: "url-uuid"))
        #expect(facts.volumeUUID == "DA-UUID")
    }

    @Test("空字串的名稱變成 nil，其餘名稱原樣保留")
    func dropsEmptyName() {
        #expect(MountedVolumeFacts.facts(from: MountedVolumeObservation(mountPath: "/", name: "")).name == nil)
        #expect(MountedVolumeFacts.facts(from: MountedVolumeObservation(mountPath: "/", name: "Macintosh HD")).name == "Macintosh HD")
    }
}

@Suite("APFS 容器名稱的解析")
struct APFSContainerParsingTests {
    @Test("解析出容器編號", arguments: [
        ("/dev/disk3s1s1", "apfs:disk3"),
        ("/dev/disk5s2", "apfs:disk5"),
        ("/dev/disk10s12", "apfs:disk10"),
    ])
    func parsesContainer(device: String, expected: String) {
        #expect(DiskVolumeInventory.apfsContainer(device) == expected)
    }

    @Test("不是 APFS 磁碟區裝置名稱時回傳 nil", arguments: [
        "/dev/disk3",
        "/dev/rdisk3s1",
        "disk3s1",
        "/dev/disk3x1",
        "/dev/disk s1",
        "/dev/disk3s",
    ])
    func rejectsOtherDeviceNames(device: String) {
        #expect(DiskVolumeInventory.apfsContainer(device) == nil)
    }
}

@Suite("磁碟區清單的選擇規則")
struct InventorySelectionTests {
    @Test("根磁碟區同容器的 Data 磁碟區才標成 data")
    func dataVolumeNeedsSameContainer() {
        let root = fact("/", device: "/dev/disk3s1", volumeUUID: "ROOT", mediaUUID: "M1")
        let data = fact("/System/Volumes/Data", device: "/dev/disk3s1s1", volumeUUID: "DATA", mediaUUID: "M1")
        #expect(DiskVolumeInventory.volumes(from: [root, data]).map(\.role) == [.system, .data])

        let foreignData = fact("/System/Volumes/Data", device: "/dev/disk9s1", volumeUUID: "OTHER", mediaUUID: "M9")
        #expect(DiskVolumeInventory.volumes(from: [root, foreignData]).map(\.role) == [.system])

        let sameDeviceData = fact("/System/Volumes/Data", device: "/dev/disk3s1", volumeUUID: "DATA", mediaUUID: "M1")
        #expect(DiskVolumeInventory.volumes(from: [root, sameDeviceData]).map(\.role) == [.system])

        let nonAPFSData = fact("/System/Volumes/Data", device: "/dev/disk3s1s1", fileSystem: "hfs")
        #expect(DiskVolumeInventory.volumes(from: [root, nonAPFSData]).map(\.role) == [.system])
    }

    @Test("只留下 /Volumes 下可瀏覽的本機磁碟區，並依名稱排序")
    func keepsBrowsableLocalVolumesSorted() {
        let root = fact("/", device: "/dev/disk3s1", name: "Macintosh HD")
        let zebra = fact("/Volumes/Zebra", device: "/dev/disk5s1", name: "Zebra", volumeUUID: "Z", mediaUUID: "MZ")
        let alpha = fact("/Volumes/Alpha", device: "/dev/disk4s1", name: "Alpha", volumeUUID: "A", mediaUUID: "MA")
        let hidden = fact("/Volumes/Hidden", device: "/dev/disk6s1", name: "Hidden", isBrowsable: false)
        let network = fact("/Volumes/Network", device: "/dev/disk7s1", name: "Network", isLocal: false)
        let rootCopy = fact("/Volumes/RootCopy", device: "/dev/disk3s1", name: "RootCopy")
        let volumes = DiskVolumeInventory.volumes(from: [root, zebra, alpha, hidden, network, rootCopy])
        #expect(volumes.map(\.name) == ["Macintosh HD", "Alpha", "Zebra"])
        #expect(volumes.map(\.role) == [.system, .local, .local])
    }

    @Test("沒有根磁碟區時仍能看到合格的本機磁碟區")
    func worksWithoutRoot() {
        let only = fact("/Volumes/Only", device: "/dev/disk4s1", name: "Only", volumeUUID: "V", mediaUUID: "M")
        #expect(DiskVolumeInventory.volumes(from: [only]).map(\.role) == [.local])
    }
}

@Suite("重複身分與可記錄條件")
struct IdentityConflictTests {
    @Test("系統磁碟區保留重複的身分，其他掛載點變成不可記錄")
    func systemEntryKeepsDuplicateIdentity() {
        let root = fact("/", device: "/dev/disk3s1", volumeUUID: "V1", mediaUUID: "M1", total: 100, available: 50)
        let clone = fact("/Volumes/Clone", device: "/dev/disk8s1", name: "Clone", volumeUUID: "V1", mediaUUID: "M1", total: 100, available: 50)
        let volumes = DiskVolumeInventory.volumes(from: [root, clone])

        #expect(volumes.count == 2)
        #expect(volumes[0].persistentID?.rawValue == "volume:V1/media:M1")
        #expect(volumes[0].isRecordable)
        #expect(volumes[1].persistentID == nil)
        #expect(!volumes[1].isRecordable)
    }

    @Test("沒有系統或 Data 磁碟區時，重複身分的本機磁碟區都不保留身分")
    func localDuplicatesAllLoseIdentity() {
        let first = fact("/Volumes/One", device: "/dev/disk4s1", name: "One", volumeUUID: "V2", mediaUUID: "M2")
        let second = fact("/Volumes/Two", device: "/dev/disk4s2", name: "Two", volumeUUID: "V2", mediaUUID: "M2")
        let volumes = DiskVolumeInventory.volumes(from: [first, second])
        #expect(volumes.map(\.persistentID) == [nil, nil])
    }

    @Test("可記錄需要身分與兩個容量都齊全")
    func recordableNeedsIdentityAndCapacities() {
        let complete = fact("/Volumes/Full", device: "/dev/disk4s1", volumeUUID: "V", mediaUUID: "M", total: 10, available: 5)
        #expect(DiskVolumeInventory.volumes(from: [complete])[0].isRecordable)

        let noMedia = fact("/Volumes/Half", device: "/dev/disk5s1", volumeUUID: "V", total: 10, available: 5)
        #expect(!DiskVolumeInventory.volumes(from: [noMedia])[0].isRecordable)

        let noCapacity = fact("/Volumes/Empty", device: "/dev/disk6s1", volumeUUID: "V", mediaUUID: "M")
        #expect(!DiskVolumeInventory.volumes(from: [noCapacity])[0].isRecordable)
    }
}

@Suite("容量共用方式")
struct CapacitySharingTests {
    @Test("APFS 依容器標記共用，固定容量檔案系統標記獨立")
    func sharingFollowsFileSystem() {
        let root = fact("/", device: "/dev/disk3s1", name: "Macintosh HD")
        let apfs = fact("/Volumes/APFS", device: "/dev/disk4s1", name: "APFS", volumeUUID: "VA", mediaUUID: "MA")
        let hfs = fact("/Volumes/HFS", device: "/dev/disk5s1", name: "HFS", fileSystem: "hfs")
        let exfat = fact("/Volumes/ExFAT", device: "/dev/disk6s1", name: "ExFAT", fileSystem: "exfat")
        let volumes = DiskVolumeInventory.volumes(from: [root, apfs, hfs, exfat])
        let sharingByName = Dictionary(uniqueKeysWithValues: volumes.compactMap { volume in
            volume.name.map { ($0, volume.capacitySharing) }
        })

        #expect(sharingByName["APFS"] == .sharedContainer("apfs:disk4"))
        #expect(sharingByName["HFS"] == .independent)
        #expect(sharingByName["ExFAT"] == .independent)
    }

    @Test("讀不出裝置名稱的 APFS 磁碟區標成 unknown")
    func unknownAPFSContainer() {
        let volume = fact("/Volumes/NoDisk", device: "not-a-device", name: "NoDisk", volumeUUID: "V", mediaUUID: "M")
        #expect(DiskVolumeInventory.volumes(from: [volume])[0].capacitySharing == .unknown)
    }
}
