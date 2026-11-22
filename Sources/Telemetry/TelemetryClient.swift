import Foundation
import OSLog

private let clientLogger = Logger(subsystem: "com.machelper.MacHelper", category: "telemetry.client")

public enum TelemetryLimits {
    public static let defaultBuffer = 100
}

/// Serializes event buffering and flushing. All mutable state lives inside the actor, so callers
/// on the main thread, the monitor loop and background tasks can record at the same time without
/// locking anything themselves.
public actor TelemetryClient<Transport: TelemetryTransport> {
    private let preferences: TelemetryPreferences
    private let transport: Transport
    private let bufferLimit: Int
    private var buffer: [TelemetryEvent] = []
    private var flushTask: Task<Void, Never>?

    public init(preferences: TelemetryPreferences, transport: Transport, bufferLimit: Int = TelemetryLimits.defaultBuffer) {
        self.preferences = preferences
        self.transport = transport
        self.bufferLimit = max(1, bufferLimit)
    }

    /// Exposed for the settings preview and for tests that assert opt-out cleared the queue.
    public var bufferedEventCount: Int { buffer.count }

    public var isEnabled: Bool { preferences.isEnabled }

    /// Starts the periodic flush. A client that is never configured sends nothing.
    public func startPeriodicFlush(interval: Duration = .seconds(60)) {
        guard flushTask == nil else { return }
        flushTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    clientLogger.debug("Periodic telemetry flush stopped: \(error.localizedDescription, privacy: .private)")
                    return
                }
                await self?.flush()
            }
        }
    }

    public func stopPeriodicFlush() {
        flushTask?.cancel()
        flushTask = nil
    }

    /// Applies the opt-in switch. Turning it off purges both the queue and the anonymous ID in
    /// one step; nothing is transmitted on the way out.
    public func setEnabled(_ enabled: Bool) async {
        preferences.setEnabled(enabled)
        guard enabled else {
            buffer.removeAll()
            stopPeriodicFlush()
            return
        }
        // A user can opt in long after launch; delivery must start at that moment, not at the
        // next app start. startPeriodicFlush is idempotent when the launch path already did it.
        startPeriodicFlush()
    }

    // MARK: - Convenience events

    /// `coldStartMsBucket` is already coarse (the caller rounds it); it is clamped again here so
    /// an accidental timestamp can never be forwarded as a value.
    public func recordAppLaunch(coldStartMsBucket: Int? = nil) {
        var properties: [String: String] = [:]
        if let ms = coldStartMsBucket {
            properties["cold_start_ms"] = String(min(max(ms, 0), 60_000))
        }
        enqueue(name: "app_launch", properties: properties)
    }

    /// Accepts a fixed section identifier such as "monitor"; anything else is dropped by the
    /// sanitizer rather than forwarded.
    public func recordSectionView(_ section: String) {
        enqueue(name: "section_view", properties: ["section": section])
    }

    public func recordAction(_ action: String, category: String) {
        enqueue(name: "action", properties: ["action": action, "category": category])
    }

    /// Both arguments are counts, converted to short integer tokens before sanitization.
    public func recordPerformanceSummary(mainThreadStalls: Int, memoryMBBucket: Int) {
        enqueue(name: "performance_summary", properties: [
            "main_thread_stalls": String(min(max(mainThreadStalls, 0), 999)),
            "memory_mb": String(min(max(memoryMBBucket, 0), 9999)),
        ])
    }

    // MARK: - Buffering and delivery

    /// Adds one event when opted in. The ring buffer drops the oldest entry at the limit, so
    /// memory use is bounded no matter how long a user stays opted in without a network.
    private func enqueue(name: String, properties: [String: String]) {
        guard preferences.isEnabled,
              let safeName = TelemetrySanitizer.sanitize(name: name) else { return }
        let event = TelemetryEvent(name: safeName,
                                   timestampBucket: TelemetrySanitizer.bucket(),
                                   properties: TelemetrySanitizer.sanitize(properties: properties))
        if buffer.count >= bufferLimit { buffer.removeFirst() }
        buffer.append(event)
    }

    /// Sends everything currently buffered. A failed batch is logged and discarded: telemetry is
    /// best-effort, and requeueing would reintroduce unbounded growth.
    public func flush() async {
        guard preferences.isEnabled, !buffer.isEmpty else { return }
        guard let installID = preferences.installID else { return }
        let events = buffer
        buffer.removeAll()
        let envelope = TelemetryEnvelope(installId: installID, events: events)
        do {
            try await transport.send(envelope)
        } catch {
            clientLogger.warning("Telemetry batch discarded: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// A deterministic example for the settings screen. It never depends on live preferences.
    public nonisolated static func samplePayloadJSON() -> String {
        TelemetrySample.payloadJSON()
    }
}

/// What the app builds. Production always wraps the URL transport in bounded retry.
public typealias DefaultTelemetryTransport = RetryingTelemetryTransport<URLSessionTelemetryTransport>
public typealias AppTelemetryClient = TelemetryClient<DefaultTelemetryTransport>
