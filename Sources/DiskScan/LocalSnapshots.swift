import Foundation

/// Local APFS snapshots of one volume, read through `tmutil listlocalsnapshots`.
/// Read-only: nothing here can create or delete a snapshot.
///
/// A snapshot's own blocks are shared with the live volume (APFS copy-on-write), so the amount
/// one snapshot keeps cannot be measured from outside, and adding up snapshots proves nothing.
/// This type therefore never reports bytes. It reports how many snapshots there are, when they
/// were taken, or that the question could not be answered.
public enum LocalSnapshots: Sendable, Equatable {
    /// The query succeeded and the volume has no local snapshots.
    case none
    /// The query succeeded. `total` counts every snapshot line; `dates` only the ones whose
    /// names carry a date, newest first.
    case list(dates: [Date], total: Int)
    /// The query could not be answered; `reason` is the technical detail, never shown as "none".
    case unavailable(reason: String)

    public var total: Int {
        switch self {
        case .none: 0
        case .list(_, let total): total
        case .unavailable: 0
        }
    }

    public var dates: [Date] {
        if case .list(let dates, _) = self { return dates }
        return []
    }

    /// Asks the system about the volume. This is the only entry point; the query is read-only.
    public static func query(for volume: URL) -> LocalSnapshots {
        let tmutil = "/usr/bin/tmutil"
        guard FileManager.default.isExecutableFile(atPath: tmutil) else {
            return .unavailable(reason: "tmutil was not found at \(tmutil)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmutil)
        process.arguments = ["listlocalsnapshots", volume.path]
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        do {
            try process.run()
        } catch {
            return .unavailable(reason: "tmutil could not be started: \(error.localizedDescription)")
        }
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: stdout, as: UTF8.self),
                     exitCode: process.terminationStatus,
                     error: String(decoding: stderr, as: UTF8.self),
                     timeZone: .current)
    }

    static func parse(_ output: String, exitCode: Int32, error: String = "",
                      timeZone: TimeZone = .current) -> LocalSnapshots {
        guard exitCode == 0 else {
            let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty ? "tmutil exited with code \(exitCode)"
                : "tmutil exited with code \(exitCode): \(detail)"
            return .unavailable(reason: reason)
        }
        let snapshotLines = output.split(whereSeparator: \.isNewline).map { String($0) }
            .filter { $0.contains("com.apple") }
        guard !snapshotLines.isEmpty else { return .none }
        let dates = Set(snapshotLines.compactMap { snapshotDate(in: $0, timeZone: timeZone) })
        return .list(dates: dates.sorted(by: >), total: snapshotLines.count)
    }

    static func snapshotDate(in line: String, timeZone: TimeZone) -> Date? {
        guard let range = line.range(of: timestampPattern, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = timeZone
        return formatter.date(from: String(line[range]))
    }

    /// `com.apple.TimeMachine.2026-11-17-090000.local` → the timestamp part.
    static let timestampPattern = #"\d{4}-\d{2}-\d{2}-\d{6}"#
}
