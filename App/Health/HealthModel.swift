import CleanEngine
import Diagnostics
import Foundation
import Observation
import Storage

@MainActor
@Observable
final class HealthModel {
    enum Window: Double, CaseIterable, Identifiable, Hashable {
        case hour = 1, day = 24, week = 168
        var id: Double { rawValue }
    }

    /// A report is a snapshot of stored history plus a few live readings; a minute-old copy is
    /// close enough to keep the page instant while the next one is computed.
    static let reportMaxAge: TimeInterval = 60
    /// Security settings change only when the user changes them; checking costs several tools.
    static let securityMaxAge: TimeInterval = 300

    private struct CachedReport {
        let report: HealthReport
        let diskPoints: [DiskSpacePoint]
        let at: Date
    }

    var window: Window = .day
    private(set) var report: HealthReport?
    private(set) var diskPoints: [DiskSpacePoint] = []
    /// True while the page has no report to show and a check is running.
    private(set) var loading = false
    /// True while an older report is on screen and a newer one is being computed.
    private(set) var updating = false
    private(set) var error: String?
    /// macOS security settings, read with Apple's status commands (independent of the period).
    private(set) var security: [SecurityCheck]?
    private(set) var checkingSecurity = false
    /// The last 24-hour check, which the health score is based on whatever period the page shows.
    private(set) var scoreReport: HealthReport?
    @ObservationIgnored private var scoreTask: Task<Void, Never>?
    @ObservationIgnored private var cachedReports: [Window: CachedReport] = [:]
    @ObservationIgnored private var securityUpdatedAt: Date?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?

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

    func loadSecurity(forceRefresh: Bool = false) async {
        if !forceRefresh, let security, let at = securityUpdatedAt, Date().timeIntervalSince(at) < Self.securityMaxAge {
            PageLoadProbe.mark(.health, "security")
            return
        }
        guard !checkingSecurity else { return }
        checkingSecurity = true
        security = await Task.detached(priority: .userInitiated) { SecurityAudit.run() }.value
        securityUpdatedAt = Date()
        checkingSecurity = false
        PageLoadProbe.mark(.health, "security")
    }

    func load(history: MetricsHistory?, forceRefresh: Bool = false) async {
        guard let history else {
            error = String(localized: "The history database couldn’t be opened.")
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        let target = window
        let hours = target.rawValue

        if !forceRefresh, let cached = cachedReports[target] {
            report = cached.report
            diskPoints = cached.diskPoints
            error = nil
            PageLoadProbe.mark(.health, "cache")
            PageLoadProbe.mark(.health, "content")
            if Date().timeIntervalSince(cached.at) < Self.reportMaxAge {
                if BackgroundItemsSource.cachedActiveCount == nil {
                    refreshBackgroundCount(history: history, window: target)
                }
                // This call returns without computing anything, and the generation bump above
                // makes an older in-flight check drop its results, so that check's defer never
                // clears these flags. Clear them here or the page can stay on "Updating…".
                loading = false
                updating = false
                return
            }
        } else if target == .day, cachedReports[.day] == nil, let scoreReport {
            // The overview's five-minute score check already has a 24-hour report. Show it
            // instead of an empty page while this page's own check runs.
            report = scoreReport
            PageLoadProbe.mark(.health, "content")
        }

        if report == nil {
            loading = true
        } else {
            updating = true
        }
        defer {
            if loadGeneration == generation {
                loading = false
                updating = false
            }
        }

        // Reading the background-item list through the Helper can take a moment when it has
        // not been read yet. Use a recent count when there is one and fill it in afterwards,
        // so the report is not held back by an optional column.
        let backgroundCount = BackgroundItemsSource.cachedActiveCount
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(HealthReport, [DiskSpacePoint]), Error> in
            Result {
                var system = SystemSnapshot.current()
                system.activeBackgroundItems = backgroundCount
                let report = try HealthCheck.run(history: history, hours: hours, system: system)
                let points = try history.diskSpace(since: Date().addingTimeInterval(-30 * 86_400))
                return (report, points)
            }
        }.value
        guard loadGeneration == generation, window == target else { return }
        switch result {
        case .success(let (report, points)):
            self.report = report
            if hours == 24 { scoreReport = report }
            self.diskPoints = points
            cachedReports[target] = CachedReport(report: report, diskPoints: points, at: Date())
            error = nil
            PageLoadProbe.mark(.health, "content")
            PageLoadProbe.mark(.health, "refresh")
            if backgroundCount == nil {
                refreshBackgroundCount(history: history, window: target)
            }
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }

    /// Fills in the optional background-item count after the page is already visible.
    /// A short delay keeps a quick page switch from competing with the Helper read.
    private func refreshBackgroundCount(history: MetricsHistory, window: Window) {
        backgroundTask?.cancel()
        backgroundTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.window == window else { return }
            let count: Int?
            switch await BackgroundItemsSource.load() {
            case .success(let items): count = BackgroundItems.activeCount(items)
            case .failure: count = nil
            }
            guard let count else { return }
            let report = await Task.detached(priority: .utility) {
                var system = SystemSnapshot.current()
                system.activeBackgroundItems = count
                return try? HealthCheck.run(history: history, hours: window.rawValue, system: system)
            }.value
            guard let report, self.window == window else { return }
            self.report = report
            self.cachedReports[window] = CachedReport(report: report, diskPoints: self.diskPoints, at: Date())
            PageLoadProbe.mark(.health, "background")
        }
    }

    /// Stops the optional background-item read when the page closes.
    func cancelBackgroundRefresh() {
        backgroundTask?.cancel()
        backgroundTask = nil
    }
}
