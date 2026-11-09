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
    /// Background recording is on, but every metric is off, so there is nothing to sample.
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
    public var lastError: String?

    public init(pid: Int32, lastHeartbeatAt: Date, lastSampleAt: Date? = nil, lastError: String? = nil) {
        self.pid = pid
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastSampleAt = lastSampleAt
        self.lastError = lastError
    }
}

/// Decides what the UI shows. With every metric and process collection off there is nothing
/// to record, so the service is reported as `.nothingToRecord` instead of looking broken. `running` requires
/// both a heartbeat and a sample no older than the thresholds below; a service that
/// heartbeats but never samples is `.stopped`, not "Recording".
public enum BackgroundRecordingStatus {
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
            if enabledModuleCount == 0 && !processCollectionEnabled { return .nothingToRecord }
            guard let beat = heartbeat else { return .stopped }
            if let error = beat.lastError, !error.isEmpty { return .failed(reason: error) }
            let freshWithin: TimeInterval = 120
            let sampleFreshWithin: TimeInterval = 180
            let beatFresh = now.timeIntervalSince(beat.lastHeartbeatAt) <= freshWithin
            let sampled = beat.lastSampleAt.map { now.timeIntervalSince($0) <= sampleFreshWithin } ?? false
            return beatFresh && sampled ? .running : .stopped
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

    public init(backgroundRecordingEnabled: Bool, modules: [ModulePlan]) {
        self.backgroundRecordingEnabled = backgroundRecordingEnabled
        self.modules = modules
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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(profile).write(to: url, options: .atomic)
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
        case metrics, series, process
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public init(profileURL: URL = MonitorAgentProfileStore.defaultURL(),
                heartbeatURL: URL = MonitorAgentHeartbeatStore.defaultURL(),
                history: MetricsHistory,
                sampler: @escaping Sampler,
                processCollection: ProcessCollection? = nil,
                seriesCollection: SeriesCollection? = nil) {
        self.profileURL = profileURL
        self.heartbeatURL = heartbeatURL
        self.history = history
        self.sampler = sampler
        self.processCollection = processCollection
        self.seriesCollection = seriesCollection
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
                }
            } else {
                profileEnabled = false
                plan = []
                nextSample = [:]
                accumulator = MinuteAccumulator()
                processAccumulator = ProcessMinuteAccumulator()
                seriesAccumulator = SeriesMinuteAccumulator()
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
