import CleanEngine
import Foundation
import Observation

@MainActor
@Observable
final class OperationHistoryModel {
    enum Period: String, CaseIterable, Identifiable {
        case today, week, month, all

        var id: String { rawValue }

        func start(from now: Date = .now, calendar: Calendar = .current) -> Date? {
            switch self {
            case .today: calendar.startOfDay(for: now)
            case .week: calendar.date(byAdding: .day, value: -7, to: now)
            case .month: calendar.date(byAdding: .day, value: -30, to: now)
            case .all: nil
            }
        }
    }

    private let log: OperationLog
    private(set) var entries: [OperationLog.Entry] = []
    private(set) var skippedLines = 0
    var period: Period = .all
    var kind: OperationKind?

    enum Display: String, CaseIterable, Identifiable { case records, bySource, byMonth; var id: String { rawValue } }
    var display: Display = .records
    /// Rule, task and detector titles by the id written in the log's `source` field.
    private(set) var sourceTitles: [String: String] = [:]

    var sourceStats: [OperationSourceStats] { OperationSourceStats.compute(filtered) }
    var monthTotals: [OperationMonthTotal] { OperationMonthTotal.compute(filtered) }

    func title(for source: String) -> String {
        if let t = sourceTitles[source] { return t }
        if source.hasPrefix("purge."), let t = sourceTitles[String(source.dropFirst(6))] { return t }
        return source
    }

    init(log: OperationLog = .shared) {
        self.log = log
    }

    var filtered: [OperationLog.Entry] {
        OperationHistoryFilter(kind: kind, from: period.start()).apply(to: entries)
    }

    var summary: OperationHistorySummary {
        OperationHistorySummary(entries: filtered)
    }

    func load() {
        if sourceTitles.isEmpty {
            var titles: [String: String] = [:]
            for r in (try? RuleSet.load()) ?? [] { titles[r.id] = r.title }
            for t in MaintenanceCatalog.all { titles[t.id] = t.title }
            for t in SystemCleanupCatalog.all { titles[t.id] = t.title }
            for d in (try? ArtifactDetector.loadBuiltIn()) ?? [] { titles[d.id] = d.title }
            sourceTitles = titles
        }
        let result = log.readAll()
        entries = result.entries
        skippedLines = result.skippedLines
    }
}
