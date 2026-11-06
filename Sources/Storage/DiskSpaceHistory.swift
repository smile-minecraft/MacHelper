import Foundation
import GRDB

/// Free space on the startup volume, one point per hour.
public struct DiskSpacePoint: Codable, Sendable, Equatable, Hashable {
    public let time: Date
    /// Bytes available for important use (what Finder shows, purgeable space included).
    public let free: Double
    public let total: Double
    public init(time: Date, free: Double, total: Double) {
        self.time = time
        self.free = free
        self.total = total
    }
}

public enum DiskSpaceReader {
    /// Startup volume capacity, or nil when the system does not report it.
    public static func current(volume: URL = URL(fileURLWithPath: "/")) -> (free: Double, total: Double)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? volume.resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity,
              total > 0 else { return nil }
        return (Double(free), Double(total))
    }
}

/// Linear trend of free space. Cleanups make free space jump up, so the slope is taken
/// only from the points after the most recent big jump.
public struct DiskSpaceForecast: Codable, Sendable, Equatable {
    /// Change of free space in bytes per day (negative: filling up).
    public let bytesPerDay: Double
    /// Days until free space reaches zero at this rate; nil when not filling up.
    public let daysUntilFull: Double?
    /// Hours of data the trend is based on.
    public let basisHours: Double
    public let latest: DiskSpacePoint

    /// Needs at least 12 hours and 6 points of data since the last jump.
    public static func compute(_ points: [DiskSpacePoint], minimumHours: Double = 12) -> DiskSpaceForecast? {
        let sorted = points.sorted { $0.time < $1.time }
        guard let latest = sorted.last else { return nil }
        // A rise of more than 2 GB or 2 % between two hours is a cleanup or a deleted VM, not a trend.
        var start = 0
        for i in sorted.indices.dropFirst() {
            let rise = sorted[i].free - sorted[i - 1].free
            if rise > max(2e9, sorted[i].total * 0.02) { start = i }
        }
        let window = Array(sorted[start...])
        guard window.count >= 6, let first = window.first else { return nil }
        let hours = latest.time.timeIntervalSince(first.time) / 3600
        guard hours >= minimumHours else { return nil }
        let xs = window.map { $0.time.timeIntervalSince(first.time) / 86_400 }
        let ys = window.map(\.free)
        let n = Double(window.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        guard sxx > 0 else { return nil }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        // Below 50 MB a day the volume is effectively stable.
        let days: Double? = slope < -50e6 ? latest.free / -slope : nil
        return DiskSpaceForecast(bytesPerDay: slope, daysUntilFull: days, basisHours: hours, latest: latest)
    }
}

extension MetricsHistory {
    /// Disk space is kept longer than the metric retention: 400 days of hourly points is a few thousand rows.
    static let diskSpaceRetention: TimeInterval = 400 * 86_400

    static func hourStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    /// Stores one point for the hour of `now` unless that hour already has one. `measure` runs
    /// only when a point is missing, outside the write transaction.
    public func recordDiskSpaceIfNeeded(now: Date = Date(),
                                        measure: () -> (free: Double, total: Double)? = { DiskSpaceReader.current() }) throws {
        let hour = Self.hourStart(now)
        let exists = try self.db.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM disk_space WHERE time = ?", arguments: [hour]) ?? false
        }
        guard !exists, let value = measure() else { return }
        try self.db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO disk_space (time, free, total) VALUES (?, ?, ?)",
                           arguments: [hour, value.free, value.total])
            try db.execute(sql: "DELETE FROM disk_space WHERE time < ?", arguments: [now.addingTimeInterval(-Self.diskSpaceRetention)])
        }
    }

    public func diskSpace(since: Date) throws -> [DiskSpacePoint] {
        try self.db.read { db in
            // A read-only connection doesn't migrate: an older database simply has no points yet.
            guard try db.tableExists("disk_space") else { return [] }
            return try Row.fetchAll(db, sql: "SELECT time, free, total FROM disk_space WHERE time >= ? ORDER BY time", arguments: [since])
                .map { DiskSpacePoint(time: $0["time"], free: $0["free"], total: $0["total"]) }
        }
    }
}
