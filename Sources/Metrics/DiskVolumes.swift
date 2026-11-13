import Darwin
import DiskArbitration
import Foundation

/// What a mounted volume is used for.
public enum DiskVolumeRole: String, Sendable, Hashable {
    /// The volume mounted at `/`.
    case system
    /// The APFS data volume that belongs to the system volume (`/System/Volumes/Data`).
    case data
    /// Another local volume mounted under `/Volumes`.
    case local
}

/// A stable identity for a volume that can be stored in history.
///
/// The identity combines the two identifiers the system reports for a mounted volume:
///
/// - the volume UUID (`kDADiskDescriptionVolumeUUIDKey`), which distinguishes the volumes
///   inside one APFS container (the system and data volumes share a container and a medium
///   but report different volume UUIDs),
/// - the media UUID (`kDADiskDescriptionMediaUUIDKey`, backed by IOKit's persistent
///   `kIOMediaUUIDKey`), which identifies the medium that carries the volume.
///
/// Both are required. With only the volume UUID, a volume copied to another disk would share
/// history with the original. `rawValue` has the form `volume:<UUID>/media:<UUID>` and is the
/// value history rows persist.
///
/// Two devices that report the same values for both identifiers (for example a block-level
/// clone that copied the partition table and volume metadata) cannot be told apart by this
/// code. Such a pair is only detected while both are mounted at the same time; mounted one at
/// a time, they share one identity. That is the limit of what the system reports, not a claim
/// that they are the same disk. The system documents the media UUID as persistent; a virtual
/// medium that reports a new UUID every time it is attached would look like a new disk.
public struct DiskVolumePersistentID: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(volumeUUID: String, mediaUUID: String) {
        self.rawValue = "volume:\(volumeUUID.uppercased())/media:\(mediaUUID.uppercased())"
    }

    public var description: String { rawValue }
}

/// How a volume's reported capacity relates to other mounted volumes.
public enum DiskCapacitySharing: Sendable, Hashable {
    /// The filesystem reports this volume's own fixed capacity. Adding it to another
    /// independent volume does not double count.
    case independent
    /// APFS volumes in the same container draw from one free-space pool. `container` is a
    /// per-sample token such as `apfs:disk3`; two volumes have the same token only when they
    /// share a container in this sample. Do not persist the token, and never add the
    /// capacities of two volumes that share a token.
    case sharedContainer(String)
    /// macOS did not report enough information to tell how this capacity relates to other
    /// volumes. Do not add it to another volume's capacity; this volume's own total and
    /// available values may still be present.
    case unknown
}

/// A mounted local volume whose capacity can be recorded over time.
///
/// The menu bar UI and the hourly recorder share this value. It contains only what the system
/// reported: a missing name, identity, or capacity stays `nil` instead of becoming a made-up
/// value. A volume that is not mounted is simply absent from a sample.
///
/// A volume is `isRecordable` only when it has a persistent identity and both capacity
/// values. A recordable system and data volume may still report one shared APFS pool; record
/// each volume's values if the history needs them, but never add two volumes whose
/// `capacitySharing` tokens are equal.
public struct DiskVolume: Sendable, Hashable {
    public let role: DiskVolumeRole
    /// The system-provided volume name, or nil when macOS does not report one. UI falls back to
    /// a role title. The name is never used as identity.
    public let name: String?
    /// The mount point reported by the system.
    public let mountPoint: URL
    /// Stable identity for history rows. nil when the system does not report both the volume
    /// UUID and the media UUID; such a volume must not be persisted as if it had a stable
    /// identity.
    public let persistentID: DiskVolumePersistentID?
    /// Total capacity in bytes, or nil when macOS does not report a usable value.
    public let totalBytes: Int64?
    /// Bytes available for important usage (what Finder shows, purgeable included), matching
    /// the existing `disk_space` history. nil when macOS does not report it.
    public let availableBytes: Int64?
    public let capacitySharing: DiskCapacitySharing

    /// True when this volume can be keyed in history without inventing an identity or a value.
    public var isRecordable: Bool {
        persistentID != nil && totalBytes != nil && availableBytes != nil
    }
}

/// Reads the system, data, and locally mounted volumes.
///
/// `sample()` is synchronous file-metadata work: it asks FileManager for mounted volumes, reads
/// URL resource values, and asks Disk Arbitration for each volume's description. It is meant
/// for the hourly recorder and on-demand UI refresh, not for per-second polling or a view body.
/// Call it from a background task.
///
/// Each Disk Arbitration call waits for `diskarbitrationd` and the API has no timeout, so a
/// stuck daemon can block the caller; the sampler does not add a timeout or a background
/// thread of its own. On one Mac with three volumes a full sample took about 16 ms. It never
/// mounts, unmounts, or writes anything. When no volume can be read it returns an empty array
/// rather than inventing a system entry.
public struct DiskVolumeSampler: Sendable {
    public init() {}

    public func sample() -> [DiskVolume] {
        let session = DASessionCreate(kCFAllocatorDefault)
        var facts: [MountedVolumeFacts] = []
        var seenMountPaths = Set<String>()

        for url in Self.probeURLs() {
            guard let fact = MountedVolumeFacts.read(at: url, session: session),
                  seenMountPaths.insert(fact.mountPath).inserted
            else { continue }
            facts.append(fact)
        }
        return DiskVolumeInventory.volumes(from: facts)
    }

    /// The two fixed system paths plus every browsable local volume mounted under `/Volumes`.
    /// `/System/Volumes/Data` is not returned by `mountedVolumeURLs` on current macOS, so it is
    /// probed directly and later verified against the root volume.
    private static func probeURLs() -> [URL] {
        var urls = [
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/System/Volumes/Data"),
        ]
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsBrowsableKey]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: []) ?? []
        for url in mounted {
            guard url.path.hasPrefix("/Volumes/"), url.path != "/Volumes" else { continue }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsLocal == true,
                  values.volumeIsBrowsable == true
            else { continue }
            urls.append(url)
        }
        return urls
    }
}

/// Raw values read for one candidate path, before validation. Kept separate from
/// `MountedVolumeFacts` so every normalization boundary can be tested with injected values
/// instead of a real disk.
struct MountedVolumeObservation: Sendable, Hashable {
    let mountPath: String
    let name: String?
    let diskArbitrationVolumeUUID: String?
    let urlVolumeUUID: String?
    let mediaUUID: String?
    let totalBytes: Int64?
    let availableBytes: Int64?
    let fileSystemType: String
    let device: String
    let isLocal: Bool
    let isBrowsable: Bool

    init(mountPath: String,
         name: String? = nil,
         diskArbitrationVolumeUUID: String? = nil,
         urlVolumeUUID: String? = nil,
         mediaUUID: String? = nil,
         totalBytes: Int64? = nil,
         availableBytes: Int64? = nil,
         fileSystemType: String = "apfs",
         device: String = "/dev/disk3s1",
         isLocal: Bool = true,
         isBrowsable: Bool = true) {
        self.mountPath = mountPath
        self.name = name
        self.diskArbitrationVolumeUUID = diskArbitrationVolumeUUID
        self.urlVolumeUUID = urlVolumeUUID
        self.mediaUUID = mediaUUID
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.fileSystemType = fileSystemType
        self.device = device
        self.isLocal = isLocal
        self.isBrowsable = isBrowsable
    }
}

/// One mounted volume as the system reported it. Kept separate from `DiskVolume` so the rules
/// that choose roles, identity, and sharing can be tested without mounting anything.
struct MountedVolumeFacts: Sendable, Hashable {
    let mountPath: String
    let name: String?
    let volumeUUID: String?
    let mediaUUID: String?
    let totalBytes: Int64?
    let availableBytes: Int64?
    let fileSystemType: String
    let device: String
    let isLocal: Bool
    let isBrowsable: Bool

    /// Reads one path. Returns nil when the path is not a mount point (or no longer exists), so
    /// a plain directory under `/` can never be reported as another disk.
    static func read(at url: URL, session: DASession?) -> MountedVolumeFacts? {
        var status = statfs()
        guard statfs(url.path, &status) == 0 else { return nil }
        let mountPath = string(status.f_mntonname)
        guard mountPath == url.path else { return nil }

        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey, .volumeNameKey, .volumeUUIDStringKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsLocalKey, .volumeIsBrowsableKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        let identity = diskArbitrationIdentity(at: mountPath, session: session)
        return facts(from: MountedVolumeObservation(
            mountPath: mountPath,
            name: [values.volumeLocalizedName, values.volumeName]
                .compactMap { $0 }
                .first { !$0.isEmpty },
            diskArbitrationVolumeUUID: identity.volumeUUID,
            urlVolumeUUID: values.volumeUUIDString,
            mediaUUID: identity.mediaUUID,
            totalBytes: values.volumeTotalCapacity.map(Int64.init),
            availableBytes: values.volumeAvailableCapacityForImportantUsage,
            fileSystemType: string(status.f_fstypename),
            device: string(status.f_mntfromname),
            isLocal: values.volumeIsLocal == true,
            isBrowsable: values.volumeIsBrowsable == true))
    }

    /// Applies the normalization rules to raw values. Pure, so tests can inject every boundary
    /// (missing UUID, missing capacity, an APFS volume without a Disk Arbitration UUID, a
    /// non-APFS volume whose URL resource value is the only UUID) without a disk.
    static func facts(from observation: MountedVolumeObservation) -> MountedVolumeFacts {
        // Disk Arbitration reports the UUID of this APFS volume. URLResourceValues reports the
        // volume group's UUID on current macOS, which is the same for the system and data
        // volumes, so it cannot tell them apart. Fall back to URLResourceValues only for
        // non-APFS filesystems, where the value is the volume's own UUID.
        let volumeUUID: String?
        if let diskUUID = observation.diskArbitrationVolumeUUID {
            volumeUUID = diskUUID.uppercased()
        } else if observation.fileSystemType.lowercased() == "apfs" {
            volumeUUID = nil
        } else {
            volumeUUID = observation.urlVolumeUUID?.uppercased()
        }

        let totalBytes = observation.totalBytes.flatMap { $0 > 0 ? $0 : nil }
        var availableBytes = observation.availableBytes
        if let available = availableBytes, available < 0 {
            availableBytes = nil
        }
        if let total = totalBytes, let available = availableBytes, available > total {
            availableBytes = nil
        }

        return MountedVolumeFacts(
            mountPath: observation.mountPath,
            name: observation.name.flatMap { $0.isEmpty ? nil : $0 },
            volumeUUID: volumeUUID,
            mediaUUID: observation.mediaUUID?.uppercased(),
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            fileSystemType: observation.fileSystemType,
            device: observation.device,
            isLocal: observation.isLocal,
            isBrowsable: observation.isBrowsable)
    }

    private static func string<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    private struct DiskArbitrationIdentity {
        let volumeUUID: String?
        let mediaUUID: String?
    }

    /// One Disk Arbitration lookup per volume; the description carries both keys.
    private static func diskArbitrationIdentity(at path: String,
                                                session: DASession?) -> DiskArbitrationIdentity {
        guard let session,
              let disk = DADiskCreateFromVolumePath(
                kCFAllocatorDefault, session, URL(fileURLWithPath: path) as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return DiskArbitrationIdentity(volumeUUID: nil, mediaUUID: nil) }
        return DiskArbitrationIdentity(
            volumeUUID: uuidString(description[kDADiskDescriptionVolumeUUIDKey as String]),
            mediaUUID: uuidString(description[kDADiskDescriptionMediaUUIDKey as String]))
    }

    private static func uuidString(_ value: Any?) -> String? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        return (CFUUIDCreateString(nil, (value as! CFUUID)) as String).uppercased()
    }
}

/// Chooses which mounted volumes to expose and how to describe them. Pure: the only input is
/// facts the sampler read, so every branch is testable with fake disks.
enum DiskVolumeInventory {
    static func volumes(from facts: [MountedVolumeFacts]) -> [DiskVolume] {
        let byPath = Dictionary(facts.map { ($0.mountPath, $0) }, uniquingKeysWith: { first, _ in first })
        let root = byPath["/"]
        let data = byPath["/System/Volumes/Data"].flatMap { isSystemDataVolume($0, root: root) ? $0 : nil }

        var ordered: [(MountedVolumeFacts, DiskVolumeRole)] = []
        if let root { ordered.append((root, .system)) }
        if let data { ordered.append((data, .data)) }

        var locals = facts.filter { isSuitableLocalVolume($0, root: root, data: data) }
        locals.sort {
            let left = $0.name ?? ""
            let right = $1.name ?? ""
            let order = left.localizedStandardCompare(right)
            return order == .orderedSame ? $0.mountPath < $1.mountPath : order == .orderedAscending
        }
        ordered.append(contentsOf: locals.map { ($0, .local) })

        var identities = ordered.map { persistentID(for: $0.0) }

        // The same identity twice in one sample means two mounts of one volume or two devices
        // that report identical stable identifiers. A system or data entry keeps the identity;
        // every other duplicate stays visible but unrecordable instead of writing two disks
        // into one history row.
        var occurrences: [DiskVolumePersistentID: [Int]] = [:]
        for (index, identity) in identities.enumerated() {
            guard let identity else { continue }
            occurrences[identity, default: []].append(index)
        }
        for indices in occurrences.values where indices.count > 1 {
            let canonical = indices.first { ordered[$0].1 == .system }
                ?? indices.first { ordered[$0].1 == .data }
            for index in indices where index != canonical {
                identities[index] = nil
            }
        }

        return ordered.enumerated().map { index, item in
            makeVolume(from: item.0, role: item.1, persistentID: identities[index])
        }
    }

    /// Both identifiers are required. A volume with only one of them cannot be told apart from
    /// a copy of itself on another medium, so it stays unrecordable until the system reports
    /// the missing piece.
    private static func persistentID(for fact: MountedVolumeFacts) -> DiskVolumePersistentID? {
        guard let volumeUUID = fact.volumeUUID, let mediaUUID = fact.mediaUUID else { return nil }
        return DiskVolumePersistentID(volumeUUID: volumeUUID, mediaUUID: mediaUUID)
    }

    /// `/System/Volumes/Data` is the data volume only when it is a real, distinct APFS volume
    /// in the same container as the root volume. A plain directory, a second mount of the root
    /// filesystem, or a volume from another container is not the system data volume.
    private static func isSystemDataVolume(_ data: MountedVolumeFacts, root: MountedVolumeFacts?) -> Bool {
        guard let root,
              data.isLocal,
              data.fileSystemType.lowercased() == "apfs",
              data.device != root.device,
              let dataContainer = apfsContainer(data.device),
              let rootContainer = apfsContainer(root.device)
        else { return false }
        return dataContainer == rootContainer
    }

    private static func isSuitableLocalVolume(_ fact: MountedVolumeFacts,
                                              root: MountedVolumeFacts?,
                                              data: MountedVolumeFacts?) -> Bool {
        guard fact.isLocal, fact.isBrowsable else { return false }
        guard fact.mountPath.hasPrefix("/Volumes/"), fact.mountPath != "/Volumes" else { return false }
        // A second mount of the system or data filesystem is the same disk, not another one.
        // A copy on a different medium stays visible and keeps a different identity; a copy
        // that reports the same identity is handled by the duplicate rule above.
        return fact.device != root?.device && fact.device != data?.device
    }

    private static func makeVolume(from fact: MountedVolumeFacts,
                                   role: DiskVolumeRole,
                                   persistentID: DiskVolumePersistentID?) -> DiskVolume {
        let sharing: DiskCapacitySharing
        if fact.fileSystemType.lowercased() == "apfs" {
            sharing = apfsContainer(fact.device).map(DiskCapacitySharing.sharedContainer) ?? .unknown
        } else if fixedCapacityFileSystems.contains(fact.fileSystemType.lowercased()) {
            sharing = .independent
        } else {
            sharing = .unknown
        }
        return DiskVolume(
            role: role,
            name: fact.name,
            mountPoint: URL(fileURLWithPath: fact.mountPath),
            persistentID: persistentID,
            totalBytes: fact.totalBytes,
            availableBytes: fact.availableBytes,
            capacitySharing: sharing)
    }

    /// APFS volume device names look like `/dev/disk3s1s1` or `/dev/disk5s2`. The `diskN` part
    /// identifies the container that the volumes share. The token is only meaningful within one
    /// sample: BSD disk numbers can change when disks are attached or removed.
    static func apfsContainer(_ device: String) -> String? {
        guard device.hasPrefix("/dev/") else { return nil }
        var name = String(device.dropFirst("/dev/".count))
        guard name.hasPrefix("disk") else { return nil }
        name.removeFirst("disk".count)
        let number = name.prefix { $0.isNumber }
        guard !number.isEmpty else { return nil }
        name.removeFirst(number.count)
        var removedVolume = false
        while !name.isEmpty {
            guard name.first == "s" else { return nil }
            name.removeFirst()
            let part = name.prefix { $0.isNumber }
            guard !part.isEmpty else { return nil }
            name.removeFirst(part.count)
            removedVolume = true
        }
        guard removedVolume else { return nil }
        return "apfs:disk\(number)"
    }

    /// Local filesystems that report a fixed size per volume and do not share a free-space pool.
    private static let fixedCapacityFileSystems: Set<String> = [
        "hfs", "exfat", "msdos", "ntfs", "udf", "cd9660", "iso9660",
    ]
}
