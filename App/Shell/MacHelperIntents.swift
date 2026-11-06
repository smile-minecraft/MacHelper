import AppIntents
import CleanEngine
import Diagnostics
import Foundation
import Storage

// Shortcuts actions. They use the same engine as the app and the CLI and never run in the
// background on their own: each one runs only when a shortcut calls it.

struct CheckHealthIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Mac Health"
    static let description = IntentDescription("Runs MacHelper’s health check on the recorded history and returns the findings as text.")

    @Parameter(title: "Hours of history", default: 24, inclusiveRange: (1, 720))
    var hours: Int

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let history = try MetricsHistory(readOnly: true)
        let report = try HealthCheck.run(history: history, hours: Double(hours), system: .current())
        let text = report.findings.isEmpty
            ? String(localized: "No problems found in the last \(hours) hours.")
            : report.findings.map { "• \($0.title): \($0.detail)" }.joined(separator: "\n")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct FreeSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Free Space Trend"
    static let description = IntentDescription("Returns free space on the startup disk and, when there’s enough hourly history, how fast it’s shrinking.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let now = DiskSpaceReader.current() else { throw IntentError.message(String(localized: "The startup disk’s free space couldn’t be read.")) }
        let free = ByteCountFormatter.string(fromByteCount: Int64(now.free), countStyle: .file)
        var text = String(localized: "\(free) free.")
        let points = (try? MetricsHistory(readOnly: true).diskSpace(since: Date().addingTimeInterval(-14 * 86_400))) ?? []
        if let f = DiskSpaceForecast.compute(points), let days = f.daysUntilFull {
            let perDay = ByteCountFormatter.string(fromByteCount: Int64(-f.bytesPerDay), countStyle: .file)
            text += " " + String(localized: "Shrinking by about \(perDay) a day; full in about \(Int(days.rounded())) days at this rate.")
        }
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct PreviewCleanupIntent: AppIntent {
    static let title: LocalizedStringResource = "Preview Low-Risk Cleanup"
    static let description = IntentDescription("Measures how much a low-risk cleanup would free, without removing anything.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let plan = try LowRiskCleanup.plan()
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: plan.selectedSize), countStyle: .file)
        return .result(value: Int(clamping: plan.selectedSize),
                       dialog: IntentDialog(stringLiteral: String(localized: "A low-risk cleanup would free \(size).")))
    }
}

struct RunCleanupIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Low-Risk Cleanup"
    static let description = IntentDescription("Deletes low-risk, selected-by-default caches and logs (the same selection as scheduled cleaning); apps rebuild this data themselves. Apps that are running are skipped. Asks before it starts.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let plan = try LowRiskCleanup.plan()
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: plan.selectedSize), countStyle: .file)
        guard plan.selectedSize > 0 else {
            return .result(value: 0, dialog: IntentDialog(stringLiteral: String(localized: "Nothing to clean right now.")))
        }
        let question = IntentDialog(stringLiteral: String(localized: "Delete \(size) of low-risk caches and logs?"))
        if #available(macOS 15.0, *) {
            try await requestConfirmation(actionName: .go, dialog: question)
        } else {
            try await requestConfirmation(result: .result(dialog: question), confirmationActionName: .go)
        }
        let report = CleanExecutor(safety: .forCleaning()).execute(plan.removalItems, dryRun: false, command: "clean")
        let total = report.freedBytes + report.trashedBytes
        let freed = ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file)
        var text = String(localized: "Cleaned \(freed).")
        if !report.failures.isEmpty { text += " " + String(localized: "\(report.failures.count) items could not be moved.") }
        return .result(value: Int(clamping: total), dialog: IntentDialog(stringLiteral: text))
    }
}

/// The scheduled-cleaning selection: low-risk rules that are selected by default, following each
/// rule's action (low-risk items are deleted directly). Never empties the Trash.
enum LowRiskCleanup {
    static func plan() throws -> CleanPlan {
        let rules = try RuleSet.load().filter { $0.risk <= AutoClean.maxRisk && $0.selectedByDefault && $0.id != "user.trash" }
        return CleanScanner(rules: rules).scan()
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)
    var localizedStringResource: LocalizedStringResource {
        switch self { case .message(let m): "\(m)" }
    }
}

struct MacHelperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CheckHealthIntent(), phrases: ["Check my Mac with \(.applicationName)", "\(.applicationName) health check"],
                    shortTitle: "Check Mac Health", systemImageName: "heart.text.square")
        AppShortcut(intent: FreeSpaceIntent(), phrases: ["How much space is free in \(.applicationName)"],
                    shortTitle: "Free Space Trend", systemImageName: "internaldrive")
        AppShortcut(intent: PreviewCleanupIntent(), phrases: ["Preview cleanup in \(.applicationName)"],
                    shortTitle: "Preview Cleanup", systemImageName: "sparkles")
        AppShortcut(intent: RunCleanupIntent(), phrases: ["Clean up with \(.applicationName)"],
                    shortTitle: "Run Cleanup", systemImageName: "trash")
    }
}
