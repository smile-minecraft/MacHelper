import FanControl
import Foundation
import HelperProtocol
import PrivilegedOps
import ServiceManagement
import SMCKit

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
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    var status: SMAppService.Status { service.status }

    private static let registeredHashKey = "helper.registeredCDHash"

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

    /// With a Team ID the constraint follows the team, so updates need no re-registration.
    var needsReregistration: Bool {
        guard status == .enabled, CodeSigning.currentProcess()?.isAdHoc ?? true else { return false }
        return registeredHelperHash != embeddedHelperHash
    }

    /// For a not-yet-approved daemon, `register()` throws "Operation not permitted" even though
    /// the registration was submitted (status becomes `.requiresApproval`). That is not a failure.
    func register() throws {
        do {
            try service.register()
        } catch where status == .requiresApproval {
            UserDefaults.standard.set(embeddedHelperHash, forKey: Self.registeredHashKey)
            return
        }
        UserDefaults.standard.set(embeddedHelperHash, forKey: Self.registeredHashKey)
    }

    func unregister() async throws {
        resetConnection()
        try await service.unregister()
        UserDefaults.standard.removeObject(forKey: Self.registeredHashKey)
    }

    /// After an app update (ad-hoc signing), re-register so launchd's constraint matches the new
    /// helper. Tries an in-place `register()` first; if that leaves the old constraint in place the
    /// caller sees a timeout and can fall back to `reinstall()`.
    @discardableResult
    func refreshRegistrationIfNeeded() throws -> Bool {
        guard needsReregistration else { return false }
        resetConnection()
        try register()
        return true
    }

    /// Full unregister + register. May require approving the helper again in System Settings.
    func reinstall() async throws {
        try? await unregister()
        // unregister() returns before launchd/BTM finish removing the job; registering too early
        // fails and leaves the service unregistered.
        for _ in 0..<50 where status != .notRegistered {
            try await Task.sleep(for: .milliseconds(100))
        }
        try register()
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Calls

    func handshake() async throws -> (protocolVersion: Int, helperVersion: String) {
        let result: (Int, String) = try await call { proxy, done in
            proxy.handshake { v, s in done(.success((v, s))) }
        }
        guard result.0 == HelperConstants.protocolVersion else {
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

    /// Old system logs and diagnostic reports (fixed folders, older than 30 days). Deleting is permanent.
    func systemCleanup(_ request: SystemCleanupRequest) async throws -> SystemCleanupResult {
        let json = try JSONEncoder().encode(request)
        let data: Data = try await call(timeout: .seconds(60)) { proxy, done in
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
        _ body: @escaping @Sendable (HelperXPC, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        guard status == .enabled else { throw HelperClientError.notEnabled(status) }
        do {
            return try await callOnce(timeout: timeout, body)
        } catch HelperClientError.timedOut {
            throw HelperClientError.timedOut
        } catch HelperClientError.connection {
            resetConnection()
            try await Task.sleep(for: .milliseconds(600))
            return try await callOnce(timeout: timeout, body)
        }
    }

    private func resetConnection() {
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
            else { throw HelperClientError.untrustedHelper }

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
