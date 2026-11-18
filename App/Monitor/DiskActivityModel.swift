import Foundation
import Metrics
import Observation

/// Per-app disk I/O for the menu panel's SSD page. Sampling runs only while the page is hosted:
/// `run()` loops until its calling task is cancelled, and `stop()` cancels the task variant
/// started by `start()`; either way the page's lifetime bounds the sampling.
@MainActor
@Observable
final class DiskActivityModel {
    private(set) var snapshot: ProcessDiskIOSnapshot?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let sampler = ProcessDiskIOSampler()
    @ObservationIgnored private let sampleOverride: (@Sendable () -> ProcessDiskIOSnapshot?)?

    init() {
        sampleOverride = nil
    }

    /// Test seam: replaces the system read. Start and stop still belong to the model.
    init(sample: @escaping @Sendable () -> ProcessDiskIOSnapshot?) {
        sampleOverride = sample
    }

    func start(interval: Duration = .seconds(2)) {
        guard task == nil else { return }
        sampler.reset()
        task = Task { [weak self] in
            await self?.loop(interval: interval)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Runs the sampling loop until the caller's task is cancelled. The page awaits this from its
    /// `.task`, so leaving the page or closing the panel ends the loop.
    func run(interval: Duration = .seconds(2)) async {
        sampler.reset()
        await loop(interval: interval)
    }

    private func loop(interval: Duration) async {
        let override = sampleOverride
        let sampler = sampler
        while !Task.isCancelled {
            let next = await Task.detached(priority: .utility) {
                override?() ?? sampler.sample()
            }.value
            guard !Task.isCancelled else { return }
            if let next { snapshot = next }
            try? await Task.sleep(for: interval)
        }
    }
}
