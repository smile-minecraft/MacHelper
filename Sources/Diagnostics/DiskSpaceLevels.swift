/// How much free space on the startup disk is fine, worth a look, or a problem. Absolute amounts,
/// not a share of the disk: macOS needs about the same room for updates, swap and caches whatever
/// the disk's size. Decimal gigabytes, as Finder shows them. Shared by the app's status colors,
/// the overview and the health check.
public enum DiskSpaceLevels {
    public enum Level: Int, Comparable, Sendable {
        case healthy, low, critical
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// At least this much free is healthy.
    public static let healthyBytes: Double = 25e9
    /// Below this is critical.
    public static let criticalBytes: Double = 10e9

    public static func level(freeBytes: Double) -> Level {
        if freeBytes < criticalBytes { return .critical }
        if freeBytes < healthyBytes { return .low }
        return .healthy
    }
}
