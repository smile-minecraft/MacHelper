import Foundation
import OSLog

private let transportLogger = Logger(subsystem: "com.machelper.MacHelper", category: "telemetry.transport")

/// Default retry delay. It is file-private; the public initializer uses `nil` as its default so
/// no private symbol has to appear in a public default argument.
private func telemetryRetrySleep(_ duration: Duration) async {
    do {
        try await Task.sleep(for: duration)
    } catch {
        transportLogger.debug("Retry delay interrupted: \(error.localizedDescription, privacy: .private)")
    }
}

/// Failures the retry layer understands. A rejected payload is never retried; a missing endpoint
/// is treated as "do nothing" by the client, not as an error worth reporting to the user.
public enum TelemetryTransportError: Error, Sendable, Equatable {
    case notConfigured
    case transientStatus(Int)
    case rejectedStatus(Int)
    case networkFailure
}

/// The whole transport contract. Tests substitute a counter or a failing implementation here.
public protocol TelemetryTransport: Sendable {
    func send(_ envelope: TelemetryEnvelope) async throws
}

/// Delays between attempts. Injectable so tests can use `.immediate` and stay deterministic.
public struct TelemetryRetryPolicy: Sendable {
    public var delays: [Duration]

    public init(delays: [Duration]) {
        self.delays = delays
    }

    public static let `default` = TelemetryRetryPolicy(delays: [.milliseconds(500), .seconds(1), .seconds(2)])
    public static let immediate = TelemetryRetryPolicy(delays: [])
}

/// POSTs one envelope as JSON. The endpoint is resolved at send time so a build with an empty
/// `MHTelemetryEndpointURL` stays silent even if preferences change later.
public struct URLSessionTelemetryTransport: TelemetryTransport {
    private let endpointResolver: @Sendable () -> URL?
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        endpointResolver: @escaping @Sendable () -> URL? = { nil },
        session: URLSession = .shared,
        timeout: TimeInterval = 8
    ) {
        self.endpointResolver = endpointResolver
        self.session = session
        self.timeout = timeout
    }

    public func send(_ envelope: TelemetryEnvelope) async throws {
        guard let endpoint = endpointResolver() else {
            throw TelemetryTransportError.notConfigured
        }
        let data = try JSONEncoder().encode(envelope)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = timeout

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TelemetryTransportError.networkFailure
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 408, 429, 500...599:
            throw TelemetryTransportError.transientStatus(http.statusCode)
        default:
            throw TelemetryTransportError.rejectedStatus(http.statusCode)
        }
    }
}

/// Adds bounded exponential backoff around any transport.
///
/// The retry budget comes from `policy.delays.count`, so the maximum number of attempts and the
/// total time spent are both fixed. A failed batch is dropped by the client afterwards; there is
/// no unbounded retry queue to grow without limit.
public struct RetryingTelemetryTransport<Base: TelemetryTransport>: TelemetryTransport {
    private let base: Base
    private let policy: TelemetryRetryPolicy
    private let sleep: @Sendable (Duration) async -> Void

    public init(
        base: Base,
        policy: TelemetryRetryPolicy = .default,
        sleep: (@Sendable (Duration) async -> Void)? = nil
    ) {
        self.base = base
        self.policy = policy
        self.sleep = sleep ?? telemetryRetrySleep
    }

    public func send(_ envelope: TelemetryEnvelope) async throws {
        var attempt = 0
        while true {
            do {
                try await base.send(envelope)
                return
            } catch {
                guard attempt < policy.delays.count, Self.isRetryable(error) else {
                    transportLogger.warning("Telemetry send gave up after \(attempt + 1) attempt(s): \(error.localizedDescription, privacy: .private)")
                    throw error
                }
                transportLogger.notice("Telemetry send failed, retrying: \(error.localizedDescription, privacy: .private)")
                await sleep(policy.delays[attempt])
                attempt += 1
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let transportError = error as? TelemetryTransportError else { return true }
        switch transportError {
        case .transientStatus, .networkFailure: return true
        case .notConfigured, .rejectedStatus: return false
        }
    }
}
