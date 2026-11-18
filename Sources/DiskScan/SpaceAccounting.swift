import Foundation

/// What a scan measured against what the volume reports, and whether the two may be compared.
/// Pure data: nothing here reads the disk or the volume.
///
/// A difference is only shown when the scan and the volume figures describe the same volume,
/// the scan root is that volume's root, the scan ran to completion, and the scan is recent enough
/// to sit beside a fresh volume reading. Anything else is `unmeasured`, with the reason.
public enum SpaceAccounting: Sendable, Equatable {
    /// Volume figures read at one moment, identified by the volume they belong to.
    public struct Volume: Sendable, Equatable {
        /// `volumeUUIDString` of the volume; two readings are only compared when these match.
        public let identifier: String
        public let total: Int64
        /// Space the volume reports as free right now.
        public let available: Int64
        /// Free space including what macOS would purge on demand (what Finder shows).
        public let availableForImportantUsage: Int64

        public init(identifier: String, total: Int64, available: Int64, availableForImportantUsage: Int64) {
            self.identifier = identifier
            self.total = total
            self.available = available
            self.availableForImportantUsage = availableForImportantUsage
        }

        /// Space the volume reports as in use. APFS shares one pool between its volumes, so this
        /// is the container's usage, not one folder's.
        public var used: Int64 { max(total - available, 0) }
        /// What macOS says it can reclaim on demand; always the system's figure, never estimated.
        public var reclaimable: Int64 { max(availableForImportantUsage - available, 0) }
    }

    /// How much a scan measured and under which conditions.
    public struct Scan: Sendable, Equatable {
        public let rootPath: String
        /// `volumeUUIDString` of the volume the scan root is on, read when the scan finished.
        /// nil when it could not be read.
        public let volumeIdentifier: String?
        /// True when the scan root is the root of the volume the figures describe.
        public let coversVolume: Bool
        /// Allocated bytes the scan summed.
        public let bytes: UInt64
        public let limits: Limits
        /// False for a restored scan: its bytes were measured before today's volume reading.
        public let isLive: Bool
        /// False when the scan was stopped before it finished.
        public let isComplete: Bool

        public init(rootPath: String, volumeIdentifier: String?, coversVolume: Bool, bytes: UInt64,
                    limits: Limits, isLive: Bool, isComplete: Bool) {
            self.rootPath = rootPath
            self.volumeIdentifier = volumeIdentifier
            self.coversVolume = coversVolume
            self.bytes = bytes
            self.limits = limits
            self.isLive = isLive
            self.isComplete = isComplete
        }
    }

    /// What the scan could not measure.
    public struct Limits: Sendable, Equatable {
        public let inaccessibleDirectories: Int
        public let cloudOnlyDirectories: Int
        public let protectedDirectories: Int

        public init(inaccessibleDirectories: Int, cloudOnlyDirectories: Int, protectedDirectories: Int) {
            self.inaccessibleDirectories = inaccessibleDirectories
            self.cloudOnlyDirectories = cloudOnlyDirectories
            self.protectedDirectories = protectedDirectories
        }

        public init(progress: ScanProgress) {
            self.init(inaccessibleDirectories: progress.inaccessibleDirectories,
                      cloudOnlyDirectories: progress.cloudOnlyDirectories,
                      protectedDirectories: progress.protectedDirectories)
        }

        /// No folder was unreadable or skipped for being cloud-only, so the byte total is not
        /// knowingly short. Folders macOS protects from every app are counted separately: they
        /// are unmeasurable rather than missed.
        public var isComplete: Bool { inaccessibleDirectories == 0 && cloudOnlyDirectories == 0 }
    }

    /// The scan root is the whole volume. `unattributedBytes` is the part of the volume's usage
    /// the scan did not measure; it includes protected system data and space shared with other
    /// APFS volumes, so it is not space the user can reclaim.
    public struct WholeVolume: Sendable, Equatable {
        public let volume: Volume
        public let scannedBytes: UInt64
        public let limits: Limits

        public init(volume: Volume, scannedBytes: UInt64, limits: Limits) {
            self.volume = volume
            self.scannedBytes = scannedBytes
            self.limits = limits
        }

        /// Volume usage minus what the scan measured, never negative.
        public var unattributedBytes: UInt64 {
            UInt64(max(volume.used - Int64(clamping: scannedBytes), 0))
        }

        /// Set when the scan counted more than the volume reports: shared APFS blocks, clones, or
        /// files changing while the scan ran. Not an error, and not free space.
        public var overcountedBytes: UInt64 {
            UInt64(max(Int64(clamping: scannedBytes) - volume.used, 0))
        }
    }

    /// The scan root is a folder inside the volume. Its bytes can't be subtracted from the whole
    /// volume's usage, because the volume also holds everything outside that folder.
    public struct Subfolder: Sendable, Equatable {
        public let volume: Volume
        public let scannedBytes: UInt64
        public let limits: Limits

        public init(volume: Volume, scannedBytes: UInt64, limits: Limits) {
            self.volume = volume
            self.scannedBytes = scannedBytes
            self.limits = limits
        }
    }

    /// The whole volume was scanned, but some folders or cloud-only contents were not measured.
    /// The byte total is a lower bound; `gapBytes` mixes real usage with things the scan could not
    /// reach, so it is not space the user can reclaim.
    public struct PartialScan: Sendable, Equatable {
        public let volume: Volume
        public let scannedBytes: UInt64
        public let limits: Limits

        public init(volume: Volume, scannedBytes: UInt64, limits: Limits) {
            self.volume = volume
            self.scannedBytes = scannedBytes
            self.limits = limits
        }

        /// Volume usage minus what the scan measured, never negative.
        public var gapBytes: UInt64 {
            UInt64(max(volume.used - Int64(clamping: scannedBytes), 0))
        }
    }

    /// No comparison is possible. The reason is kept so the screen can say which condition failed
    /// instead of showing a number nobody should trust.
    public struct Unmeasured: Sendable, Equatable {
        public enum Reason: Sendable, Equatable {
            /// Nothing was scanned yet.
            case noScan
            /// The result on screen came from a saved scan, measured earlier than today's figures.
            case savedScan
            /// The scan was stopped before it finished.
            case incompleteScan
            /// The volume's capacity or identity could not be read.
            case volumeUnavailable
            /// The scan and the volume figures are from different volumes.
            case differentVolume
        }

        public let reason: Reason
        public let scannedBytes: UInt64?

        public init(reason: Reason, scannedBytes: UInt64?) {
            self.reason = reason
            self.scannedBytes = scannedBytes
        }
    }

    case wholeVolume(WholeVolume)
    case subfolder(Subfolder)
    case partialScan(PartialScan)
    case unmeasured(Unmeasured)

    /// Decides which of the four states applies. Order matters: a comparison needs a live,
    /// finished scan on the same volume before coverage and completeness are considered.
    public static func evaluate(scan: Scan?, volume: Volume?) -> SpaceAccounting {
        guard let scan else {
            return .unmeasured(Unmeasured(reason: .noScan, scannedBytes: nil))
        }
        let unmeasured: (Unmeasured.Reason) -> SpaceAccounting = {
            .unmeasured(Unmeasured(reason: $0, scannedBytes: scan.bytes))
        }
        guard scan.isLive else { return unmeasured(.savedScan) }
        guard scan.isComplete else { return unmeasured(.incompleteScan) }
        guard let volume, let identifier = scan.volumeIdentifier else { return unmeasured(.volumeUnavailable) }
        guard identifier == volume.identifier else { return unmeasured(.differentVolume) }
        if scan.coversVolume {
            return scan.limits.isComplete
                ? .wholeVolume(WholeVolume(volume: volume, scannedBytes: scan.bytes, limits: scan.limits))
                : .partialScan(PartialScan(volume: volume, scannedBytes: scan.bytes, limits: scan.limits))
        }
        return .subfolder(Subfolder(volume: volume, scannedBytes: scan.bytes, limits: scan.limits))
    }
}
