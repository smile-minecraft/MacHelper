import Foundation

/// The figures a scan page shows while a scan runs.
///
/// The scanning page polls a running scan a few times a second, and those readings have to add up
/// to what the finished scan reports: a number that steps back, or restarts halfway through, reads
/// as a broken scan. A readout therefore only ever grows, and a scan that replaces another starts
/// from a fresh readout instead of keeping the old totals.
public struct ScanProgressReadout: Sendable {
    /// The figures to show. Zero until a scan measures something.
    public private(set) var progress = ScanProgressReadout.empty

    public init() {}

    /// Records the counters a poll just read. Each counter keeps the largest value it has seen:
    /// readings taken on several threads, or a poll that arrives after a later one, can then never
    /// make the size or the file count jump backwards on screen.
    public mutating func update(_ next: ScanProgress) {
        let shown = progress
        progress = ScanProgress(files: max(shown.files, next.files),
                                directories: max(shown.directories, next.directories),
                                bytes: max(shown.bytes, next.bytes),
                                unreadableDirectories: max(shown.unreadableDirectories, next.unreadableDirectories),
                                cloudOnlyDirectories: max(shown.cloudOnlyDirectories, next.cloudOnlyDirectories),
                                protectedDirectories: max(shown.protectedDirectories, next.protectedDirectories))
    }

    /// Forgets everything, for a scan that is starting: its counters begin at zero and are allowed
    /// to be smaller than the previous scan's.
    public mutating func reset() { progress = Self.empty }

    private static let empty = ScanProgress(files: 0, directories: 0, bytes: 0, unreadableDirectories: 0)
}
