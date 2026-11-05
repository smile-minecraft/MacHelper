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
        let result = log.readAll()
        entries = result.entries
        skippedLines = result.skippedLines
    }
}
