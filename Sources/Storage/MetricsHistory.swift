import Darwin
import Foundation
import GRDB

/// Errors from opening the shared history database.
public enum HistoryDatabaseError: Error, LocalizedError, Equatable {
    /// The cross-process migration lock file could not be opened or locked.
    case migrationLockUnavailable(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .migrationLockUnavailable(let path, let code):
            "Couldn’t lock \(path) for the history migration (errno \(code))."
        }
    }
}

/// Serializes schema migration between the app and the background recorder.
///
/// GRDB's `DatabaseMigrator` checks which migrations are applied and then records them
/// without one cross-process transaction, so two processes that open a brand-new database
/// at the same time can both try to create the same table. A `busyMode` timeout does not
/// help: the migrators are not waiting on each other's SQLite lock, they are racing between
/// the check and the write. An advisory `flock` on a sidecar file makes the whole migrate
/// step run in one process at a time; the next process then finds the schema already
/// migrated. The lock is released by the system if a process crashes while holding it.
enum HistoryMigrationLock {
    static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let path = url.path + ".migration.lock"
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw HistoryDatabaseError.migrationLockUnavailable(path: path, code: errno)
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw HistoryDatabaseError.migrationLockUnavailable(path: path, code: errno)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}

/// One minute of averaged readings. Nil where the metric isn't available or wasn't sampled.
public struct MetricSample: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sample"

    /// Start of the interval (a whole minute when written by the app).
    public var time: Date
    public var cpu: Double?
    public var gpu: Double?
    public var memory: Double?
    public var temperature: Double?
    public var fan: Double?
    public var power: Double?
    public var networkIn: Double?
    public var networkOut: Double?
    public var diskRead: Double?
    public var diskWrite: Double?
    public var battery: Double?

    public init(time: Date, cpu: Double? = nil, gpu: Double? = nil, memory: Double? = nil, temperature: Double? = nil,
                fan: Double? = nil, power: Double? = nil, networkIn: Double? = nil, networkOut: Double? = nil,
                diskRead: Double? = nil, diskWrite: Double? = nil, battery: Double? = nil) {
        self.time = time
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.temperature = temperature
        self.fan = fan
        self.power = power
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.battery = battery
    }

    public static let metricColumns = ["cpu", "gpu", "memory", "temperature", "fan", "power", "networkIn", "networkOut",
                                       "diskRead", "diskWrite", "battery"]
}

/// Per-minute metric history in SQLite (~/Library/Application Support/MacHelper/history.sqlite),
/// kept for `retention` (7 days by default).
public final class MetricsHistory: Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/MacHelper/history.sqlite")
    }

    let db: any DatabaseWriter
    public let retention: TimeInterval

    /// Opens (creating if needed) the database. `readOnly` for tools that only query it.
    public init(url: URL = MetricsHistory.defaultURL, retention: TimeInterval = 7 * 86_400, readOnly: Bool = false) throws {
        self.retention = retention
        var config = Configuration()
        config.readonly = readOnly
        // WAL is the DatabasePool default; set it explicitly so shared access does not
        // depend on a library default. Read-only pools ignore this setting.
        config.journalMode = .wal
        // Two processes may open this file (app and background recorder). GRDB returns
        // SQLITE_BUSY immediately by default; wait instead so a lost lock race is not an error.
        config.busyMode = .timeout(5)
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let pool: DatabasePool
        if readOnly {
            pool = try DatabasePool(path: url.path, configuration: config)
        } else {
            pool = try Self.openMigratedPool(at: url, configuration: config)
        }
        db = pool
        if !readOnly {
            try pool.write { db in
                try db.execute(sql: "INSERT OR IGNORE INTO history_setting (key, value) VALUES ('retentionSeconds', ?)",
                               arguments: [String(Int(retention))])
            }
        }
    }

    /// In-memory database, for tests.
    public init(inMemory: Void, retention: TimeInterval = 7 * 86_400) throws {
        self.retention = retention
        let queue = try DatabaseQueue()
        db = queue
        try Self.migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO history_setting (key, value) VALUES ('retentionSeconds', ?)",
                           arguments: [String(Int(retention))])
        }
    }

    /// Opens a writable pool and runs the published migrations while holding the
    /// cross-process lock. Both the app and the background recorder call this when they
    /// open the database, so the first launch after an update cannot race the other process.
    ///
    /// The lock covers the pool's own `journal_mode = WAL` step too: two processes switching
    /// a brand-new file to WAL at the same moment can fail with `database is locked` before
    /// the migrator is reached, and SQLite's busy timeout does not wait for that step.
    static func openMigratedPool(at url: URL, configuration: Configuration) throws -> DatabasePool {
        try HistoryMigrationLock.withLock(at: url) {
            let pool = try DatabasePool(path: url.path, configuration: configuration)
            try migrator.migrate(pool)
            return pool
        }
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "sample") { t in
                t.column("time", .datetime).primaryKey(onConflict: .replace)
                for c in MetricSample.metricColumns { t.column(c, .double) }
            }
        }
        m.registerMigration("v2") { db in
            // Per-column running sums and counts, so minute averages stay correct when a
            // minute was written partly by the app and partly by the background recorder.
            try db.create(table: "sample_accumulator") { t in
                t.column("time", .datetime).notNull()
                t.column("column", .text).notNull()
                t.column("total_sum", .double).notNull()
                t.column("total_count", .integer).notNull()
                t.primaryKey(["time", "column"])
            }
        }
        m.registerMigration("v3") { db in
            try db.create(table: "history_setting") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        m.registerMigration("v4") { db in
            // One row per name that made a minute's top ten by CPU or by memory. Only the
            // name is stored, never a path or arguments. Sums and counts let two writers
            // merge a shared minute without averaging averages.
            try db.create(table: "process_sample") { t in
                t.column("time", .datetime).notNull()
                t.column("name", .text).notNull()
                t.column("cpu_sum", .double).notNull()
                t.column("cpu_count", .integer).notNull()
                t.column("memory_sum", .double).notNull()
                t.column("memory_count", .integer).notNull()
                t.primaryKey(["time", "name"])
            }
            // The unreadable count belongs to the whole minute, not to one name.
            try db.create(table: "process_sample_minute") { t in
                t.column("time", .datetime).primaryKey()
                t.column("hidden_count", .integer).notNull()
            }
        }
        m.registerMigration("v5") { db in
            // One row per series per minute. Sums and counts let the app and the background
            // recorder merge a shared minute without averaging averages. Series names are
            // opaque strings such as "temperature.PMU tdie1" or "cpu.performance".
            try db.create(table: "series_sample") { t in
                t.column("time", .datetime).notNull()
                t.column("series", .text).notNull()
                t.column("value_sum", .double).notNull()
                t.column("value_count", .integer).notNull()
                t.primaryKey(["time", "series"])
            }
        }
        m.registerMigration("v6") { db in
            // Free space on the startup volume, one row per hour, kept for 400 days.
            try db.create(table: "disk_space") { t in
                t.column("time", .datetime).primaryKey()
                t.column("free", .double).notNull()
                t.column("total", .double).notNull()
            }
        }
        m.registerMigration("v7") { db in
            // Per-volume hourly capacity. The v6 disk_space rows stay untouched: they carry
            // no volume identity, so they are never reassigned to one of the new volumes.
            try VolumeCapacityHistory.createTable(db)
        }
        return m
    }

    /// Merge-by-column write for minute samples shared by the app and the background
    /// recorder. A column with an accumulator absorbs the new observations by adding sums
    /// and counts, so the displayed value stays a true average; a v1 row (average only,
    /// no counts) is left untouched rather than given an invented weight. A writer with
    /// no observations for a column never overwrites it. Pruning removes expired process
    /// rows too, so process names still age out after collection is turned off. A minute at
    /// or before the last clear of this kind is dropped whole: it was accumulating in
    /// memory when the user cleared the history.
    public func recordMinute(_ minute: FinishedMinute, now: Date = Date()) throws {
        try db.write { db in
            let stored: String? = try String.fetchOne(db, sql: "SELECT value FROM history_setting WHERE key = 'retentionSeconds'")
            let effectiveRetention = stored.flatMap { Double($0) } ?? retention
            let cutoff = now.addingTimeInterval(-effectiveRetention)
            let wasCleared = try HistorySetting.wasCleared(minute.time, kind: .minuteSamples, db)
            if !wasCleared {
                try db.execute(sql: "INSERT OR IGNORE INTO sample (time) VALUES (?)", arguments: [minute.time])
                for column in MetricSample.metricColumns {
                    guard let totals = minute.totals[column], totals.count > 0 else { continue }
                    let accumulator = try Row.fetchOne(
                        db, sql: "SELECT total_sum, total_count FROM sample_accumulator WHERE time = ? AND column = ?",
                        arguments: [minute.time, column])
                    if let accumulator {
                        let existingSum: Double = accumulator["total_sum"]
                        let existingCount: Int64 = accumulator["total_count"]
                        let mergedSum = existingSum + totals.sum
                        let mergedCount = existingCount + Int64(totals.count)
                        try db.execute(sql: "UPDATE sample_accumulator SET total_sum = ?, total_count = ? WHERE time = ? AND column = ?",
                                       arguments: [mergedSum, mergedCount, minute.time, column])
                        try db.execute(sql: "UPDATE sample SET \(column) = ? WHERE time = ?",
                                       arguments: [mergedSum / Double(mergedCount), minute.time])
                    } else {
                        // A v1 row has an average but no sample count: keep the legacy value.
                        let legacy: Double? = try Double.fetchOne(db, sql: "SELECT \(column) FROM sample WHERE time = ?",
                                                                  arguments: [minute.time])
                        if legacy == nil {
                            try db.execute(sql: "INSERT INTO sample_accumulator (time, column, total_sum, total_count) VALUES (?, ?, ?, ?)",
                                           arguments: [minute.time, column, totals.sum, totals.count])
                            try db.execute(sql: "UPDATE sample SET \(column) = ? WHERE time = ?",
                                           arguments: [totals.sum / Double(totals.count), minute.time])
                        }
                    }
                }
            }
            try db.execute(sql: "DELETE FROM sample WHERE time < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM sample_accumulator WHERE time < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM process_sample WHERE time < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM process_sample_minute WHERE time < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM series_sample WHERE time < ?", arguments: [cutoff])
        }
    }

    /// Samples since `since`, averaged into buckets of `bucket` seconds (one row per bucket).
    public func samples(since: Date, bucket: TimeInterval = 60) throws -> [MetricSample] {
        let averages = MetricSample.metricColumns.map { "AVG(\($0)) AS \($0)" }.joined(separator: ", ")
        // Dates are stored as "YYYY-MM-DD HH:MM:SS.SSS" text; bucket on the unix time.
        let sql = """
            SELECT datetime((CAST(strftime('%s', time) AS INTEGER) / :bucket) * :bucket, 'unixepoch') AS time, \(averages)
            FROM sample WHERE time >= :since
            GROUP BY CAST(strftime('%s', time) AS INTEGER) / :bucket ORDER BY time
            """
        return try db.read { db in
            try MetricSample.fetchAll(db, sql: sql, arguments: ["bucket": max(Int(bucket), 1), "since": since])
        }
    }

    public func count() throws -> Int {
        try db.read { try MetricSample.fetchCount($0) }
    }

    /// Stores one finished minute of process usage. Does nothing while process collection
    /// is off. Two writers record the same minute by adding their sums and counts, so the
    /// average keeps every observation. Only the process name is stored. A minute with no
    /// readable process still keeps its hidden count, and pruning covers both tables. A
    /// minute at or before the last clear of this kind is dropped whole, names included.
    public func recordProcessMinute(_ minute: FinishedProcessMinute, now: Date = Date()) throws {
        try db.write { db in
            let stored: String? = try String.fetchOne(db, sql: "SELECT value FROM history_setting WHERE key = 'retentionSeconds'")
            let effectiveRetention = stored.flatMap { Double($0) } ?? retention
            let cutoff = now.addingTimeInterval(-effectiveRetention)

            let enabled = try HistorySetting.processCollectionEnabled(db)
            guard enabled else { return }
            let wasCleared = try HistorySetting.wasCleared(minute.time, kind: .processSamples, db)
            if !wasCleared {
                for (name, totals) in minute.processes {
                    try db.execute(sql: """
                        INSERT INTO process_sample (time, name, cpu_sum, cpu_count, memory_sum, memory_count)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(time, name) DO UPDATE SET
                            cpu_sum = cpu_sum + excluded.cpu_sum,
                            cpu_count = cpu_count + excluded.cpu_count,
                            memory_sum = memory_sum + excluded.memory_sum,
                            memory_count = memory_count + excluded.memory_count
                        """, arguments: [minute.time, name, totals.cpu.sum, totals.cpu.count,
                                        totals.memoryBytes.sum, totals.memoryBytes.count])
                }
                try db.execute(sql: """
                    INSERT INTO process_sample_minute (time, hidden_count) VALUES (?, ?)
                    ON CONFLICT(time) DO UPDATE SET hidden_count = MAX(hidden_count, excluded.hidden_count)
                    """, arguments: [minute.time, minute.hiddenCount])
            }

            try db.execute(sql: "DELETE FROM sample WHERE time < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM sample_accumulator WHERE time < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM process_sample WHERE time < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM process_sample_minute WHERE time < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM series_sample WHERE time < ?", arguments: [cutoff])
        }
    }

    public func processUsage(since: Date, until: Date = Date(), top: Int = 10) throws -> ProcessUsageHistory {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT name, cpu_sum, cpu_count, memory_sum, memory_count
                FROM process_sample WHERE time >= ? AND time < ?
                """, arguments: [since, until])
            var minutesByName: [String: [(Double, Double)]] = [:]
            for row in rows {
                let name: String = row["name"]
                let cpuSum: Double = row["cpu_sum"]
                let cpuCount: Int64 = row["cpu_count"]
                let memorySum: Double = row["memory_sum"]
                let memoryCount: Int64 = row["memory_count"]
                let cpuAverage = cpuCount > 0 ? cpuSum / Double(cpuCount) : 0
                let memoryAverage = memoryCount > 0 ? memorySum / Double(memoryCount) : 0
                minutesByName[name, default: []].append((cpuAverage, memoryAverage))
            }
            var cpuRanks: [ProcessUsageRank] = []
            var memoryRanks: [ProcessUsageRank] = []
            for (name, minutes) in minutesByName {
                let averageCPU = minutes.map(\.0).reduce(0, +) / Double(minutes.count)
                let averageMemory = minutes.map(\.1).reduce(0, +) / Double(minutes.count)
                let rank = ProcessUsageRank(name: name, averageCPU: averageCPU,
                                           averageMemoryBytes: averageMemory, minuteCount: minutes.count)
                cpuRanks.append(rank)
                memoryRanks.append(rank)
            }
            cpuRanks.sort { left, right in
                if left.averageCPU != right.averageCPU { return left.averageCPU > right.averageCPU }
                return left.name < right.name
            }
            memoryRanks.sort { left, right in
                if left.averageMemoryBytes != right.averageMemoryBytes { return left.averageMemoryBytes > right.averageMemoryBytes }
                return left.name < right.name
            }
            if top > 0 {
                cpuRanks = Array(cpuRanks.prefix(top))
                memoryRanks = Array(memoryRanks.prefix(top))
            }
            let hiddenCount: Int64 = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(MAX(hidden_count), 0) FROM process_sample_minute
                WHERE time >= ? AND time < ?
                """, arguments: [since, until]) ?? 0
            let totalMinuteCount = Int(floor(until.timeIntervalSince(since) / 60.0))
            return ProcessUsageHistory(byCPU: cpuRanks, byMemory: memoryRanks,
                                      totalMinuteCount: totalMinuteCount, hiddenCount: Int(hiddenCount))
        }
    }

    /// Stores one finished minute of individual series. Does nothing while series
    /// collection is off. Two writers record the same minute by adding their sums and
    /// counts, so the average keeps every observation. Pruning must cover the series table.
    /// A minute at or before the last clear of this kind is dropped whole.
    public func recordSeriesMinute(_ minute: FinishedSeriesMinute, now: Date = Date()) throws {
        try db.write { db in
            let stored: String? = try String.fetchOne(db, sql: "SELECT value FROM history_setting WHERE key = 'retentionSeconds'")
            let effectiveRetention = stored.flatMap { Double($0) } ?? retention
            let cutoff = now.addingTimeInterval(-effectiveRetention)

            let enabled = try HistorySetting.seriesCollectionEnabled(db)
            guard enabled else { return }
            let wasCleared = try HistorySetting.wasCleared(minute.time, kind: .seriesSamples, db)
            if !wasCleared {
                for (series, totals) in minute.totals {
                    guard totals.count > 0 else { continue }
                    try db.execute(sql: """
                        INSERT INTO series_sample (time, series, value_sum, value_count)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(time, series) DO UPDATE SET
                            value_sum = value_sum + excluded.value_sum,
                            value_count = value_count + excluded.value_count
                        """, arguments: [minute.time, series, totals.sum, totals.count])
                }
            }

            try db.execute(sql: "DELETE FROM series_sample WHERE time < ?", arguments: [cutoff])
        }
    }

    /// Every series with stored data, ordered by key, and the last minute it was seen.
    public func availableSeries() throws -> [AvailableSeries] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT series, MAX(time) AS lastSeen FROM series_sample
                GROUP BY series ORDER BY series
                """).map { row in
                AvailableSeries(series: row["series"], lastSeen: row["lastSeen"])
            }
        }
    }

    /// Averages for `series` in `since..<until`, one point per stored minute and in time
    /// order. A minute without an observation is absent, never zero.
    public func seriesSamples(_ series: String, since: Date, until: Date = Date()) throws -> [SeriesSample] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT time, value_sum / value_count AS value
                FROM series_sample
                WHERE series = ? AND time >= ? AND time < ?
                ORDER BY time
                """, arguments: [series, since, until]).map { row in
                SeriesSample(time: row["time"], value: row["value"])
            }
        }
    }

    /// `seriesSamples` for several series in one query, keyed by series. A series without
    /// stored minutes in the window is absent from the result.
    public func seriesSamples(_ series: [String], since: Date, until: Date = Date()) throws -> [String: [SeriesSample]] {
        guard !series.isEmpty else { return [:] }
        return try db.read { db in
            let placeholders = Array(repeating: "?", count: series.count).joined(separator: ", ")
            var arguments = StatementArguments(series)
            arguments += [since, until]
            var result: [String: [SeriesSample]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT series, time, value_sum / value_count AS value
                FROM series_sample
                WHERE series IN (\(placeholders)) AND time >= ? AND time < ?
                ORDER BY series, time
                """, arguments: arguments) {
                result[row["series"], default: []].append(SeriesSample(time: row["time"], value: row["value"]))
            }
            return result
        }
    }

    /// `seriesSamples` for several series, averaged into `bucket`-second buckets and keyed
    /// by series. The rows are grouped by bucket *and* by a run of consecutive stored
    /// minutes, so a gap in the underlying minutes is never averaged away: a gap inside one
    /// bucket becomes two buckets, and `lastSampleTime` records where each bucket's data
    /// really ends. A bucket with no stored minute is absent, never zero.
    public func seriesBuckets(_ series: [String], since: Date, until: Date = Date(),
                              bucket: TimeInterval = 60) throws -> [String: [SeriesBucket]] {
        guard !series.isEmpty else { return [:] }
        let seconds = max(Int(bucket), 60)
        return try db.read { db in
            let placeholders = Array(repeating: "?", count: series.count).joined(separator: ", ")
            var arguments = StatementArguments(series)
            arguments += [since, until, seconds]
            var result: [String: [SeriesBucket]] = [:]
            // Minutes are stored one per minute. A jump larger than 60 s is a recording
            // gap, not a bucket boundary, so it starts a new run before the bucket average.
            for row in try Row.fetchAll(db, sql: """
                WITH ordered AS (
                    SELECT series, time, value_sum, value_count,
                           LAG(time) OVER (PARTITION BY series ORDER BY time) AS previous_time
                    FROM series_sample
                    WHERE series IN (\(placeholders)) AND time >= ? AND time < ?
                ),
                marked AS (
                    SELECT series, time, value_sum, value_count,
                           CASE WHEN previous_time IS NULL
                                     OR CAST(strftime('%s', time) AS INTEGER)
                                        - CAST(strftime('%s', previous_time) AS INTEGER) > 60
                                THEN 1 ELSE 0 END AS new_run
                    FROM ordered
                ),
                runs AS (
                    SELECT series, time, value_sum, value_count,
                           SUM(new_run) OVER (PARTITION BY series ORDER BY time) AS run_id
                    FROM marked
                )
                SELECT series,
                       MIN(time) AS time,
                       SUM(value_sum) / SUM(value_count) AS value,
                       MAX(time) AS lastSampleTime,
                       COUNT(*) AS storedMinuteCount
                FROM runs
                GROUP BY series, CAST(strftime('%s', time) AS INTEGER) / ?, run_id
                ORDER BY series, time
                """, arguments: arguments) {
                result[row["series"], default: []].append(SeriesBucket(
                    time: row["time"], value: row["value"],
                    lastSampleTime: row["lastSampleTime"], storedMinuteCount: row["storedMinuteCount"]))
            }
            return result
        }
    }
}

/// Collects readings for the current minute and yields their per-column sums and counts
/// when the minute ends.
public struct MinuteAccumulator: Sendable {
    private var minute: Date?
    private var sums: [String: (Double, Int)] = [:]

    public init() {}

    /// Adds a reading; returns the finished previous minute's totals when `date` starts
    /// a new minute. The history store turns these totals into averages.
    public mutating func addTracked(_ column: String, _ value: Double, at date: Date = Date()) -> FinishedMinute? {
        guard value.isFinite else { return nil }
        let m = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var finished: FinishedMinute?
        if let current = minute, current != m {
            finished = flushTracked(current)
        }
        minute = m
        let (s, n) = sums[column] ?? (0, 0)
        sums[column] = (s + value, n + 1)
        return finished
    }

    private mutating func flushTracked(_ time: Date) -> FinishedMinute? {
        defer { sums = [:] }
        guard !sums.isEmpty else { return nil }
        let totals = sums.mapValues { ColumnTotals(sum: $0.0, count: $0.1) }
        return FinishedMinute(time: time, totals: totals)
    }
}
