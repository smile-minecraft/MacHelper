import Foundation

/// Pure, deterministic model of the privileged Helper's health.
///
/// `SMAppService.status` only says what Background Task Management recorded. It does
/// not say whether launchd actually spawned the daemon or whether the daemon speaks
/// the same XPC protocol as the app. This state is derived from both observations so
/// the UI can never show a green dot for a Helper that does not answer.
public enum HelperHealthState: Equatable, Sendable {
    /// The Helper was never set up on this Mac. No warning is warranted.
    case notConfigured
    /// Registered, approved and answering with a matching protocol version.
    case healthy(helperVersion: String)
    /// A recovery pass is in flight. Transient; the UI stays quiet.
    case recovering
    /// Background Task Management recorded the job but the user must flip its switch.
    case requiresApproval(afterUpdate: Bool)
    /// It worked before an update, now the registration is gone (`.notRegistered`/`.notFound`).
    case permissionLostAfterUpdate
    /// The job is enabled in Login Items but XPC failed after bounded retries.
    case unresponsive(detail: String, afterUpdate: Bool)
    /// The daemon answered, but with an older or newer protocol version.
    case versionMismatch(helper: Int, app: Int)
    /// The embedded helper's code signature could not be read; XPC is pinned to nothing.
    case untrustedSignature(detail: String)

    /// Whether this state warrants an in-app banner.
    public var needsAttention: Bool {
        switch self {
        case .notConfigured, .healthy, .recovering: false
        case .requiresApproval, .permissionLostAfterUpdate, .unresponsive,
             .versionMismatch, .untrustedSignature: true
        }
    }

    /// Whether a full unregister/register can plausibly fix this state.
    public var isRepairable: Bool {
        switch self {
        case .permissionLostAfterUpdate, .unresponsive, .versionMismatch: true
        case .notConfigured, .healthy, .recovering, .requiresApproval, .untrustedSignature: false
        }
    }
}

/// A mirror of `SMAppService.Status` that lives in a pure Swift module, so the state
/// machine and its tests never need ServiceManagement or a root daemon.
public enum HelperServiceStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

/// The result of an XPC handshake, reduced to the facts the recovery planner needs.
/// The app maps its own `HelperClientError` into this before calling the planner.
public enum HelperHandshakeOutcome: Equatable, Sendable {
    case success(protocolVersion: Int, helperVersion: String)
    case versionMismatch(helper: Int, app: Int)
    case timedOut
    case connectionFailed(String)
    case untrustedSignature(String)
    case notEnabled

    /// A short, user-facing explanation for the `.unresponsive` state.
    public var detail: String? {
        switch self {
        case .timedOut: "The Helper did not answer in time."
        case .connectionFailed(let text): text
        case .notEnabled: "macOS is no longer allowing the Helper to run."
        case .untrustedSignature(let text): text
        case .success, .versionMismatch: nil
        }
    }
}

/// What the monitor should do next. `.promptUser` carries the exact state to show so
/// the decision and the message never drift apart.
public enum HelperRecoveryAction: Equatable, Sendable {
    case none
    /// Reset the XPC connection and re-publish the existing registration, then verify.
    case softReregister
    /// The daemon may simply still be starting; verify again before changing anything.
    case retryHandshake
    /// Unregister, wait for launchd to drop the job, register again, then verify.
    case reinstall
    case promptUser(HelperHealthState)
}

/// A snapshot taken immediately before Sparkle replaces the app bundle. Stored outside
/// the bundle so the relaunched app can tell an update from a fresh install, and so a
/// Helper that worked before the update gets recovered instead of silently ignored.
public struct HelperUpdateHandoff: Codable, Equatable, Sendable {
    public var wasEnabled: Bool
    public var wasHealthy: Bool
    public var previousAppVersion: String
    public var previousHelperHash: String?
    public var timestamp: Date

    public init(wasEnabled: Bool,
                wasHealthy: Bool,
                previousAppVersion: String,
                previousHelperHash: String?,
                timestamp: Date) {
        self.wasEnabled = wasEnabled
        self.wasHealthy = wasHealthy
        self.previousAppVersion = previousAppVersion
        self.previousHelperHash = previousHelperHash
        self.timestamp = timestamp
    }

    /// Handoffs older than a week are stale: a crashed app must not claim an update
    /// happened after the user has since changed the Helper's registration.
    public static let timeToLive: TimeInterval = 7 * 24 * 60 * 60

    public func isExpired(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age > Self.timeToLive || age < -60
    }
}

/// The last app/helper pair for which a handshake actually succeeded. A manual
/// drag-and-drop update never calls Sparkle, so this is the only way to notice that the
/// embedded helper changed behind the app's back.
public struct HelperInstallFingerprint: Codable, Equatable, Sendable {
    public var appVersion: String
    public var helperHash: String?
    public var recordedAt: Date

    public init(appVersion: String, helperHash: String?, recordedAt: Date) {
        self.appVersion = appVersion
        self.helperHash = helperHash
        self.recordedAt = recordedAt
    }
}

/// Pure decisions. No ServiceManagement, no XPC, no defaults — every input arrives as
/// a value so each transition can be pinned by a unit test.
public enum HelperRecoveryPlanner {
    /// Derives the state shown in the UI from one observation.
    public static func evaluateState(
        status: HelperServiceStatus,
        handshakeResult: HelperHandshakeOutcome?,
        handoff: HelperUpdateHandoff?,
        hadPreviouslyWorked: Bool
    ) -> HelperHealthState {
        let afterUpdate = handoff != nil
        switch status {
        case .notRegistered, .notFound:
            // A Helper that never worked is a first-launch setup case, not a failure.
            if hadPreviouslyWorked || handoff?.wasEnabled == true {
                return .permissionLostAfterUpdate
            }
            return .notConfigured
        case .requiresApproval:
            guard hadPreviouslyWorked || afterUpdate else { return .notConfigured }
            return .requiresApproval(afterUpdate: afterUpdate)
        case .enabled:
            // A Helper that was never observed working is a setup case, even if a stale
            // registration happens to be enabled. Don't alarm on a first launch.
            guard hadPreviouslyWorked || afterUpdate else { return .notConfigured }
            guard let handshakeResult else { return .recovering }
            switch handshakeResult {
            case .success(_, let helperVersion):
                return .healthy(helperVersion: helperVersion)
            case .versionMismatch(let helper, let app):
                return .versionMismatch(helper: helper, app: app)
            case .untrustedSignature(let detail):
                return .untrustedSignature(detail: detail)
            case .timedOut:
                return .unresponsive(detail: handshakeResult.detail ?? "", afterUpdate: afterUpdate)
            case .connectionFailed:
                return .unresponsive(detail: handshakeResult.detail ?? "", afterUpdate: afterUpdate)
            case .notEnabled:
                return hadPreviouslyWorked || afterUpdate ? .permissionLostAfterUpdate : .notConfigured
            }
        }
    }

    /// Chooses the next recovery step. `attemptCount` is the number of steps already
    /// tried in this pass: one cheap handshake retry, then up to two soft repairs, then
    /// a prompt. A lost registration gets up to two full reinstalls first.
    public static func nextAction(
        status: HelperServiceStatus,
        handshakeResult: HelperHandshakeOutcome?,
        handoff: HelperUpdateHandoff?,
        hadPreviouslyWorked: Bool,
        attemptCount: Int
    ) -> HelperRecoveryAction {
        // Never touch a Helper that was never enabled, or nag about a first launch.
        guard hadPreviouslyWorked || handoff?.wasEnabled == true else { return .none }

        switch status {
        case .notRegistered, .notFound:
            return attemptCount < 2 ? .reinstall : .promptUser(.permissionLostAfterUpdate)
        case .requiresApproval:
            return .promptUser(.requiresApproval(afterUpdate: handoff != nil))
        case .enabled:
            guard let handshakeResult else { return .retryHandshake }
            switch handshakeResult {
            case .success:
                return .none
            case .versionMismatch(let helper, let app):
                // The daemon answered from an older bundle. Refresh in place first so an
                // approval the user already gave is kept; only drop and re-add the job if
                // that does not spawn the new binary.
                switch attemptCount {
                case 0: return .softReregister
                case 1: return .reinstall
                default: return .promptUser(.versionMismatch(helper: helper, app: app))
                }
            case .untrustedSignature(let detail):
                // A signature we cannot verify will stay unverified after a reinstall.
                return .promptUser(.untrustedSignature(detail: detail))
            case .timedOut, .connectionFailed, .notEnabled:
                switch attemptCount {
                case 0: return .retryHandshake
                case 1, 2: return .softReregister
                default:
                    return .promptUser(evaluateState(
                        status: status,
                        handshakeResult: handshakeResult,
                        handoff: handoff,
                        hadPreviouslyWorked: hadPreviouslyWorked))
                }
            }
        }
    }

    /// Detects a manual DMG update: the app version or the embedded helper's cdhash
    /// changed while a previously working Helper was enabled. Sparkle never wrote a
    /// handoff in that path, so we synthesise one from the last known-good fingerprint.
    public static func detectUpdate(
        lastKnownWorking: HelperInstallFingerprint?,
        currentAppVersion: String,
        currentHelperHash: String?,
        wasEnabled: Bool,
        now: Date
    ) -> HelperUpdateHandoff? {
        guard let lastKnownWorking, wasEnabled else { return nil }
        guard lastKnownWorking.appVersion != currentAppVersion
                || lastKnownWorking.helperHash != currentHelperHash
        else { return nil }
        return HelperUpdateHandoff(
            wasEnabled: true,
            wasHealthy: true,
            previousAppVersion: lastKnownWorking.appVersion,
            previousHelperHash: lastKnownWorking.helperHash,
            timestamp: now)
    }
}

/// JSON persistence next to the other MacHelper support files. Keys are namespaced so
/// a handoff can never be confused with the background-recording agent's handoff.
public enum HelperUpdateHandoffStore {
    public static let fileName = "helper-update-handoff.json"

    public static func defaultURL(supportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/MacHelper")) -> URL {
        supportDirectory.appending(path: fileName)
    }

    /// Loads a live handoff. An expired record is removed so it cannot be replayed.
    public static func load(from url: URL, now: Date = Date()) -> HelperUpdateHandoff? {
        guard let handoff = try? JSONDecoder().decode(HelperUpdateHandoff.self,
                                                      from: Data(contentsOf: url)) else { return nil }
        guard !handoff.isExpired(now: now) else {
            clear(from: url)
            return nil
        }
        return handoff
    }

    public static func save(_ handoff: HelperUpdateHandoff, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(handoff).write(to: url, options: .atomic)
    }

    public static func clear(from url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
