import Foundation
import Testing
@testable import Metrics

/// Fixtures shared by the production-module lifecycle tests. The tests stub the kernel read with a
/// counter so they can see every sampling round the model starts; nothing here touches the disk.

/// Counts rounds and can hold one chosen round open, so cancellation can happen while a detached
/// sample is still in flight.
final class SamplingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private let slowCall: Int
    private let slowSeconds: TimeInterval

    init(slowCall: Int = 0, slowSeconds: TimeInterval = 0) {
        self.slowCall = slowCall
        self.slowSeconds = slowSeconds
    }

    func countOneRound() -> Int {
        let round = lock.withLock {
            value += 1
            return value
        }
        if round == slowCall { Thread.sleep(forTimeInterval: slowSeconds) }
        return round
    }

    var count: Int { lock.withLock { value } }
}

/// Runs on the main actor so the condition may read main-actor state (the model's snapshot).
@MainActor func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct WaitTimeout: Error {}

/// A snapshot whose only meaningful field is the marker, used as an obvious fake.
func probeSnapshot(_ marker: UInt64) -> ProcessDiskIOSnapshot {
    ProcessDiskIOSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(marker)),
        items: [
            ProcessDiskIOUsage(id: "probe", name: "probe", path: nil, appPath: nil, processCount: 1,
                               readBytesPerSecond: Double(marker), writeBytesPerSecond: 0,
                               totalReadBytes: marker, totalWriteBytes: 0),
        ],
        hasRates: true,
        hiddenCount: 0
    )
}
