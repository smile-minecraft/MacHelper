import CleanEngine
import Diagnostics
import Foundation
import Observation
import Storage

@MainActor
@Observable
final class HealthModel {
    enum Window: Double, CaseIterable, Identifiable {
        case hour = 1, day = 24, week = 168
        var id: Double { rawValue }
    }

    var window: Window = .day
    private(set) var report: HealthReport?
    private(set) var diskPoints: [DiskSpacePoint] = []
    private(set) var loading = false
    private(set) var error: String?
    /// macOS security settings, read with Apple's status commands (independent of the period).
    private(set) var security: [SecurityCheck]?
    private(set) var checkingSecurity = false
    /// The last 24-hour check, which the health score is based on whatever period the page shows.
    private(set) var scoreReport: HealthReport?
    @ObservationIgnored private var scoreTask: Task<Void, Never>?

    /// The health score from the live readings and the last 24-hour check.
    func score(store: MonitorStore) -> HealthScore? {
        guard scoreReport != nil || store.disk != nil else { return nil }
        let memory: HealthScore.Memory? = store.memory.map {
            switch $0.pressure {
            case .normal: .normal
            case .warning: .warning
            case .critical: .critical
            }
        }
        return HealthScore.compute(report: scoreReport, freeBytes: store.diskFreeBytes.map(Double.init), memory: memory)
    }

    /// Re-runs the 24-hour check every few minutes for the score (overview, health page, menu bar).
    func startScoreUpdates(history: @escaping @MainActor () -> MetricsHistory?) {
        guard scoreTask == nil else { return }
        scoreTask = Task { [weak self] in
            while !Task.isCancelled {
                if let history = history(), let report = try? await Self.check(history: history, hours: 24) {
                    self?.scoreReport = report
                }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private static func check(history: MetricsHistory, hours: Double) async throws -> HealthReport {
        // Through the Helper, cached for a few minutes, and never sfltool (which would ask for a password).
        let backgroundCount: Int? = switch await BackgroundItemsSource.load() {
        case .success(let items): BackgroundItems.activeCount(items)
        case .failure: nil
        }
        return try await Task.detached(priority: .utility) {
            var system = SystemSnapshot.current()
            system.activeBackgroundItems = backgroundCount
            return try HealthCheck.run(history: history, hours: hours, system: system)
        }.value
    }

    func loadSecurity() async {
        guard !checkingSecurity else { return }
        checkingSecurity = true
        security = await Task.detached(priority: .userInitiated) { SecurityAudit.run() }.value
        checkingSecurity = false
    }

    func load(history: MetricsHistory?) async {
        guard !loading else { return }
        guard let history else {
            error = String(localized: "The history database couldn’t be opened.")
            return
        }
        loading = true
        let hours = window.rawValue
        // Through the Helper, cached for a few minutes: switching the period never re-reads it,
        // and nothing here runs sfltool (which would ask for a password).
        let backgroundCount: Int? = switch await BackgroundItemsSource.load() {
        case .success(let items): BackgroundItems.activeCount(items)
        case .failure: nil
        }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(HealthReport, [DiskSpacePoint]), Error> in
            Result {
                var system = SystemSnapshot.current()
                system.activeBackgroundItems = backgroundCount
                let report = try HealthCheck.run(history: history, hours: hours, system: system)
                let points = try history.diskSpace(since: Date().addingTimeInterval(-30 * 86_400))
                return (report, points)
            }
        }.value
        switch result {
        case .success(let (report, points)):
            self.report = report
            if hours == 24 { scoreReport = report }
            self.diskPoints = points
            error = nil
        case .failure(let failure):
            error = failure.localizedDescription
        }
        loading = false
    }
}
