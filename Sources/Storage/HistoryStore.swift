import Foundation
import GRDB

/// A kind of history that can be managed or cleared as a whole. Later kinds add their
/// tables to the same clear operation without changing how the interface is used.
public enum HistoryKind: String, CaseIterable, Sendable {
    /// The per-minute samples behind the history charts, together with the hourly disk-space
    /// and per-volume capacity points that share the same clear action.
    case minuteSamples
    /// The per-minute process rankings, kept only for names that made a top ten.
    case processSamples
    /// Per-sensor temperatures and per-cluster CPU use, one row per series per minute.
    case seriesSamples
}

/// Retention choices offered to the user. The raw value is the number of days.
public enum HistoryRetention: Int, CaseIterable, Sendable {
    case oneDay = 1
    case threeDays = 3
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30

    /// The retention used until the user chooses another value.
    public static let `default`: HistoryRetention = .sevenDays

    public var seconds: TimeInterval {
        TimeInterval(rawValue) * 86_400
    }
}

/// Bytes occupied by the history database and its two SQLite sidecar files.
public struct HistoryDiskUsage: Equatable, Sendable {
    public var databaseBytes: Int64
    public var writeAheadLogBytes: Int64
    public var sharedMemoryBytes: Int64

    public init(databaseBytes: Int64, writeAheadLogBytes: Int64, sharedMemoryBytes: Int64) {
        self.databaseBytes = databaseBytes
        self.writeAheadLogBytes = writeAheadLogBytes
        self.sharedMemoryBytes = sharedMemoryBytes
    }

    public var totalBytes: Int64 {
        databaseBytes + writeAheadLogBytes + sharedMemoryBytes
    }
}

/// Errors for read-only misuse.
public enum HistoryStoreError: Error {
    case readOnly
}

/// Settings and maintenance for the history database shared by the app and the background
/// recorder. The database stores the retention value so both processes prune with the same
/// number instead of each keeping its own copy.
///
/// The retention lives in a `history_setting` key/value table created by a migration, and
/// `MetricsHistory.recordMinute` reads it inside its write transaction before pruning. A
/// clear deletes only the tables mapped to the requested kind, records the clear moment in
/// the same table so a minute that was open at that moment cannot be written back, and then
/// truncates the write-ahead log once the delete has committed. User settings are never
/// deleted by a clear.
public struct HistoryStore: Sendable {
    private let url: URL
    private let readOnly: Bool
    private let pool: DatabasePool

    /// Opens the shared history database. With `readOnly`, inspecting works but changing
    /// the settings or clearing data fails.
    public init(url: URL = MetricsHistory.defaultURL, readOnly: Bool = false) throws {
        self.url = url
        self.readOnly = readOnly
        var config = Configuration()
        config.readonly = readOnly
        // WAL is the DatabasePool default; set it explicitly so shared access does not
        // depend on a library default. Read-only pools ignore this setting.
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let pool: DatabasePool
        if readOnly {
            pool = try DatabasePool(path: url.path, configuration: config)
        } else {
            pool = try MetricsHistory.openMigratedPool(at: url, configuration: config)
        }
        self.pool = pool
        if !readOnly {
            try pool.write { db in
                try db.execute(sql: "INSERT OR IGNORE INTO history_setting (key, value) VALUES ('retentionSeconds', ?)",
                               arguments: [String(Int(HistoryRetention.default.seconds))])
            }
        }
    }

    /// The retention currently stored in the database.
    public func retention() throws -> HistoryRetention {
        try pool.read { db in
            let stored: String? = try String.fetchOne(db, sql: "SELECT value FROM history_setting WHERE key = 'retentionSeconds'")
            guard let stored, let seconds = Double(stored) else { return .default }
            let days = Int(seconds / 86_400)
            return HistoryRetention(rawValue: days) ?? .default
        }
    }

    /// Stores the retention that every process uses when it next prunes.
    public func setRetention(_ retention: HistoryRetention) throws {
        if readOnly { throw HistoryStoreError.readOnly }
        try pool.write { db in
            try db.execute(sql: "INSERT INTO history_setting (key, value) VALUES ('retentionSeconds', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [String(Int(retention.seconds))])
        }
    }

    /// Whether process names are collected. Off by default: process names are personal
    /// data, so only an explicit choice turns collection on. The value lives in the shared
    /// database, which makes the app and the background recorder see the same switch.
    public func isProcessCollectionEnabled() throws -> Bool {
        try pool.read { db in
            try HistorySetting.processCollectionEnabled(db)
        }
    }

    /// Stores the shared collection switch.
    public func setProcessCollectionEnabled(_ enabled: Bool) throws {
        if readOnly { throw HistoryStoreError.readOnly }
        try pool.write { db in
            try db.execute(sql: "INSERT INTO history_setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [HistorySetting.processCollectionKey, enabled ? "1" : "0"])
        }
    }

    /// Whether individual sensor and CPU-cluster series are collected. Off by default:
    /// the series table holds one row per sensor per minute, so only an explicit choice
    /// turns collection on. The value lives in the shared database, like the process switch.
    public func isSeriesCollectionEnabled() throws -> Bool {
        try pool.read { db in
            try HistorySetting.seriesCollectionEnabled(db)
        }
    }

    /// Stores the shared series collection switch.
    public func setSeriesCollectionEnabled(_ enabled: Bool) throws {
        if readOnly { throw HistoryStoreError.readOnly }
        try pool.write { db in
            try db.execute(sql: "INSERT INTO history_setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [HistorySetting.seriesCollectionKey, enabled ? "1" : "0"])
        }
    }

    /// Size of the database, its write-ahead log, and its shared-memory file.
    public func diskUsage() -> HistoryDiskUsage {
        func size(of path: String) -> Int64 {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return 0 }
            return size.int64Value
        }
        let databasePath = url.path
        return HistoryDiskUsage(
            databaseBytes: size(of: databasePath),
            writeAheadLogBytes: size(of: databasePath + "-wal"),
            sharedMemoryBytes: size(of: databasePath + "-shm"))
    }

    /// Deletes every stored row of `kind`, leaving other kinds and settings untouched.
    ///
    /// The deletion transaction also records when the clear happened. A recorder may still
    /// hold the minute that was open at that moment in memory; the recording methods read
    /// this marker and drop a minute that started at or before it, so cleared samples cannot
    /// come back when the minute closes.
    ///
    /// SQLite cannot checkpoint inside a transaction, so the write-ahead log is truncated
    /// afterwards in its own transaction. That step is best effort: another connection may
    /// briefly hold the log, and a blocked truncation must not turn the completed delete
    /// into an error.
    public func clear(_ kind: HistoryKind, now: Date = Date()) throws {
        if readOnly { throw HistoryStoreError.readOnly }
        try pool.write { db in
            switch kind {
            case .minuteSamples:
                try db.execute(sql: "DELETE FROM sample")
                try db.execute(sql: "DELETE FROM sample_accumulator")
                try db.execute(sql: "DELETE FROM disk_space")
                try db.execute(sql: "DELETE FROM volume_capacity")
            case .processSamples:
                try db.execute(sql: "DELETE FROM process_sample")
                try db.execute(sql: "DELETE FROM process_sample_minute")
            case .seriesSamples:
                try db.execute(sql: "DELETE FROM series_sample")
            }
            try db.execute(sql: "INSERT INTO history_setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [HistorySetting.clearedAtKey(for: kind), String(Int(now.timeIntervalSince1970))])
        }
        // Best effort: another connection can briefly hold the log, and a blocked
        // truncation must not turn the completed delete into an error.
        _ = try? pool.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
    }
}

/// Keys in `history_setting`, shared by the app and the background recorder.
enum HistorySetting {
    static let processCollectionKey = "processCollectionEnabled"
    static let seriesCollectionKey = "seriesCollectionEnabled"

    /// The moment each kind was last cleared, as seconds since 1970. The marker lives with
    /// the other shared settings so both the app and the background recorder apply the same
    /// boundary while writing a minute they had already started.
    static func clearedAtKey(for kind: HistoryKind) -> String {
        switch kind {
        case .minuteSamples: "minuteSamplesClearedAt"
        case .processSamples: "processSamplesClearedAt"
        case .seriesSamples: "seriesSamplesClearedAt"
        }
    }

    static func clearedAt(_ kind: HistoryKind, _ db: Database) throws -> Date? {
        let stored: String? = try String.fetchOne(
            db, sql: "SELECT value FROM history_setting WHERE key = ?",
            arguments: [clearedAtKey(for: kind)])
        guard let stored, let seconds = Double(stored) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Whether `time` falls at or before the last clear of `kind`. Such a minute was
    /// already accumulating when the user cleared the history, so the whole minute is
    /// discarded instead of bringing cleared samples back.
    static func wasCleared(_ time: Date, kind: HistoryKind, _ db: Database) throws -> Bool {
        guard let clearedAt = try clearedAt(kind, db) else { return false }
        return time <= clearedAt
    }

    /// Process collection stays off until the stored value says otherwise; an absent key
    /// or any value other than "1" means off.
    static func processCollectionEnabled(_ db: Database) throws -> Bool {
        let value: String? = try String.fetchOne(db, sql: "SELECT value FROM history_setting WHERE key = ?", arguments: [processCollectionKey])
        return value == "1"
    }

    /// Series collection follows the same rule as the process switch: an absent key or
    /// any value other than "1" means off.
    static func seriesCollectionEnabled(_ db: Database) throws -> Bool {
        let value: String? = try String.fetchOne(db, sql: "SELECT value FROM history_setting WHERE key = ?", arguments: [seriesCollectionKey])
        return value == "1"
    }
}
