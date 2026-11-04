import Foundation
import GRDB

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

    private let db: any DatabaseWriter
    public let retention: TimeInterval

    /// Opens (creating if needed) the database. `readOnly` for tools that only query it.
    public init(url: URL = MetricsHistory.defaultURL, retention: TimeInterval = 7 * 86_400, readOnly: Bool = false) throws {
        self.retention = retention
        var config = Configuration()
        config.readonly = readOnly
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        db = pool
        if !readOnly { try Self.migrator.migrate(pool) }
    }

    /// In-memory database, for tests.
    public init(inMemory: Void, retention: TimeInterval = 7 * 86_400) throws {
        self.retention = retention
        let queue = try DatabaseQueue()
        db = queue
        try Self.migrator.migrate(queue)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "sample") { t in
                t.column("time", .datetime).primaryKey(onConflict: .replace)
                for c in MetricSample.metricColumns { t.column(c, .double) }
            }
        }
        return m
    }

    public func append(_ sample: MetricSample) throws {
        try db.write { db in
            try sample.insert(db)
            try db.execute(sql: "DELETE FROM sample WHERE time < ?", arguments: [Date().addingTimeInterval(-retention)])
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
}

/// Collects readings for the current minute and yields their averages when the minute ends.
public struct MinuteAccumulator: Sendable {
    private var minute: Date?
    private var sums: [String: (Double, Int)] = [:]

    public init() {}

    /// Adds a reading; returns the finished previous minute's sample when `date` starts a new minute.
    public mutating func add(_ column: String, _ value: Double, at date: Date = Date()) -> MetricSample? {
        guard value.isFinite else { return nil }
        let m = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var finished: MetricSample?
        if let current = minute, current != m {
            finished = flush(current)
        }
        minute = m
        let (s, n) = sums[column] ?? (0, 0)
        sums[column] = (s + value, n + 1)
        return finished
    }

    private mutating func flush(_ time: Date) -> MetricSample? {
        defer { sums = [:] }
        guard !sums.isEmpty else { return nil }
        func avg(_ c: String) -> Double? { sums[c].map { $0.0 / Double($0.1) } }
        return MetricSample(time: time, cpu: avg("cpu"), gpu: avg("gpu"), memory: avg("memory"), temperature: avg("temperature"),
                            fan: avg("fan"), power: avg("power"), networkIn: avg("networkIn"), networkOut: avg("networkOut"),
                            diskRead: avg("diskRead"), diskWrite: avg("diskWrite"), battery: avg("battery"))
    }
}
