import FanControl
import Foundation
import HelperProtocol
import OSLog
import PrivilegedOps
import ServiceManagement
import SMCKit
import Storage

enum HelperClientError: Error, CustomStringConvertible {
    case notEnabled(SMAppService.Status)
    case connection(String)
    case remote(String)
    case versionMismatch(helper: Int, app: Int)
    case untrustedHelper
    case timedOut

    var description: String {
        switch self {
        case .notEnabled(let s): "Helper not enabled (status: \(s.label))"
        case .connection(let m): "XPC connection failed: \(m)"
        case .remote(let m): "Helper error: \(m)"
        case .versionMismatch(let h, let a): "Helper protocol v\(h) does not match app v\(a); re-register the helper"
        case .untrustedHelper: "Could not read the embedded helper's code signature"
        case .timedOut: "Helper did not respond (launchd may be refusing to start it; try re-registering)"
        }
    }
}

extension SMAppService.Status {
    /// The status in the interface language, for people rather than logs.
    var localizedLabel: String {
        switch self {
        case .enabled: String(localized: "Running")
        case .requiresApproval: String(localized: "Waiting for approval in Login Items")
        case .notRegistered: String(localized: "Not set up")
        case .notFound: String(localized: "Missing from the app")
        @unknown default: String(localized: "Not set up")
        }
    }

    /// The status for the CLI self-test and error messages (English, stable for logs).
    var label: String {
        switch self {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "requires approval in System Settings → General → Login Items"
        case .notFound: "not found (plist missing from bundle)"
        @unknown default: "unknown (\(rawValue))"
        }
    }
}

/// Registers the root Helper and talks to it over XPC.
final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()

    let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    static let logger = Logger(subsystem: "com.machelper.MacHelper", category: "helper")
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var cachedStatus: (value: SMAppService.Status, at: Date)?

    /// The registration status, reused for a second. SMAppService answers over IPC on the calling
    /// thread, and the sidebar, overview and panel ask on the main thread every few seconds or on
    /// every redraw; the status itself only changes when the user turns the Helper on or off.
    var status: SMAppService.Status {
        if let cached = lock.withLock({ cachedStatus }), Date().timeIntervalSince(cached.at) < 1 {
            return cached.value
        }
        return currentStatus
    }

    /// Asks launchd now. For code that has just changed the registration.
    var currentStatus: SMAppService.Status {
        let value = service.status
        lock.withLock { cachedStatus = (value, Date()) }
        return value
    }

    private static let registeredHashKey = "helper.registeredCDHash"
    /// App/helper pair for which a handshake last succeeded. Written only after real XPC
    /// success, so it means "this combination worked" rather than "we hoped it would".
    private static let fingerprintKey = "helper.lastKnownWorkingFingerprint"

    /// The app's marketing version, used to notice a manual DMG update.
    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// cdhash of the helper embedded in this app bundle.
    var embeddedHelperHash: String? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(HelperConstants.helperExecutableName)")
        return CodeSigning.info(at: url)?.cdhash
    }

    /// cdhash the daemon was last registered with. launchd pins this in the job's launch
    /// constraint (LWCR) and refuses to spawn any other binary (exit 78, EX_CONFIG).
    var registeredHelperHash: String? {
        UserDefaults.standard.string(forKey: Self.registeredHashKey)
    }

    var lastKnownWorkingFingerprint: HelperInstallFingerprint? {
        guard let data = UserDefaults.standard.data(forKey: Self.fingerprintKey) else { return nil }
        return try? JSONDecoder().decode(HelperInstallFingerprint.self, from: data)
    }

    /// The last helper cdhash that actually answered over XPC.
    var lastKnownWorkingHash: String? { lastKnownWorkingFingerprint?.helperHash }

    /// The last app version whose embedded helper actually answered over XPC.
    var lastKnownAppVersion: String? { lastKnownWorkingFingerprint?.appVersion }

    /// True once the Helper has really worked on this Mac. Drives both auto-recovery and
    /// the decision to alert: a Helper that never worked is a setup case, not a failure.
    var hadPreviouslyWorked: Bool { lastKnownWorkingFingerprint != nil }

    /// `SMAppService.Status` reduced to the pure model used by the recovery planner.
    var pureStatus: HelperServiceStatus {
        switch currentStatus {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .notRegistered
        }
    }

    /// A drag-and-drop DMG update never calls Sparkle, so no update handoff is written.
    /// Compare the current bundle with the last known-good fingerprint and synthesise the
    /// same handoff the Sparkle path would have written.
    func detectedManualUpdateHandoff() -> HelperUpdateHandoff? {
        HelperRecoveryPlanner.detectUpdate(lastKnownWorking: lastKnownWorkingFingerprint,
                                           currentAppVersion: appVersion,
                                           currentHelperHash: embeddedHelperHash,
                                           wasEnabled: hadPreviouslyWorked,
                                           now: Date())
    }

    /// After any update — ad-hoc or signed, Sparkle or DMG — the pinned job and the
    /// embedded helper can drift. A hash change covers ad-hoc LWCR and manual replacements;
    /// an app version change covers signed builds where the team constraint survives but the
    /// daemon still needs republishing. Registration must be verified by a handshake next.
    var needsReregistration: Bool {
        guard status == .enabled else { return false }
        if registeredHelperHash != embeddedHelperHash { return true }
        if let last = lastKnownWorkingHash, let embedded = embeddedHelperHash, last != embedded { return true }
        if let last = lastKnownAppVersion, last != appVersion { return true }
        return false
    }

    /// Records a verified handshake. Clears update detection: the current app/helper pair
    /// is now known good, so a later launch will not mistake it for another update.
    func markWorking(protocolVersion: Int, helperVersion: String) {
        let fingerprint = HelperInstallFingerprint(appVersion: appVersion,
                                                   helperHash: embeddedHelperHash,
                                                   recordedAt: Date())
        if let data = try? JSONEncoder().encode(fingerprint) {
            UserDefaults.standard.set(data, forKey: Self.fingerprintKey)
        }
        if let hash = embeddedHelperHash {
            UserDefaults.standard.set(hash, forKey: Self.registeredHashKey)
        }
        Self.logger.info("Helper verified: protocol v\(protocolVersion, privacy: .public), version \(helperVersion, privacy: .public)")
    }

    /// Maps a concrete client error onto the pure outcome the planner consumes.
    func handshakeOutcome(_ error: Error) -> HelperHandshakeOutcome {
        guard let clientError = error as? HelperClientError else {
            return .connectionFailed(error.localizedDescription)
        }
        switch clientError {
        case .versionMismatch(let helper, let app): return .versionMismatch(helper: helper, app: app)
        case .timedOut: return .timedOut
        case .connection(let message): return .connectionFailed(message)
        case .remote(let message): return .connectionFailed(message)
        case .untrustedHelper: return .untrustedSignature(clientError.description)
        case .notEnabled: return .notEnabled
        }
    }

    /// One bounded probe for the health monitor. Always returns a value; failures are
    /// logged here so neither the monitor nor the caller can silently drop them.
    func probeHandshake() async -> HelperHandshakeOutcome {
        guard status == .enabled else {
            Self.logger.warning("Handshake skipped: Helper is \(self.status.label, privacy: .public)")
            return .notEnabled
        }
        do {
            let result = try await handshake()
            markWorking(protocolVersion: result.protocolVersion, helperVersion: result.helperVersion)
            return .success(protocolVersion: result.protocolVersion, helperVersion: result.helperVersion)
        } catch {
            let outcome = handshakeOutcome(error)
            Self.logger.warning("Handshake failed: \(error.localizedDescription, privacy: .public)")
            return outcome
        }
    }

    /// For a not-yet-approved daemon, `register()` throws "Operation not permitted" even though
    /// the registration was submitted (status becomes `.requiresApproval`). That is not a failure.
    func register() throws {
        do {
            try service.register()
        } catch where currentStatus == .requiresApproval {
            if let hash = embeddedHelperHash {
                UserDefaults.standard.set(hash, forKey: Self.registeredHashKey)
            }
            Self.logger.notice("Helper submitted for approval in Login Items")
            return
        }
        if let hash = embeddedHelperHash {
            UserDefaults.standard.set(hash, forKey: Self.registeredHashKey)
        }
        lock.withLock { cachedStatus = nil }
        Self.logger.notice("Helper registration refreshed")
    }

    func unregister() async throws {
        resetConnection()
        try await service.unregister()
        lock.withLock { cachedStatus = nil }
        UserDefaults.standard.removeObject(forKey: Self.registeredHashKey)
        Self.logger.notice("Helper unregistered")
    }

    /// In-place re-registration used by the CLI self-test. The app's launch path verifies
    /// the result with `softRepair()` / the health monitor instead of assuming success.
    @discardableResult
    func refreshRegistrationIfNeeded() throws -> Bool {
        guard needsReregistration else { return false }
        resetConnection()
        try register()
        Self.logger.notice("Re-registered Helper after an app/helper change")
        return true
    }

    /// Non-destructive repair: drop the stale XPC connection, republish the existing
    /// registration, then verify with bounded backoff. Never unregisters, so a Helper the
    /// user approved stays approved.
    func softRepair() async throws {
        Self.logger.notice("Soft repair: resetting XPC connection and re-registering")
        resetConnection()
        try register()
        var lastError: Error = HelperClientError.timedOut
        for attempt in 0..<3 {
            do {
                let result = try await handshake()
                markWorking(protocolVersion: result.protocolVersion, helperVersion: result.helperVersion)
                Self.logger.notice("Soft repair succeeded on attempt \(attempt + 1, privacy: .public)")
                return
            } catch {
                lastError = error
                Self.logger.warning("Soft repair attempt \(attempt + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                resetConnection()
                if attempt < 2 { try await Task.sleep(for: .milliseconds(300 * (attempt + 1))) }
            }
        }
        throw lastError
    }

    /// Full unregister + register. May require approving the helper again in System Settings.
    /// Verifies the result with a handshake so a "registered" job that never starts is a failure.
    func reinstall() async throws {
        Self.logger.notice("Reinstalling Helper")
        try? await unregister()
        // unregister() returns before launchd/BTM finish removing the job; registering too early
        // fails and leaves the service unregistered.
        for _ in 0..<50 where currentStatus != .notRegistered {
            try await Task.sleep(for: .milliseconds(100))
        }
        try register()
        var lastError: Error = HelperClientError.timedOut
        for attempt in 0..<3 {
            do {
                let result = try await handshake()
                markWorking(protocolVersion: result.protocolVersion, helperVersion: result.helperVersion)
                Self.logger.notice("Helper reinstalled and verified on attempt \(attempt + 1, privacy: .public)")
                return
            } catch {
                lastError = error
                Self.logger.warning("Post-reinstall verification \(attempt + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                resetConnection()
                if attempt < 2 { try await Task.sleep(for: .milliseconds(300 * (attempt + 1))) }
            }
        }
        throw lastError
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Calls

    func handshake() async throws -> (protocolVersion: Int, helperVersion: String) {
        let result: (Int, String) = try await call { proxy, done in
            proxy.handshake { v, s in done(.success((v, s))) }
        }
        guard result.0 == HelperConstants.protocolVersion else {
            Self.logger.error("Helper protocol v\(result.0, privacy: .public) does not match app v\(HelperConstants.protocolVersion, privacy: .public)")
            throw HelperClientError.versionMismatch(helper: result.0, app: HelperConstants.protocolVersion)
        }
        return result
    }

    func readFans() async throws -> [FanReading] {
        let data: Data = try await call { proxy, done in
            proxy.readFans { data, error in
                if let data { done(.success(data)) } else { done(.failure(HelperClientError.remote(error ?? "unknown"))) }
            }
        }
        return try JSONDecoder().decode([FanReading].self, from: data)
    }

    func applyFanPolicy(_ policy: FanPolicy) async throws {
        let json = try JSONEncoder().encode(policy)
        let _: Bool = try await call { proxy, done in
            proxy.applyFanPolicy(json) { error in
                if let error { done(.failure(HelperClientError.remote(error))) } else { done(.success(true)) }
            }
        }
    }

    func fanControlStatus() async throws -> FanControlStatus {
        let data: Data = try await call { proxy, done in
            proxy.fanControlStatus { data, error in
                if let data { done(.success(data)) } else { done(.failure(HelperClientError.remote(error ?? "unknown"))) }
            }
        }
        return try JSONDecoder().decode(FanControlStatus.self, from: data)
    }

    /// Longer deadline: purge can take a while.
    func runMaintenance(_ id: String) async throws -> String {
        try await call(timeout: .seconds(120)) { proxy, done in
            proxy.runMaintenance(id) { ok, output in
                done(ok ? .success(output) : .failure(HelperClientError.remote(output)))
            }
        }
    }

    /// Old system logs and diagnostic reports, and the deep targets (fixed folders and age limits).
    /// Deleting is permanent. Deleting deep targets waits for the administrator password dialog the
    /// Helper shows, so callers pass a longer `timeout`.
    func systemCleanup(_ request: SystemCleanupRequest, timeout: Duration = .seconds(60)) async throws -> SystemCleanupResult {
        let json = try JSONEncoder().encode(request)
        // A request that carries an authorization is never resent: a retry could show the
        // password dialog twice or repeat a deletion the first attempt already made.
        let data: Data = try await call(timeout: timeout, retryOnConnectionFailure: request.authorization == nil) { proxy, done in
            proxy.systemCleanup(json) { data, error in
                if let data { done(.success(data)) } else { done(.failure(HelperClientError.remote(error ?? "unknown"))) }
            }
        }
        return try JSONDecoder().decode(SystemCleanupResult.self, from: data)
    }

    func setSystemDaemonEnabled(plistPath: String, enabled: Bool) async throws {
        let _: Bool = try await call(timeout: .seconds(30)) { proxy, done in
            proxy.setSystemDaemonEnabled(plistPath, enabled: enabled) { error in
                if let error { done(.failure(HelperClientError.remote(error))) } else { done(.success(true)) }
            }
        }
    }

    /// Background Task Management records via the Helper (root: no password prompt).
    func dumpBackgroundItems() async throws -> String {
        try await call(timeout: .seconds(40)) { proxy, done in
            proxy.dumpBackgroundItems { text, error in
                if let text { done(.success(text)) } else { done(.failure(HelperClientError.remote(error ?? "unknown"))) }
            }
        }
    }

    /// Moves leftovers out of system folders into this user's Trash (the Helper re-validates each path).
    func moveSystemLeftovers(_ paths: [String]) async throws -> SystemLeftovers.Result {
        let json = try JSONEncoder().encode(SystemLeftovers.Request(paths: paths))
        let data: Data = try await call(timeout: .seconds(120)) { proxy, done in
            proxy.moveSystemLeftovers(json) { data, error in
                if let data { done(.success(data)) } else { done(.failure(HelperClientError.remote(error ?? "unknown"))) }
            }
        }
        return try JSONDecoder().decode(SystemLeftovers.Result.self, from: data)
    }

    /// CPU time and memory of every process, read as root.
    func processCounters() async throws -> [ProcessCounter] {
        let data: Data = try await call(timeout: .seconds(4)) { proxy, done in
            proxy.processCounters { data, error in
                if let data { done(.success(data)) } else { done(.failure(HelperClientError.remote(error ?? "unknown"))) }
            }
        }
        return try JSONDecoder().decode([ProcessCounter].self, from: data)
    }

    func heartbeat() async throws {
        let _: Bool = try await call { proxy, done in
            proxy.heartbeat { done(.success(true)) }
        }
    }

    // MARK: Plumbing

    /// One retry on connection failure: after an app update the old helper exits on first contact
    /// and launchd starts the new one, so the second attempt reaches the right binary.
    private func call<T: Sendable>(
        timeout: Duration = .seconds(4),
        retryOnConnectionFailure: Bool = true,
        _ body: @escaping @Sendable (HelperXPC, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        guard status == .enabled else { throw HelperClientError.notEnabled(status) }
        do {
            return try await callOnce(timeout: timeout, body)
        } catch HelperClientError.timedOut {
            Self.logger.error("XPC call timed out after \(timeout)")
            throw HelperClientError.timedOut
        } catch HelperClientError.connection(let message) where retryOnConnectionFailure {
            // One retry on connection failure: after an app update the old helper exits on
            // first contact and launchd starts the new one, so the second attempt reaches it.
            Self.logger.warning("XPC connection failed, retrying once: \(message, privacy: .public)")
            resetConnection()
            try await Task.sleep(for: .milliseconds(600))
            return try await callOnce(timeout: timeout, body)
        } catch {
            Self.logger.warning("XPC call failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Drops the cached XPC connection. Called before Sparkle swaps the bundle so the old
    /// daemon is not held open across replacement, and before every repair attempt.
    func resetConnection() {
        lock.withLock {
            connection?.invalidate()
            connection = nil
        }
    }

    /// If launchd cannot spawn the helper, XPC neither replies nor errors; it waits forever.
    /// So every call has a deadline, after which we invalidate the connection, which makes
    /// XPC fire the proxy's error handler and resume the pending continuation.
    private func callOnce<T: Sendable>(
        timeout: Duration = .seconds(4),
        _ body: @escaping @Sendable (HelperXPC, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let timedOut = Once()
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            timedOut.run {}
            self?.resetConnection()
        }
        defer { timer.cancel() }
        do {
            return try await callUntimed(body)
        } catch {
            if timedOut.hasRun { throw HelperClientError.timedOut }
            throw error
        }
    }

    private func callUntimed<T: Sendable>(
        _ body: @escaping @Sendable (HelperXPC, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let conn = try currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let finish: @Sendable (Result<T, Error>) -> Void = { result in
                once.run { continuation.resume(with: result) }
            }
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                finish(.failure(HelperClientError.connection(error.localizedDescription)))
            }
            guard let helper = proxy as? HelperXPC else {
                finish(.failure(HelperClientError.connection("proxy does not conform to HelperXPC")))
                return
            }
            body(helper, finish)
        }
    }

    private func currentConnection() throws -> NSXPCConnection {
        try lock.withLock {
            if let connection { return connection }
            // Pin the helper we are about to talk to: the binary embedded in our own bundle.
            let helperURL = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(HelperConstants.helperExecutableName)")
            guard let requirement = CodeSigning.requirement(
                identifier: HelperConstants.helperBundleIdentifier, expected: CodeSigning.info(at: helperURL))
            else {
                Self.logger.fault("Could not read the embedded helper signature; refusing to connect")
                throw HelperClientError.untrustedHelper
            }

            let conn = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: HelperXPC.self)
            conn.setCodeSigningRequirement(requirement)
            conn.invalidationHandler = { [weak self] in
                self?.lock.withLock { self?.connection = nil }
            }
            conn.resume()
            connection = conn
            return conn
        }
    }
}

/// Runs a closure at most once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var hasRun: Bool { lock.withLock { done } }
    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
