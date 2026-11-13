import Metrics
import SwiftUI

/// The network page's live section: it owns the visible-period refresh loop and hands each
/// captured snapshot to the presentation-only `NetworkDetailsContent`.
///
/// `NetworkDetailsSampler.snapshot()` is synchronous and may perform `getifaddrs`, `sysctl` and
/// SystemConfiguration reads, so every call is made from a detached background task. The loop runs
/// only while the section is visible; hiding it cancels the loop and invalidates its generation so a
/// read that is already in flight cannot replace a newer result.
///
/// `NetworkTab` in MonitorPanel.swift calls this section without arguments, so each rebuild of the
/// tab creates a new `NetworkDetailsSectionModel` backed by a new `NetworkDetailsSampler` with an
/// empty cache. Re-entering the network page therefore reads the system again; the 15-second cache
/// only absorbs repeated starts while one section instance stays alive. The page passes no
/// `isActive` flag and keeps only the selected tab in the hierarchy, so `onAppear`/`onDisappear`
/// drive the loop.
///
/// A page that keeps all tabs in the hierarchy should pass the selected-tab flag instead;
/// `onAppear`/`onDisappear` alone do not fire when a tab is merely deselected.
///
/// The periodic read deliberately calls `snapshot()`, not `refresh()`: the sampler's 15-second cache
/// absorbs repeated starts while the section stays alive, while the 30-second loop keeps the expensive
/// system queries off a per-second path. The view never synthesises an empty or offline snapshot while
/// the first read is pending; it shows a loading indicator instead.
///
/// Not yet verified: the native menu popover's real lifecycle and the latency of real system reads.
struct NetworkDetailsSection: View {
    @StateObject private var model: NetworkDetailsSectionModel
    private let isActive: Bool

    init(sampler: NetworkDetailsSampler = NetworkDetailsSampler(),
         interval: Duration = .seconds(30),
         isActive: Bool = true) {
        _model = StateObject(wrappedValue: NetworkDetailsSectionModel(sampler: sampler,
                                                                      interval: interval))
        self.isActive = isActive
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                loading
            case .loaded(let snapshot):
                NetworkDetailsContent(snapshot: snapshot)
            }
        }
        .onAppear { model.setVisible(isActive) }
        .onDisappear { model.setVisible(false) }
        .onChange(of: isActive) { _, active in model.setVisible(active) }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(NetworkDetailsText.networkDetails.localized())
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Owns the section's visibility state and its single refresh loop.
///
/// The model is main-actor isolated: every published state change happens on the main thread.
/// The blocking sampler read runs in a detached task, and the loop awaits it before scheduling the
/// next read, so at most one read is outstanding for one loop.
@MainActor
final class NetworkDetailsSectionModel: ObservableObject {
    enum State: Equatable, Sendable {
        /// No snapshot has been produced yet. The view must not turn this into "offline" or zeroes.
        case loading
        /// The snapshot carries its own read-failure state (`interfaces == .unavailable(.readFailed)`);
        /// the section does not convert that into loading or an empty list.
        case loaded(NetworkDetailsSnapshot)
    }

    @Published private(set) var state: State = .loading

    let interval: Duration

    private let sampler: NetworkDetailsSampler
    private let sleeper: @Sendable (Duration) async throws -> Void
    private var loopTask: Task<Void, Never>?
    private var generation = 0
    private var isVisible = false

    init(sampler: NetworkDetailsSampler = NetworkDetailsSampler(),
         interval: Duration = .seconds(30),
         sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sampler = sampler
        self.interval = interval
        self.sleeper = sleeper
    }

    /// Starts the loop on the first visible transition and stops it on the next hidden one.
    /// Repeated calls with the same value are ignored, so SwiftUI re-appearances cannot leave
    /// duplicate timers behind.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        generation += 1
        loopTask?.cancel()
        loopTask = nil
        guard visible else { return }

        let generation = generation
        loopTask = Task { [weak self] in
            await self?.runLoop(generation: generation)
        }
    }

    private func runLoop(generation: Int) async {
        while !Task.isCancelled,
              isVisible,
              generation == self.generation {
            let sampler = self.sampler
            // The sampler is thread-safe, but its read can block. Keep it off the main actor.
            let snapshot = await Task.detached(priority: .utility) {
                sampler.snapshot()
            }.value

            // A stop or restart may have happened while the read was in flight. Do not let that
            // older result replace the newer loop's state.
            guard !Task.isCancelled,
                  isVisible,
                  generation == self.generation else { return }
            state = .loaded(snapshot)

            do {
                try await sleeper(interval)
            } catch {
                return
            }
        }
    }
}
