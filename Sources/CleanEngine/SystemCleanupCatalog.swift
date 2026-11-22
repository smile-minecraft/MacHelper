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
    /// Part of deep clean: deleting it asks for an administrator password.
    public var deep: Bool = false
}

public enum SystemCleanupCatalog {
    /// Standard targets (no password) followed by the deep ones.
    public static let all: [SystemCleanupInfo] = standard + deep

    public static let standard: [SystemCleanupInfo] = SystemCleanup.targets.map { t in
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

    public static let deep: [SystemCleanupInfo] = SystemCleanup.deepTargets.map { t in
        // Like every other cleanup item, only low-risk targets start selected.
        func info(_ title: String, _ description: String, risk: RiskLevel = .low) -> SystemCleanupInfo {
            SystemCleanupInfo(id: t.id, title: title, description: description, folder: t.root, risk: risk, selectedByDefault: risk == .low, deep: true)
        }
        return switch t.id {
        case "deep.system-caches":
            info(String(localized: "System caches", bundle: .module),
                 String(localized: "Third-party caches shared by all users in /Library/Caches, untouched for 7 days. Apple’s own caches are left alone; apps rebuild theirs when needed.", bundle: .module),
                 risk: .medium)
        case "deep.root-caches":
            info(String(localized: "Caches of system services", bundle: .module),
                 String(localized: "Caches of processes that run as the system administrator (root), untouched for 7 days.", bundle: .module))
        case "deep.var-log":
            info(String(localized: "Rotated system logs", bundle: .module),
                 String(localized: "Older, already rotated or compressed logs in /private/var/log (system.log.3.gz and the like). The current logs stay.", bundle: .module))
        case "deep.diagnostic-reports":
            info(String(localized: "All system diagnostic reports", bundle: .module),
                 String(localized: "Every crash, hang and resource report in /Library/Logs/DiagnosticReports older than a day, not only the ones past 30 days.", bundle: .module))
        case "deep.library-logs":
            info(String(localized: "App logs in /Library/Logs", bundle: .module),
                 String(localized: "Log files in the app folders of /Library/Logs, untouched for 7 days.", bundle: .module))
        case "deep.temp":
            info(String(localized: "System temporary files", bundle: .module),
                 String(localized: "Files in /private/var/tmp that haven’t changed for 7 days.", bundle: .module), risk: .medium)
        case "deep.tmp":
            info(String(localized: "Shared temporary files", bundle: .module),
                 String(localized: "Files in /tmp that haven’t changed for 7 days. An app that keeps a file open without writing to it can still need it, so leave this off if you aren’t sure.", bundle: .module), risk: .medium)
        case "deep.simulator-caches":
            info(String(localized: "Simulator system caches", bundle: .module),
                 String(localized: "Shared caches of the iOS simulators in /Library/Developer/CoreSimulator/Caches. Rebuilt the next time a simulator starts, which then takes longer.", bundle: .module))
        default:
            info(t.id, t.root, risk: .medium)
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
