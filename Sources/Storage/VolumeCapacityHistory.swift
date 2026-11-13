import Foundation
import GRDB

/// A capacity reading for one volume: bytes available for important use and the volume's
/// total capacity. A reading the system could not produce has no value of this type, so the
/// store never turns "unknown" into zero bytes.
public struct VolumeCapacity: Sendable, Equatable, Hashable {
    /// Bytes available for important use (what Finder shows, purgeable space included).
    public let free: Double
    /// Total capacity in bytes.
    public let total: Double

    /// Returns nil when the numbers are not a usable reading: a non-finite value, a
    /// non-positive total, or negative free space. Free space above the total is accepted
    /// because macOS can count purgeable space in the available capacity.
    public init?(free: Double, total: Double) {
        guard free.isFinite, total.isFinite, total > 0, free >= 0 else { return nil }
        self.free = free
        self.total = total
    }
}

/// One hourly capacity point stored for one volume. `volume` is an opaque identifier chosen
/// by the caller; storage never parses it, and legacy single-volume rows are never assigned
/// to it.
public struct VolumeCapacityPoint: Codable, Sendable, Equatable, Hashable, FetchableRecord {
    public static let databaseTableName = "volume_capacity"

    public let volume: String
    /// Start of the hour the point belongs to.
    public let time: Date
    public let free: Double
    public let total: Double

    public init(volume: String, time: Date, free: Double, total: Double) {
        self.volume = volume
        self.time = time
        self.free = free
        self.total = total
    }
}

public enum VolumeCapacityHistoryError: Error, Equatable {
    /// An empty identifier would merge unrelated volumes into one history.
    case emptyVolumeIdentifier
}

/// Per-volume capacity history in the shared history database, one point per volume per hour.
///
/// The table is separate from the v6 `disk_space` table, which keeps the startup volume's
/// history under a single implicit identity. The v7 migration creates the table without
/// rewriting or reassigning those rows: an old database has no volume identifiers that could
/// prove which volume a legacy row belongs to.
public struct VolumeCapacityHistory: Sendable {
    /// Same horizon as the v6 `disk_space` history: 400 days of hourly points.
    public static let defaultRetention: TimeInterval = 400 * 86_400

    private let db: any DatabaseWriter
    /// Points older than this are removed when a point is stored.
    public let retention: TimeInterval

    public init(db: any DatabaseWriter, retention: TimeInterval = Self.defaultRetention) {
        self.db = db
        self.retention = retention
    }

    /// Uses the connection of an already-open shared history database.
    public init(history: MetricsHistory, retention: TimeInterval = Self.defaultRetention) {
        self.init(db: history.db, retention: retention)
    }

    /// Creates the per-volume capacity table. This is the step the v7 migration registers;
    /// it does not touch existing tables or rows.
    public static func createTable(_ db: Database) throws {
        try db.create(table: VolumeCapacityPoint.databaseTableName) { t in
            t.column("volume", .text).notNull()
            t.column("time", .datetime).notNull()
            t.column("free", .double).notNull()
            t.column("total", .double).notNull()
            // One point per volume per hour. A second write in the same hour is ignored,
            // so two writers cannot create duplicates or average two measurements.
            t.primaryKey(["volume", "time"])
        }
    }

    /// Stores one hourly point for `volume`. The first measurement of an hour wins; later
    /// writes in that hour leave the stored point unchanged. A nil capacity stores nothing,
    /// which keeps an unavailable reading from becoming a zero-byte row. Points older than
    /// `retention`, across every volume, are pruned in the same transaction.
    ///
    /// A reading taken at or before the last clear of the monitoring history is dropped
    /// whole: the recorder may still hold a value that was sampled before the user cleared
    /// the history, and writing it afterwards would bring cleared data back. A reading taken
    /// after the clear is new data and may be stored in the same hour.
    ///
    /// Returns whether a new point was inserted (`false` for a duplicate hour, a nil
    /// capacity, or a reading from the cleared period).
    @discardableResult
    public func record(_ capacity: VolumeCapacity?, volume: String,
                       at date: Date = Date(), now: Date = Date()) throws -> Bool {
        guard !volume.isEmpty else { throw VolumeCapacityHistoryError.emptyVolumeIdentifier }
        guard let capacity else { return false }
        return try record([VolumeCapacityReading(volume: volume, capacity: capacity)],
                          at: date, now: now) > 0
    }

    /// Stores every usable reading of one sample in a single write transaction. One
    /// authorization decision and one commit cover the whole sample, so a disable cannot
    /// split a sample in half. Returns the number of newly inserted points; duplicates,
    /// unknown capacities, and a reading taken at or before the last clear insert nothing.
    @discardableResult
    public func record(_ readings: [VolumeCapacityReading], at date: Date,
                       now: Date = Date()) throws -> Int {
        var usable: [(volume: String, capacity: VolumeCapacity)] = []
        usable.reserveCapacity(readings.count)
        for reading in readings {
            guard let capacity = reading.capacity else { continue }
            guard !reading.volume.isEmpty else { throw VolumeCapacityHistoryError.emptyVolumeIdentifier }
            usable.append((reading.volume, capacity))
        }
        guard !usable.isEmpty else { return 0 }
        let hour = Self.hourStart(date)
        let cutoff = now.addingTimeInterval(-retention)
        return try db.write { db in
            // Standalone stores used before the v7 migration have no settings table; they
            // also cannot have a clear marker, so nothing is dropped. The marker has whole
            // seconds, so the reading is compared at the same granularity: a reading in the
            // same second as the clear stays on the cleared side.
            if try db.tableExists("history_setting"),
               let clearedAt = try HistorySetting.clearedAt(.minuteSamples, db),
               date.timeIntervalSince1970.rounded(.down) <= clearedAt.timeIntervalSince1970 {
                return 0
            }
            var inserted = 0
            for (volume, capacity) in usable {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO volume_capacity (volume, time, free, total)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [volume, hour, capacity.free, capacity.total])
                inserted += db.changesCount
            }
            try db.execute(sql: "DELETE FROM volume_capacity WHERE time < ?", arguments: [cutoff])
            return inserted
        }
    }

    /// Points for `volume` in `since..<until`, oldest first. Hours without a stored point
    /// stay absent; the result is never padded with zeros. A database opened before the v7
    /// migration has no table and therefore no points, which lets read-only tools query an
    /// older file without failing.
    public func points(volume: String, since: Date, until: Date? = nil) throws -> [VolumeCapacityPoint] {
        try db.read { db in
            guard try db.tableExists(VolumeCapacityPoint.databaseTableName) else { return [] }
            if let until {
                return try VolumeCapacityPoint.fetchAll(db, sql: """
                    SELECT volume, time, free, total FROM volume_capacity
                    WHERE volume = ? AND time >= ? AND time < ?
                    ORDER BY time
                    """, arguments: [volume, since, until])
            }
            return try VolumeCapacityPoint.fetchAll(db, sql: """
                SELECT volume, time, free, total FROM volume_capacity
                WHERE volume = ? AND time >= ?
                ORDER BY time
                """, arguments: [volume, since])
        }
    }

    /// Deletes every stored volume capacity point and leaves other history tables alone.
    /// `HistoryStore.clear` calls this inside its existing write transaction; calling an
    /// instance method there would start a nested write and is not allowed.
    public static func deleteAll(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM volume_capacity")
    }

    /// `deleteAll` for callers that are not already inside a write transaction.
    public func clear() throws {
        try db.write { db in try Self.deleteAll(db) }
    }

    /// Start of the hour containing `date`, using the same whole-hour boundary as the
    /// existing disk space history.
    static func hourStart(_ date: Date) -> Date {
        MetricsHistory.hourStart(date)
    }
}

/// A capacity reading from one mounted volume. The caller maps the disk identity and the two
/// capacity values; storage never parses the identifier. `capacity` is nil when the system
/// could not report a usable reading, which is stored as nothing rather than zero bytes.
public struct VolumeCapacityReading: Sendable, Equatable {
    public let volume: String
    public let capacity: VolumeCapacity?

    public init(volume: String, capacity: VolumeCapacity?) {
        self.volume = volume
        self.capacity = capacity
    }

    /// Builds a reading from the values the disk layer reports. Returns nil when the volume
    /// has no stable identity or either capacity value is missing, so a caller cannot store
    /// an unknown reading as zero or attach it to another volume.
    public init?(volumeID: String?, totalBytes: Int64?, availableBytes: Int64?) {
        guard let volumeID, !volumeID.isEmpty,
              let totalBytes, let availableBytes,
              let capacity = VolumeCapacity(free: Double(availableBytes), total: Double(totalBytes))
        else { return nil }
        self.init(volume: volumeID, capacity: capacity)
    }
}

/// What one `VolumeCapacityRecorder.tick` did. The caller uses this to refresh the heartbeat
/// without guessing from the history table, and tests can distinguish "still waiting for the
/// sampler" from "the hour is done".
public struct VolumeCapacityTickOutcome: Sendable, Equatable {
    /// A sample was started on the worker on this tick. The sampler may still be running.
    public let didStart: Bool
    /// A sample finished and its readings were applied on this tick. `readings` may be empty
    /// when the disk sampler returned no recordable volume.
    public let didSample: Bool
    /// A finished sample was dropped because recording was disabled or the profile became
    /// unreadable before it could be applied. No history row was written.
    public let didDiscard: Bool
    /// The hour the finished sample belongs to now has its pass, so no more sampling is
    /// needed for that hour.
    public let hourCompleted: Bool

    public init(didStart: Bool = false, didSample: Bool, didDiscard: Bool = false, hourCompleted: Bool) {
        self.didStart = didStart
        self.didSample = didSample
        self.didDiscard = didDiscard
        self.hourCompleted = hourCompleted
    }
}

/// The outcome of applying one finished sample. `authorized` is false when the background
/// recording session changed while the sample was in flight; the sample is then dropped whole
/// and no history row is written.
public struct VolumeCapacityApplyResult: Sendable, Equatable {
    public let authorized: Bool
    public let inserted: Int
    public let readingCount: Int

    public init(authorized: Bool, inserted: Int, readingCount: Int) {
        self.authorized = authorized
        self.inserted = inserted
        self.readingCount = readingCount
    }

    public static let discarded = VolumeCapacityApplyResult(authorized: false, inserted: 0, readingCount: 0)

    public static func applied(inserted: Int, readingCount: Int) -> VolumeCapacityApplyResult {
        VolumeCapacityApplyResult(authorized: true, inserted: inserted, readingCount: readingCount)
    }
}

/// A capacity write that failed outside the database's own error type, for example because
/// the profile lock could not be acquired. The message is what the heartbeat reports.
public enum VolumeCapacityRecorderError: Error, LocalizedError, Equatable {
    case applyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .applyFailed(let message):
            "Couldn’t write volume capacity history: \(message)"
        }
    }
}

/// The result the worker hands back to the recorder. Applying happens on the worker too, so a
/// slow SQLite write cannot block the agent's sampling loop or its heartbeat.
enum VolumeCapacityWorkResult: Sendable {
    case applied(VolumeCapacityApplyResult)
    case failed(String)
}

/// Runs the blocking disk sampler and the SQLite write away from the recorder's loop. Disk
/// Arbitration has no timeout and SQLite may wait for another writer, so neither a stuck
/// daemon nor a busy database may stop module sampling or the heartbeat. At most one sample is
/// in flight; a request made while one is running is ignored. A cancel before the apply starts
/// drops the result. The recorder only polls for finished results.
final class VolumeCapacitySampleWorker: @unchecked Sendable {
    typealias Apply = @Sendable ([VolumeCapacityReading], Date, Date, String) throws -> VolumeCapacityApplyResult

    private let queue = DispatchQueue(label: "com.machelper.volume-capacity-sampler", qos: .utility)
    private let lock = NSLock()
    private let sampler: @Sendable () -> [VolumeCapacityReading]
    private let apply: Apply
    private var generation: UInt64 = 0
    private var running = false
    private var finished: (generation: UInt64, result: VolumeCapacityWorkResult)?

    init(sampler: @escaping @Sendable () -> [VolumeCapacityReading],
         apply: @escaping Apply) {
        self.sampler = sampler
        self.apply = apply
    }

    /// Starts one sample at `date` unless one is already running. The sample and its write
    /// run on the worker. Returns the generation token that `takeResult` must match, or nil
    /// when a sample is already in flight.
    func start(at date: Date, session: String, now: Date) -> UInt64? {
        lock.lock()
        guard !running else {
            lock.unlock()
            return nil
        }
        running = true
        let token = generation
        lock.unlock()
        queue.async { [self] in
            let readings = sampler()
            lock.lock()
            // A cancel while the sampler was blocked makes this result obsolete; do not keep
            // it for a later generation and do not start the write.
            let stillCurrent = generation == token
            lock.unlock()
            guard stillCurrent else {
                lock.lock()
                running = false
                lock.unlock()
                return
            }
            let result: VolumeCapacityWorkResult
            do {
                result = .applied(try apply(readings, date, now, session))
            } catch {
                result = .failed(error.localizedDescription)
            }
            lock.lock()
            if generation == token {
                finished = (token, result)
            }
            running = false
            lock.unlock()
        }
        return token
    }

    /// The finished result for `generation`, if it is ready. Clears it so it is applied once.
    func takeResult(generation token: UInt64) -> VolumeCapacityWorkResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let finished, finished.generation == token else { return nil }
        self.finished = nil
        return finished.result
    }

    /// Drops any finished result. A sample or write already running still finishes, but its
    /// result is not kept and it does not start another pass by itself.
    func cancel() {
        lock.lock()
        generation &+= 1
        finished = nil
        lock.unlock()
    }
}

/// Samples the mounted volumes on a slow timer and stores at most one point per volume per
/// hour. The app and the background recorder each own one; the table's primary key makes a
/// second writer's point a no-op, so running both at once cannot duplicate rows.
///
/// The blocking sampler and the SQLite write both run on `VolumeCapacitySampleWorker`, never
/// on the caller's loop. A tick starts at most one sample and only polls for a result, so a
/// stuck Disk Arbitration call or a database waiting for another writer cannot stop other
/// sampling or the heartbeat. The sampler runs at most once per hour (plus retries while the
/// hour is open). `session` names the recording session the pass belongs to; a sample whose
/// session changed is discarded whole. A reading the sampler could not measure is skipped,
/// never stored as zero.
public struct VolumeCapacityRecorder: Sendable {
    public typealias Apply = @Sendable ([VolumeCapacityReading], Date, Date, String) throws -> VolumeCapacityApplyResult

    /// A failed or empty pass is retried after this many seconds, still within the same hour.
    public static let retryInterval: TimeInterval = 60

    private let worker: VolumeCapacitySampleWorker
    /// The current recording session, or nil when recording is off. The app leaves the default
    /// always-on session in place while it runs; the background agent reads its profile file.
    private let session: @Sendable () -> String?
    private var completedHour: Date?
    private var lastAttemptAt: Date?
    private var pending: (generation: UInt64, hour: Date)?

    public init(history: VolumeCapacityHistory,
                sampler: @escaping @Sendable () -> [VolumeCapacityReading],
                session: @escaping @Sendable () -> String? = { "always" },
                apply: Apply? = nil) {
        let effectiveApply = apply ?? { readings, sampledAt, now, token in
            // The default (app) recorder has no profile; a caller-supplied session can still
            // turn it off between the start and the apply.
            guard session() == token else { return .discarded }
            let inserted = try history.record(readings, at: sampledAt, now: now)
            return .applied(inserted: inserted, readingCount: readings.count)
        }
        self.worker = VolumeCapacitySampleWorker(sampler: sampler, apply: effectiveApply)
        self.session = session
    }

    /// One loop tick. Never blocks on the disk sampler or the history write: it starts a pass
    /// when one is due and polls for a finished one. Returns whether this tick started a pass,
    /// applied a sample, and whether that sample's hour is now complete. A retry wait or an
    /// in-flight sample returns all four false, so a caller can keep a previous failure visible
    /// until a pass succeeds.
    @discardableResult
    public mutating func tick(now: Date = Date()) throws -> VolumeCapacityTickOutcome {
        if let pending {
            guard let work = worker.takeResult(generation: pending.generation) else {
                return VolumeCapacityTickOutcome(didSample: false, hourCompleted: false)
            }
            self.pending = nil
            switch work {
            case .failed(let message):
                // Keep lastAttemptAt so the same hour is retried after the normal interval.
                throw VolumeCapacityRecorderError.applyFailed(message)
            case .applied(let applied):
                guard applied.authorized else {
                    // The profile was disabled or the recording session changed while the
                    // sample was in flight. Drop the whole result; re-enabling starts a fresh
                    // pass with a new generation.
                    worker.cancel()
                    completedHour = nil
                    lastAttemptAt = nil
                    return VolumeCapacityTickOutcome(didSample: false, didDiscard: true, hourCompleted: false)
                }
                if applied.readingCount == 0 {
                    // Nothing recordable. Disk Arbitration may not be ready right after login,
                    // so leave the hour open and retry after the normal interval instead of
                    // delaying the first point until the next hour. The worker still runs one
                    // sample at a time, so this cannot pile up.
                    return VolumeCapacityTickOutcome(didSample: true, hourCompleted: false)
                }
                completedHour = pending.hour
                return VolumeCapacityTickOutcome(didSample: true, hourCompleted: true)
            }
        }

        let hour = VolumeCapacityHistory.hourStart(now)
        if completedHour == hour {
            return VolumeCapacityTickOutcome(didSample: false, hourCompleted: true)
        }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.retryInterval {
            return VolumeCapacityTickOutcome(didSample: false, hourCompleted: false)
        }
        // Do not start a pass while recording is disabled, even in the few seconds before
        // the agent re-reads its profile. This also avoids one extra sampler call after a
        // result was discarded.
        guard let token = session() else {
            completedHour = nil
            lastAttemptAt = nil
            return VolumeCapacityTickOutcome(didSample: false, hourCompleted: false)
        }
        lastAttemptAt = now
        if let generation = worker.start(at: now, session: token, now: now) {
            pending = (generation, hour)
            return VolumeCapacityTickOutcome(didStart: true, didSample: false, hourCompleted: false)
        }
        return VolumeCapacityTickOutcome(didSample: false, hourCompleted: false)
    }

    /// Drops an in-flight sample. A result that has not started its write is never written, and
    /// a later enabled period starts a fresh pass instead of inheriting the old hour.
    public mutating func cancel() {
        worker.cancel()
        pending = nil
        completedHour = nil
        lastAttemptAt = nil
    }
}
