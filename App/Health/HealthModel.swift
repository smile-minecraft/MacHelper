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
            self.diskPoints = points
            error = nil
        case .failure(let failure):
            error = failure.localizedDescription
        }
        loading = false
    }
}
