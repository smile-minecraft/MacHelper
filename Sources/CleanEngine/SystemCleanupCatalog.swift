import Foundation
import PrivilegedOps

/// Display text and logging for the root Helper's system cleanup targets (`PrivilegedOps.SystemCleanup`).
/// The Helper owns the folders and patterns; this side only names and records them.
public struct SystemCleanupInfo: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let folder: String
    public let risk: RiskLevel
    public let selectedByDefault: Bool
}

public enum SystemCleanupCatalog {
    public static let all: [SystemCleanupInfo] = SystemCleanup.targets.map { t in
        switch t.id {
        case "system.diagnostic-reports":
            SystemCleanupInfo(id: t.id, title: String(localized: "Old system diagnostic reports", bundle: .module),
                              description: String(localized: "Crash, hang and resource reports for all users in /Library/Logs/DiagnosticReports older than 30 days. Deleted directly as administrator.", bundle: .module),
                              folder: t.root, risk: .low, selectedByDefault: true)
        case "system.logs":
            SystemCleanupInfo(id: t.id, title: String(localized: "Old system log files", bundle: .module),
                              description: String(localized: "Log files directly in /Library/Logs older than 30 days; app subfolders are left alone. Deleted directly as administrator.", bundle: .module),
                              folder: t.root, risk: .low, selectedByDefault: true)
        default:
            SystemCleanupInfo(id: t.id, title: t.id, description: t.root, folder: t.root, risk: .low, selectedByDefault: false)
        }
    }

    /// Writes a finished (non-dry-run) cleanup to the operations log: one entry per listed file,
    /// one summary entry for files beyond the Helper's list limit, one per failure.
    public static func record(_ result: SystemCleanupResult, log: OperationLog = .shared, at date: Date = Date()) {
        var entries: [OperationLog.Entry] = []
        for target in result.targets where !target.dryRun {
            for f in target.files {
                entries.append(.init(time: date, command: "clean", path: f.path, source: target.id, bytes: f.bytes, result: "deleted", message: nil))
            }
            let unlisted = target.count - target.files.count
            if unlisted > 0 {
                let listedBytes = target.files.reduce(UInt64(0)) { $0 + $1.bytes }
                entries.append(.init(time: date, command: "clean", path: SystemCleanup.target(target.id)?.root ?? "",
                                     source: target.id, bytes: target.bytes - listedBytes, result: "deleted",
                                     message: "\(unlisted) more files"))
            }
            for f in target.failures {
                entries.append(.init(time: date, command: "clean", path: f.path, source: target.id, bytes: 0, result: "failed", message: f.message))
            }
        }
        log.append(entries)
    }
}
