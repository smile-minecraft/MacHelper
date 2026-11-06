import Foundation
import Testing
@testable import CleanEngine

private func logEntry(_ time: Date, command: String, path: String = "", bytes: UInt64 = 0,
                      result: String, message: String? = nil) -> OperationLog.Entry {
    OperationLog.Entry(time: time, command: command, path: path, source: "test",
                       bytes: bytes, result: result, message: message)
}

private func encodedLines(_ entries: [OperationLog.Entry]) throws -> [String] {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try entries.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
}

private func write(lines: [String], to url: URL) throws {
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
}

@Suite struct OperationHistoryTests {
    @Test func emptyFileReadsAsEmpty() throws {
        let t = try TempDir()
        let url = t.url.appending(path: "operations.jsonl")
        try Data().write(to: url)

        let result = OperationLog(url: url).readAll()

        #expect(result.entries.isEmpty)
        #expect(result.skippedLines == 0)
    }

    @Test func corruptLinesAreSkippedAndCounted() throws {
        let t = try TempDir()
        let url = t.url.appending(path: "operations.jsonl")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = old.addingTimeInterval(60)
        var lines = try encodedLines([logEntry(old, command: "uninstall", path: "/tmp/old", result: "failed")])
        lines.append("{ this is not json")
        lines.append(contentsOf: try encodedLines([logEntry(new, command: "clean", path: "/tmp/new", result: "trashed")]))
        try write(lines: lines, to: url)

        let result = OperationLog(url: url).readAll()

        #expect(result.entries.map(\.path) == ["/tmp/new", "/tmp/old"])
        #expect(result.skippedLines == 1)
    }

    @Test func readAllReturnsMoreThanTheDefaultLimit() throws {
        let t = try TempDir()
        let url = t.url.appending(path: "operations.jsonl")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (0..<250).map {
            logEntry(now.addingTimeInterval(Double($0)), command: "clean", path: "/tmp/\($0)", result: "trashed")
        }
        try write(lines: try encodedLines(entries), to: url)

        #expect(OperationLog(url: url).readAll().entries.count == 250)
    }

    @Test func classifiesKindsAndStatuses() {
        let cases: [(String, OperationKind)] = [
            ("clean", .cleanup), ("autoclean", .cleanup), ("purge", .cleanup),
            ("uninstall", .uninstall), ("startup", .startup), ("optimize", .maintenance),
            ("analyze", .diskAnalysis), ("test-scheduled-clean", .other),
        ]
        for (command, kind) in cases {
            #expect(logEntry(.now, command: command, result: "trashed").kind == kind)
        }

        let succeeded = ["trashed", "deleted", "ok", "enabled", "disabled"]
        for result in succeeded {
            #expect(logEntry(.now, command: "clean", result: result).status == .succeeded)
        }
        #expect(logEntry(.now, command: "clean", result: "failed").status == .failed)
        #expect(logEntry(.now, command: "clean", result: "skipped").status == .skipped)
    }

    @Test func filtersByTimeRangeAndKind() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            logEntry(start.addingTimeInterval(10), command: "clean", path: "a", result: "trashed"),
            logEntry(start.addingTimeInterval(20), command: "uninstall", path: "b", result: "trashed"),
            logEntry(start.addingTimeInterval(30), command: "clean", path: "c", result: "deleted"),
            logEntry(start.addingTimeInterval(40), command: "optimize", path: "d", result: "ok"),
        ]

        let window = OperationHistoryFilter(kind: .cleanup,
                                            from: start.addingTimeInterval(15),
                                            to: start.addingTimeInterval(35))
        #expect(window.apply(to: entries).map(\.path) == ["c"])
        #expect(OperationHistoryFilter(kind: .cleanup).apply(to: entries).map(\.path) == ["a", "c"])
        #expect(OperationHistoryFilter(from: start.addingTimeInterval(30), to: start.addingTimeInterval(30))
            .apply(to: entries).map(\.path) == ["c"])
    }

    @Test func summarySeparatesTrashedAndDeletedAndCountsDuplicates() {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            logEntry(time, command: "clean", path: "/tmp/a", bytes: 100, result: "trashed"),
            logEntry(time, command: "clean", path: "/tmp/a", bytes: 100, result: "trashed"),
            logEntry(time, command: "uninstall", path: "/tmp/b", bytes: 50, result: "deleted"),
            logEntry(time, command: "analyze", path: "/tmp/c", bytes: 999, result: "failed"),
            logEntry(time, command: "startup", path: "/tmp/d", result: "skipped"),
            logEntry(time, command: "optimize", result: "ok"),
        ]

        let summary = OperationHistorySummary(entries: entries)

        #expect(summary.trashedBytes == 200)
        #expect(summary.deletedBytes == 50)
        #expect(summary.recordCount == 6)
        #expect(summary.succeededCount == 4)
        #expect(summary.skippedCount == 1)
        #expect(summary.failedCount == 1)
    }
}

@Suite struct OperationStatsTests {
    private func entry(_ day: Int, _ source: String, _ bytes: UInt64, _ result: String = "trashed") -> OperationLog.Entry {
        var c = DateComponents(); c.year = 2026; c.month = day > 31 ? 11 : 10; c.day = day > 31 ? day - 31 : day; c.hour = 12
        return OperationLog.Entry(time: Calendar(identifier: .gregorian).date(from: c)!, command: "clean", path: "/p/\(UUID())",
                                  source: source, bytes: bytes, result: result, message: nil)
    }

    @Test func groupsBySourceAndMonth() {
        let cal = Calendar(identifier: .gregorian)
        let entries = [entry(1, "user.caches", 100), entry(1, "user.caches", 50), entry(3, "user.caches", 10),
                       entry(33, "dev.npm", 500), entry(33, "user.trash", 7, "deleted"), entry(34, "dev.npm", 9, "failed")]
        let stats = OperationSourceStats.compute(entries, calendar: cal)
        #expect(stats.map(\.source) == ["dev.npm", "user.caches", "user.trash"])
        #expect(stats[0].bytes == 500 && stats[0].items == 1, "failed removals don't count")
        #expect(stats[1].bytes == 160 && stats[1].items == 3 && stats[1].days == 2)
        let months = OperationMonthTotal.compute(entries, calendar: cal)
        #expect(months.count == 2)
        #expect(months[0].trashedBytes == 500 && months[0].deletedBytes == 7, "newest month first")
        #expect(months[1].trashedBytes == 160)
    }
}
