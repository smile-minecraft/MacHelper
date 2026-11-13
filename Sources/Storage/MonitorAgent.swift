import Darwin
import Foundation

/// How the copy of the background recorder service registered with the system looks
/// from the app's perspective. Mirrors the four states of the platform's agent status
/// (`SMAppService.Status`) without importing ServiceManagement, so the decision logic
/// stays unit-testable. The app maps the platform value onto this enum.
public enum BackgroundServiceStatus: String, Codable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
}

/// User-facing state of background recording. `enabled` from the service API only means
/// the service is allowed to run; the heartbeat decides whether it is actually alive.
public enum BackgroundRecordingState: Equatable, Sendable {
    /// Background recording is off (or was never enabled).
    case notEnabled
    /// The user still has to allow MacHelper in System Settings → General → Login Items.
    case pendingApproval
    /// Service enabled and the heartbeat is fresh.
    case running
    /// Service enabled, but no fresh heartbeat (crashed, throttled by launchd, or not started yet).
    case stopped
    /// Kept for source compatibility. Background recording now always records the hourly
    /// capacity history, so an enabled profile is never "nothing to record".
    case nothingToRecord
    /// The last heartbeat reports an error, or the service registration is missing.
    case failed(reason: String)
}

/// Heartbeat file the background recorder rewrites every 10 seconds while it runs.
/// Absence or staleness is what distinguishes "running" from "stopped".
public struct MonitorAgentHeartbeat: Codable, Equatable, Sendable {
    public var pid: Int32
    public var lastHeartbeatAt: Date
    public var lastSampleAt: Date?
    /// Last time a per-volume capacity pass was attempted (refreshed again when it applies).
    /// Optional so a heartbeat written by an earlier version decodes unchanged.
    public var lastCapacitySampleAt: Date?
    public var lastError: String?

    public init(pid: Int32, lastHeartbeatAt: Date, lastSampleAt: Date? = nil,
                lastCapacitySampleAt: Date? = nil, lastError: String? = nil) {
        self.pid = pid
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastSampleAt = lastSampleAt
        self.lastCapacitySampleAt = lastCapacitySampleAt
        self.lastError = lastError
    }
}

/// Decides what the UI shows. Background recording always includes the hourly capacity
/// history, so an enabled profile has something to record even with every menu bar metric and
/// process collection off. `running` requires a fresh heartbeat plus the freshness signal that
/// belongs to the enabled work: per-minute samples for modules/processes, or the hourly
/// capacity pass when only capacity is recorded. A recorded error wins over both, so a
/// capacity write failure cannot hide behind "nothing to record".
public enum BackgroundRecordingStatus {
    /// A capacity pass runs once an hour, so its freshness window is wider than a minute
    /// sample's. Two hours allows one missed pass without briefly showing "stopped".
    public static let capacityFreshWithin: TimeInterval = 2 * 3_600

    public static func evaluate(serviceStatus: BackgroundServiceStatus,
                                profileEnabled: Bool,
                                enabledModuleCount: Int,
                                processCollectionEnabled: Bool = false,
                                heartbeat: MonitorAgentHeartbeat?,
                                now: Date) -> BackgroundRecordingState {
        if !profileEnabled { return .notEnabled }
        switch serviceStatus {
        case .requiresApproval: return .pendingApproval
        case .notRegistered: return .failed(reason: "service not registered")
        case .notFound: return .failed(reason: "service not found")
        case .enabled:
            guard let beat = heartbeat else { return .stopped }
            if let error = beat.lastError, !error.isEmpty { return .failed(reason: error) }
            let freshWithin: TimeInterval = 120
            let beatFresh = now.timeIntervalSince(beat.lastHeartbeatAt) <= freshWithin
            guard beatFresh else { return .stopped }

            if enabledModuleCount == 0 && !processCollectionEnabled {
                // Capacity-only recording. A nil value means the process just started and the
                // first hourly pass has not finished yet; the fresh heartbeat covers that gap.
                let capacityFresh = beat.lastCapacitySampleAt.map {
                    now.timeIntervalSince($0) <= capacityFreshWithin
                } ?? true
                return capacityFresh ? .running : .stopped
            }

            let sampleFreshWithin: TimeInterval = 180
            let sampled = beat.lastSampleAt.map { now.timeIntervalSince($0) <= sampleFreshWithin } ?? false
            return sampled ? .running : .stopped
        }
    }
}

/// One enabled module in the background recorder's plan.
public struct ModulePlan: Codable, Equatable, Sendable {
    public var module: String
    /// Seconds between samples, as chosen for the menu bar monitor.
    public var interval: TimeInterval

    public init(module: String, interval: TimeInterval) {
        self.module = module
        self.interval = interval
    }
}

/// Snapshot of what the background recorder should collect, written by the app as the
/// single source of truth and read by the agent process. The app keeps this in sync
/// with its own settings; the agent never reads the app's preference domain.
public struct MonitorAgentProfile: Codable, Equatable, Sendable {
    public var backgroundRecordingEnabled: Bool
    /// Modules the recorder samples, in the order the app wrote them.
    public var modules: [ModulePlan]
    /// Identifies one enabled recording session. A capacity sample started under an older
    /// generation is discarded, even when the user disables and re-enables before the sample
    /// finishes. Optional so a profile written by an earlier app still decodes.
    public var capacityGeneration: String?

    public init(backgroundRecordingEnabled: Bool, modules: [ModulePlan],
                capacityGeneration: String? = nil) {
        self.backgroundRecordingEnabled = backgroundRecordingEnabled
        self.modules = modules
        self.capacityGeneration = capacityGeneration
    }
}

/// Failures from the profile lock. The lock makes a profile change and the capacity write
/// that reads it one ordered operation across the app and the background recorder.
public enum MonitorAgentProfileStoreError: Error, LocalizedError, Equatable {
    /// The sidecar lock file could not be opened or locked.
    case lockUnavailable(path: String, code: Int32)
    /// Another process kept the lock longer than the caller allowed.
    case lockTimeout(path: String)

    public var errorDescription: String? {
        switch self {
        case .lockUnavailable(let path, let code):
            "Couldn’t lock \(path) for the background recording profile (errno \(code))."
        case .lockTimeout(let path):
            "Timed out waiting for \(path) to finish a background recording write."
        }
    }
}

/// Advisory lock shared by the app's profile writer and the agent's capacity writer.
///
/// A capacity result is written while holding the shared lock, and a profile change is
/// written while holding the exclusive lock. A disable therefore cannot return while a
/// capacity write that already read the old profile is still in flight: the writer holds the
/// shared lock through the SQLite commit, and the profile save waits for it. A profile save
/// that starts first makes the next capacity write read the new generation and discard its
/// result. The lock is released by the system if a process crashes.
enum MonitorAgentProfileLock {
    static func withLock<T>(at profileURL: URL, exclusive: Bool,
                            timeout: TimeInterval, _ body: () throws -> T) throws -> T {
        let path = profileURL.path + ".lock"
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw MonitorAgentProfileStoreError.lockUnavailable(path: path, code: errno)
        }
        defer { close(descriptor) }
        let operation = (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, operation) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK || errno == EAGAIN {
                if Date() >= deadline {
                    throw MonitorAgentProfileStoreError.lockTimeout(path: path)
                }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            throw MonitorAgentProfileStoreError.lockUnavailable(path: path, code: errno)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}

/// JSON persistence for the profile, in the per-user Application Support directory.
public enum MonitorAgentProfileStore {
    public static let fileName = "monitor-agent.json"

    public static func defaultURL(supportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/MacHelper")) -> URL {
        supportDirectory.appending(path: fileName)
    }

    public static func load(from url: URL) -> MonitorAgentProfile? {
        try? JSONDecoder().decode(MonitorAgentProfile.self, from: Data(contentsOf: url))
    }

    public static func save(_ profile: MonitorAgentProfile, to url: URL) throws {
        try save(profile, to: url, timeout: 2)
    }

    /// `save` with an explicit lock timeout. The public call uses two seconds so a profile
    /// change cannot hang the app indefinitely when a capacity write is stuck in SQLite. On
    /// timeout nothing is written: the old profile stays in place and the caller reports the
    /// failure, so a disable is never mistaken for a completed one. Tests use a short timeout
    /// to prove the failure is bounded.
    static func save(_ profile: MonitorAgentProfile, to url: URL,
                     timeout: TimeInterval) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withExclusiveLock(at: url, timeout: timeout) {
            try JSONEncoder().encode(profile).write(to: url, options: .atomic)
        }
    }

    /// Runs `body` while holding the shared sidecar lock. The agent wraps the capacity
    /// write in this lock so a profile save cannot slip between its profile read and its
    /// SQLite commit.
    static func withSharedLock<T>(at url: URL, timeout: TimeInterval = 2,
                                  _ body: () throws -> T) throws -> T {
        try MonitorAgentProfileLock.withLock(at: url, exclusive: false, timeout: timeout, body)
    }

    /// Runs `body` while holding the exclusive sidecar lock. Used by the profile writer and
    /// by tests that need to observe whether a capacity write is in flight.
    static func withExclusiveLock<T>(at url: URL, timeout: TimeInterval = 2,
                                     _ body: () throws -> T) throws -> T {
        try MonitorAgentProfileLock.withLock(at: url, exclusive: true, timeout: timeout, body)
    }

    /// The generation a capacity pass must belong to, or nil when background recording is
    /// off or the profile cannot be read. A profile from an earlier app has no generation;
    /// its enabled state is still honoured under the stable "legacy" token.
    static func capacitySession(from url: URL) -> String? {
        guard let profile = load(from: url), profile.backgroundRecordingEnabled else { return nil }
        return profile.capacityGeneration ?? "legacy"
    }
}

/// Process sampling supplied by the process that owns the process sampler. The shared
/// switch is read once per process sample, so the app and the background recorder obey the
/// same choice without a separate channel; when it is off the sampler is never called.
public struct ProcessCollection {
    public let sample: () -> ProcessUsageReadings
    public let isEnabled: () -> Bool

    public init(sample: @escaping () -> ProcessUsageReadings, isEnabled: @escaping () -> Bool) {
        self.sample = sample
        self.isEnabled = isEnabled
    }
}

/// Individual sensor and CPU-cluster sampling supplied by the process that owns the
/// hardware. `sample` receives the module that was just sampled and must derive its values
/// from that same reading; sampling the CPU again would consume its tick delta twice.
public struct SeriesCollection {
    public let sample: (String) -> [String: Double]
    public let isEnabled: () -> Bool

    public init(sample: @escaping (String) -> [String: Double], isEnabled: @escaping () -> Bool) {
        self.sample = sample
        self.isEnabled = isEnabled
    }
}

/// Per-volume capacity sampling supplied by the process that owns the disk sampler. The
/// recorder stores one point per volume per hour and is independent of the module plan, so
/// turning every menu bar module off does not stop capacity history while background
/// recording is enabled.
public struct VolumeCapacityCollection: Sendable {
    public let sample: @Sendable () -> [VolumeCapacityReading]

    public init(sample: @escaping @Sendable () -> [VolumeCapacityReading]) {
        self.sample = sample
    }
}

/// Samples the enabled modules and, when their shared switch is on, process usage and
/// individual series into per-minute history and keeps the heartbeat fresh. The samplers
/// are supplied by the process that owns them, so the loop can be exercised with a
/// temporary database and fake samplers.
public struct MonitorAgentRecorder {
    public typealias Sampler = (String) -> [String: Double]

    /// How often the profile is re-read so settings changes reach a running agent.
    public static let profileReloadInterval: TimeInterval = 5
    /// How often the heartbeat file is rewritten (the UI treats 120 s as stale).
    public static let heartbeatInterval: TimeInterval = 10
    /// Background process history needs one sample every five seconds at most; the user's
    /// module intervals are unrelated and may be shorter.
    public static let processSampleInterval: TimeInterval = 5

    private let profileURL: URL
    private let heartbeatURL: URL
    private let history: MetricsHistory
    private let sampler: Sampler
    private let processCollection: ProcessCollection?
    private let seriesCollection: SeriesCollection?
    private var volumeCapacityRecorder: VolumeCapacityRecorder?

    private var accumulator = MinuteAccumulator()
    private var processAccumulator = ProcessMinuteAccumulator()
    private var seriesAccumulator = SeriesMinuteAccumulator()
    private var nextProcessSample = Date.distantPast
    private var plan: [ModulePlan] = []
    private var profileEnabled = false
    private var nextSample: [String: Date] = [:]
    private var heartbeat: MonitorAgentHeartbeat
    private var lastProfileRead = Date.distantPast
    private var lastHeartbeatWrite = Date.distantPast
    /// Last write failure per history kind, kept until a write of that same kind succeeds.
    /// Ticks are shorter than the heartbeat interval, so a failure held only for the current
    /// tick would be lost, and a success of one kind must not hide a failure of another.
    private var writeErrors: [WriteKind: String] = [:]

    private enum WriteKind: Int, Comparable {
        case metrics, series, process, capacity
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public init(profileURL: URL = MonitorAgentProfileStore.defaultURL(),
                heartbeatURL: URL = MonitorAgentHeartbeatStore.defaultURL(),
                history: MetricsHistory,
                sampler: @escaping Sampler,
                processCollection: ProcessCollection? = nil,
                seriesCollection: SeriesCollection? = nil,
                volumeCapacity: VolumeCapacityCollection? = nil) {
        self.profileURL = profileURL
        self.heartbeatURL = heartbeatURL
        self.history = history
        self.sampler = sampler
        self.processCollection = processCollection
        self.seriesCollection = seriesCollection
        if let volumeCapacity {
            let capacityHistory = VolumeCapacityHistory(history: history)
            volumeCapacityRecorder = VolumeCapacityRecorder(
                history: capacityHistory,
                sampler: volumeCapacity.sample,
                // The profile file is the authority, not the five-second cache above: a
                // result that finishes after the user disables background recording must be
                // discarded even when the next profile reload has not happened yet.
                session: { MonitorAgentProfileStore.capacitySession(from: profileURL) },
                apply: { readings, sampledAt, now, session in
                    // Hold the shared lock across the profile read and the SQLite commit.
                    // A profile save (enable, disable, or a new generation) takes the
                    // exclusive lock, so it cannot slip between the check and the write.
                    try MonitorAgentProfileStore.withSharedLock(at: profileURL) {
                        guard let current = MonitorAgentProfileStore.capacitySession(from: profileURL),
                              current == session else {
                            return .discarded
                        }
                        let inserted = try capacityHistory.record(readings, at: sampledAt, now: now)
                        return .applied(inserted: inserted, readingCount: readings.count)
                    }
                })
        }
        heartbeat = MonitorAgentHeartbeat(pid: ProcessInfo.processInfo.processIdentifier,
                                          lastHeartbeatAt: Date())
    }

    /// One pass of the loop. Samples the modules whose interval elapsed, writes the minute
    /// that just ended, and refreshes the heartbeat.
    public mutating func tick(now: Date = Date()) {
        var profileError: String?
        if now.timeIntervalSince(lastProfileRead) >= Self.profileReloadInterval {
            lastProfileRead = now
            if let profile = MonitorAgentProfileStore.load(from: profileURL) {
                profileEnabled = profile.backgroundRecordingEnabled
                let updated = profile.backgroundRecordingEnabled ? profile.modules : []
                if updated != plan {
                    plan = updated
                    nextSample = [:]   // sample new or re-timed modules on the next tick
                }
                if !profileEnabled {
                    accumulator = MinuteAccumulator()
                    processAccumulator = ProcessMinuteAccumulator()
                    seriesAccumulator = SeriesMinuteAccumulator()
                    // Drop any capacity sample that started while recording was enabled; its
                    // result must not be written after the user turned background recording off.
                    volumeCapacityRecorder?.cancel()
                }
            } else {
                profileEnabled = false
                plan = []
                nextSample = [:]
                accumulator = MinuteAccumulator()
                processAccumulator = ProcessMinuteAccumulator()
                seriesAccumulator = SeriesMinuteAccumulator()
                volumeCapacityRecorder?.cancel()
                profileError = "monitor profile not found or unreadable"
            }
        }

        for module in plan {
            if let due = nextSample[module.module], now < due { continue }
            for (column, value) in sampler(module.module) {
                heartbeat.lastSampleAt = now
                if let finished = accumulator.addTracked(column, value, at: now) {
                    do {
                        try history.recordMinute(finished, now: now)
                        writeErrors[.metrics] = nil
                        // Hourly free-space point; a failure here must not mark metrics as failing.
                        try? history.recordDiskSpaceIfNeeded(now: now)
                    } catch let writeError {
                        writeErrors[.metrics] = "history write failed: \(writeError.localizedDescription)"
                        // Surface the failure now: the next timed heartbeat is up to 10 s
                        // away, and the app decides "failed" from this file alone.
                        writeHeartbeat(now: now, profileError: profileError)
                    }
                }
            }
            // Series follow the module cadence: the closure derives its values from the
            // sample just taken, so the CPU tick delta is consumed only once.
            if let seriesCollection {
                if seriesCollection.isEnabled() {
                    if let finished = seriesAccumulator.add(seriesCollection.sample(module.module), at: now) {
                        do {
                            try history.recordSeriesMinute(finished, now: now)
                            writeErrors[.series] = nil
                        } catch let writeError {
                            writeErrors[.series] = "series history write failed: \(writeError.localizedDescription)"
                            writeHeartbeat(now: now, profileError: profileError)
                        }
                    }
                } else {
                    // Turning collection off ends the open minute without carrying values
                    // across the off period.
                    seriesAccumulator = SeriesMinuteAccumulator()
                }
            }
            // History only needs a per-minute average; don't sample faster than every 5 seconds.
            nextSample[module.module] = now.addingTimeInterval(max(module.interval, 5))
        }

        // Process history is collected on its own cadence: it does not depend on the module
        // plan, and the shared switch is checked before the sampler sees any process name.
        if let processCollection, profileEnabled, now >= nextProcessSample {
            nextProcessSample = now.addingTimeInterval(Self.processSampleInterval)
            if processCollection.isEnabled() {
                let readings = processCollection.sample()
                heartbeat.lastSampleAt = now
                if let finished = processAccumulator.add(readings, at: now) {
                    do {
                        try history.recordProcessMinute(finished, now: now)
                        writeErrors[.process] = nil
                    } catch let writeError {
                        writeErrors[.process] = "process history write failed: \(writeError.localizedDescription)"
                        writeHeartbeat(now: now, profileError: profileError)
                    }
                }
            } else {
                // Turning collection off ends the open minute without inventing or padding it.
                processAccumulator = ProcessMinuteAccumulator()
            }
        }

        // Per-volume capacity history follows the background recording profile, not the
        // module plan: an enabled profile keeps recording it even when every menu bar module
        // is off. The blocking disk sampler runs on its own worker; this tick only starts a
        // pass and polls for a result, so a stuck Disk Arbitration call cannot stop the loop.
        if profileEnabled, volumeCapacityRecorder != nil {
            do {
                if let outcome = try volumeCapacityRecorder?.tick(now: now) {
                    // Record the attempt as soon as it starts, so a stuck sampler still has a
                    // fresh-looking status only for the bounded capacity window.
                    if outcome.didStart || outcome.didSample {
                        heartbeat.lastCapacitySampleAt = now
                    }
                    if outcome.hourCompleted {
                        writeErrors[.capacity] = nil
                    }
                }
            } catch let writeError {
                writeErrors[.capacity] = "volume capacity history write failed: \(writeError.localizedDescription)"
                writeHeartbeat(now: now, profileError: profileError)
            }
        }

        if now.timeIntervalSince(lastHeartbeatWrite) >= Self.heartbeatInterval {
            writeHeartbeat(now: now, profileError: profileError)
        }
    }

    private mutating func writeHeartbeat(now: Date, profileError: String?) {
        heartbeat.lastHeartbeatAt = now
        let messages = writeErrors.sorted { $0.key < $1.key }.map(\.value) + [profileError].compactMap { $0 }
        heartbeat.lastError = messages.isEmpty ? nil : messages.joined(separator: "; ")
        try? MonitorAgentHeartbeatStore.save(heartbeat, to: heartbeatURL)
        lastHeartbeatWrite = now
    }

    /// Runs until the process is terminated. Completed minutes are already on disk; an
    /// in-progress minute is not invented or padded after a crash.
    public mutating func run() {
        while true {
            tick()
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

/// JSON persistence for the heartbeat file.
public enum MonitorAgentHeartbeatStore {
    public static let fileName = "monitor-agent-status.json"

    public static func defaultURL(supportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/MacHelper")) -> URL {
        supportDirectory.appending(path: fileName)
    }

    public static func load(from url: URL) -> MonitorAgentHeartbeat? {
        try? JSONDecoder().decode(MonitorAgentHeartbeat.self, from: Data(contentsOf: url))
    }

    public static func save(_ heartbeat: MonitorAgentHeartbeat, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(heartbeat).write(to: url, options: .atomic)
    }
}

/// A snapshot of background recording taken immediately before Sparkle replaces the
/// app bundle. The app unregisters the background agent for the install so the old
/// binary is not running while the bundle is swapped, then the relaunched app (or
/// the running app, when the update is canceled) consults this handoff to restore
/// exactly what it stopped. Stored outside the bundle so it survives replacement.
public struct UpdateAgentHandoff: Codable, Equatable, Sendable {
    /// The recorder was enabled and registered immediately before the install.
    public var wasEnabled: Bool
    /// The last heartbeat was fresh (the recorder was actually sampling).
    public var wasRunning: Bool
    public var recordedAt: Date

    public init(wasEnabled: Bool, wasRunning: Bool, recordedAt: Date) {
        self.wasEnabled = wasEnabled
        self.wasRunning = wasRunning
        self.recordedAt = recordedAt
    }
}

/// What the app should do with a handoff once the update (or a canceled update)
/// leaves the service registration in a given state.
public enum UpdateAgentRestore: Equatable, Sendable {
    /// Nothing was running before, the handoff is missing, or the user must approve
    /// again in Login Items. Leave the service alone: a revoked permission stays
    /// revoked instead of being silently re-enabled.
    case stayOff
    /// The service is already enabled; re-publish the profile snapshot so the
    /// recorder loop sees fresh sampling plans.
    case republish
    /// The agent was unregistered for the install; register it again so launchd
    /// starts the new binary.
    case reregister
}

/// Pure stop/restore decisions for the update handoff, kept free of the service
/// APIs so the state machine stays unit-testable.
public enum UpdateAgentRestorePlanner {
    /// Captures whether recording may be resumed after the update. Only an intent
    /// that was actually enabled and registered counts: recording turned off or
    /// revoked before the update must not spring back after it.
    public static func snapshot(enabledIntent: Bool,
                                serviceStatus: BackgroundServiceStatus,
                                heartbeat: MonitorAgentHeartbeat?,
                                now: Date) -> UpdateAgentHandoff {
        let wasEnabled = enabledIntent && serviceStatus == .enabled
        let wasRunning: Bool
        if wasEnabled, let heartbeat,
           now.timeIntervalSince(heartbeat.lastHeartbeatAt) <= 120,
           heartbeat.lastSampleAt.map({ now.timeIntervalSince($0) <= 180 }) ?? false {
            wasRunning = true
        } else {
            wasRunning = false
        }
        return UpdateAgentHandoff(wasEnabled: wasEnabled, wasRunning: wasRunning, recordedAt: now)
    }

    /// Decides how to restore after the install completes or is canceled; both
    /// need the same restore, which is also what unblocks a canceled update.
    public static func restore(handoff: UpdateAgentHandoff?,
                               serviceStatus: BackgroundServiceStatus) -> UpdateAgentRestore {
        guard let handoff, handoff.wasEnabled else { return .stayOff }
        switch serviceStatus {
        case .enabled: return .republish
        case .notRegistered, .notFound: return .reregister
        case .requiresApproval: return .stayOff
        }
    }
}

/// JSON persistence for the update handoff, next to the profile and heartbeat.
public enum UpdateAgentHandoffStore {
    public static let fileName = "update-agent-handoff.json"

    public static func defaultURL(supportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/MacHelper")) -> URL {
        supportDirectory.appending(path: fileName)
    }

    public static func load(from url: URL) -> UpdateAgentHandoff? {
        try? JSONDecoder().decode(UpdateAgentHandoff.self, from: Data(contentsOf: url))
    }

    public static func save(_ handoff: UpdateAgentHandoff, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(handoff).write(to: url, options: .atomic)
    }

    public static func clear(from url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
