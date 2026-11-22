import Foundation
import Testing
@testable import Telemetry

enum MockTransportError: Error, Sendable, Equatable {
    case transient
    case rejected
}

/// Actor-backed so concurrent callers cannot race on the counters.
actor RecordingTransport: TelemetryTransport {
    private var sent: [TelemetryEnvelope] = []
    private let failuresBeforeSuccess: Int
    private let failure: Error?

    init(failuresBeforeSuccess: Int = 0, failure: Error? = nil) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.failure = failure
    }

    func send(_ envelope: TelemetryEnvelope) async throws {
        sent.append(envelope)
        if sent.count <= failuresBeforeSuccess, let failure { throw failure }
    }

    func attemptCount() -> Int { sent.count }

    func eventProperties() -> [[String: String]] {
        sent.flatMap(\.events).map(\.properties)
    }

    func envelopes() -> [TelemetryEnvelope] { sent }
}

actor DelayRecorder {
    private(set) var values: [Duration] = []
    func add(_ duration: Duration) { values.append(duration) }
}

@Suite struct TelemetryTransportTests {
    private func envelope() -> TelemetryEnvelope {
        TelemetryEnvelope(installId: "test-install-id", events: [])
    }

    @Test func unconfiguredTransportThrowsInsteadOfSending() async {
        let transport = URLSessionTelemetryTransport(endpointResolver: { nil })
        do {
            try await transport.send(envelope())
            Issue.record("An unconfigured endpoint must not produce a request")
        } catch TelemetryTransportError.notConfigured {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func retriesTransientFailuresWithExponentialDelays() async throws {
        let base = RecordingTransport(failuresBeforeSuccess: 2, failure: MockTransportError.transient)
        let delays = DelayRecorder()
        let retry = RetryingTelemetryTransport(
            base: base,
            policy: TelemetryRetryPolicy(delays: [.milliseconds(1), .milliseconds(2), .milliseconds(4)]),
            sleep: { duration in await delays.add(duration) })

        try await retry.send(envelope())
        #expect(await base.attemptCount() == 3)
        #expect(await delays.values == [.milliseconds(1), .milliseconds(2)])
    }

    @Test func doesNotRetryARejectedPayload() async {
        let base = RecordingTransport(failuresBeforeSuccess: 1,
                                      failure: TelemetryTransportError.rejectedStatus(400))
        let delays = DelayRecorder()
        let retry = RetryingTelemetryTransport(base: base, sleep: { duration in await delays.add(duration) })

        do {
            try await retry.send(envelope())
            Issue.record("A rejected payload must surface its error")
        } catch TelemetryTransportError.rejectedStatus(400) {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await base.attemptCount() == 1)
        #expect(await delays.values.isEmpty)
    }

    @Test func givesUpAfterTheRetryBudget() async {
        let base = RecordingTransport(failuresBeforeSuccess: 99, failure: MockTransportError.transient)
        let retry = RetryingTelemetryTransport(
            base: base,
            policy: TelemetryRetryPolicy(delays: [.milliseconds(1), .milliseconds(2)]),
            sleep: { _ in })

        do {
            try await retry.send(envelope())
            Issue.record("All attempts failed")
        } catch MockTransportError.transient {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await base.attemptCount() == 3, "one initial attempt plus two retries")
    }
}
