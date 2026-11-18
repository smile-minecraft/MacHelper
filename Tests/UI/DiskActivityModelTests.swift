import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DiskActivityFeature
@testable import Metrics

/// Lifecycle of the production `DiskActivityModel`.
///
/// The sampler is replaced by a counter so the tests can see every round the model starts. The
/// host test uses a real SwiftUI hosting view with the same `.task { await model.run() }` shape
/// the disk page uses; it never shows or activates a window. Nothing here reads the machine's
/// disk or starts the app.
@Suite(.serialized)
@MainActor
struct DiskActivityModelLifecycleTests {
    // MARK: - Static screen

    @Test func aModelThatIsNotStartedNeverSamples() async throws {
        let probe = SamplingProbe()
        let model = DiskActivityModel(sample: { probeSnapshot(UInt64(probe.countOneRound())) })
        try await Task.sleep(for: .milliseconds(150))
        #expect(probe.count == 0)
        #expect(model.snapshot == nil)
    }

    // MARK: - Model cancellation

    @Test func runStopsWhenCancelledAndDropsTheRoundInFlight() async throws {
        let probe = SamplingProbe(slowCall: 2, slowSeconds: 0.2)
        let model = DiskActivityModel(sample: { probeSnapshot(UInt64(probe.countOneRound())) })
        let task = Task { await model.run(interval: .milliseconds(10)) }

        try await waitUntil { model.snapshot != nil }
        #expect(model.snapshot?.items.first?.readBytesPerSecond == 1)

        try await waitUntil { probe.count >= 2 }
        task.cancel()
        await task.value

        // The detached round that had already started may finish, but its result is dropped and
        // no new round begins.
        #expect(probe.count == 2)
        #expect(model.snapshot?.items.first?.readBytesPerSecond == 1)

        try await Task.sleep(for: .milliseconds(150))
        #expect(probe.count == 2)
        #expect(model.snapshot?.items.first?.readBytesPerSecond == 1)
    }

    @Test func stopEndsTheLoopStartedByStart() async throws {
        let probe = SamplingProbe()
        let model = DiskActivityModel(sample: { probeSnapshot(UInt64(probe.countOneRound())) })
        model.start(interval: .milliseconds(10))
        try await waitUntil { probe.count >= 2 }

        model.stop()
        let frozen = try #require(model.snapshot)
        let stoppedAt = probe.count
        try await Task.sleep(for: .milliseconds(150))

        // The last numbers stay on screen; the frozen picture is not a new sample.
        #expect(probe.count == stoppedAt)
        #expect(model.snapshot == frozen)

        model.start(interval: .milliseconds(10))
        try await waitUntil { probe.count > stoppedAt }
        model.stop()
    }

    // MARK: - Leaving a hosted page

    private struct SamplingPageHost: View {
        let model: DiskActivityModel

        var body: some View {
            Text(verbatim: "disk page host")
                .task { await model.run(interval: .milliseconds(10)) }
        }
    }

    @Test func aHostedPageSamplesAndLeavingItStopsTheLoop() async throws {
        let probe = SamplingProbe()
        let model = DiskActivityModel(sample: { probeSnapshot(UInt64(probe.countOneRound())) })
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: SamplingPageHost(model: model))
        let window = NSWindow(contentViewController: controller)
        // Never ordered front or activated: the view only needs a hosting context, not a visible
        // window, for the .task modifier to run.
        window.setFrame(NSRect(x: -10_000, y: -10_000, width: 240, height: 80), display: false)
        defer { window.close() }

        try await waitUntil(timeout: 3) { probe.count >= 2 }
        #expect(probe.count >= 2)
        #expect(model.snapshot != nil)

        window.contentViewController = nil
        window.close()
        try? await Task.sleep(for: .milliseconds(300))
        let stoppedAt = probe.count
        let frozen = try #require(model.snapshot)
        try? await Task.sleep(for: .milliseconds(400))

        #expect(probe.count == stoppedAt)
        #expect(model.snapshot == frozen)
    }
}
