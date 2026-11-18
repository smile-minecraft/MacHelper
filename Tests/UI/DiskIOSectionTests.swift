import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DiskActivityFeature
@testable import Metrics

/// The production `DiskIOSection`, with only its display dependencies substituted (see
/// DiskIOSectionDisplayStandins.swift; the isolated verification package links those instead
/// of the app's design system). The section itself is the unmodified production source: it owns
/// the model and the `.task` that runs sampling.
///
/// The mount test hosts the real section in a window that is never ordered front or activated,
/// so mounting starts the `.task` and closing it cancels the loop, exactly what leaving the SSD
/// page does in the app.
@Suite(.serialized)
@MainActor
struct DiskIOSectionTests {
    // MARK: - Hosted lifetime

    @Test func theMountedSectionSamplesAndLeavingItStops() async throws {
        let probe = SamplingProbe()
        let model = DiskActivityModel(sample: { probeSnapshot(UInt64(probe.countOneRound())) })
        _ = NSApplication.shared
        let controller = NSHostingController(
            rootView: DiskIOSection(model: model, interval: .milliseconds(10)))
        let window = NSWindow(contentViewController: controller)
        // Never shown or activated: the section only needs a hosting context for .task to run.
        window.setFrame(NSRect(x: -10_000, y: -10_000, width: 320, height: 240), display: false)
        defer { window.close() }

        try await waitUntil(timeout: 3) { probe.count >= 2 && model.snapshot != nil }
        #expect(model.snapshot != nil)

        window.contentViewController = nil
        window.close()
        try? await Task.sleep(for: .milliseconds(300))
        let stoppedAt = probe.count
        let frozen = try #require(model.snapshot)
        try? await Task.sleep(for: .milliseconds(400))

        // The numbers stay on screen; they are not a new sample.
        #expect(probe.count == stoppedAt)
        #expect(model.snapshot == frozen)
    }

    // MARK: - The section's ranking

    // The sampler pins its own order; this checks what the page displays, which is the same rule but
    // lives in the section. Both are exact-order checks on controlled data.

    @Test func theFormalSectionRanksByRateThenTotalThenIdentifier() throws {
        let items = [
            usage("slow", read: 1_000, write: 0),
            usage("beta", read: 1_000, write: 1_000, totalWrite: 6_000),
            usage("fast", read: 2_000, write: 1_000),
            usage("alpha", read: 1_000, write: 1_000, totalWrite: 6_000),
            usage("light", read: 2_000, write: 0, totalWrite: 2_100),
            // Same rate as the rest at 2,000 B/s but a much larger total, so it lands ahead of them.
            usage("heavy", read: 2_000, write: 0, totalWrite: 1_000_000),
        ]
        let ranked = DiskIOSection.ranked(snapshot(items))
        #expect(ranked.map(\.id) == ["fast", "heavy", "alpha", "beta", "light", "slow"])
    }

    @Test func theFormalSectionWithoutRatesOrdersByTotalBytes() throws {
        // Before the first rates exist every row reports a nil rate; the section must order by total
        // bytes, then by id, instead of presenting zeros in a meaningless order.
        let items = [
            usage("small", totalRead: 5_000, totalWrite: 7_000),    // 12,000
            usage("big", totalRead: 400_000, totalWrite: 500_000),  // 900,000
            usage("mid", totalRead: 8_000, totalWrite: 4_000),      // 12,000; before "small" by id
        ]
        let ranked = DiskIOSection.ranked(snapshot(items))
        #expect(ranked.map(\.id) == ["big", "mid", "small"])
    }

    private func usage(_ id: String, read: Double? = nil, write: Double? = nil,
                       totalRead: UInt64 = 0, totalWrite: UInt64 = 0) -> ProcessDiskIOUsage {
        ProcessDiskIOUsage(id: id, name: id, path: nil, appPath: nil, processCount: 1,
                           readBytesPerSecond: read, writeBytesPerSecond: write,
                           totalReadBytes: totalRead, totalWriteBytes: totalWrite)
    }

    private func snapshot(_ items: [ProcessDiskIOUsage]) -> ProcessDiskIOSnapshot {
        ProcessDiskIOSnapshot(capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                              items: items,
                              hasRates: items.allSatisfy { $0.readBytesPerSecond != nil },
                              hiddenCount: 0)
    }
}
