import AppKit
import CleanEngine
import Foundation
import Observation

/// Scan → preview → choose → run → report. Nothing is removed before `run()`.
@MainActor
@Observable
final class OptimizeModel {
    enum Phase: Equatable { case idle, scanning, ready, running, finished }

    struct TaskRow: Identifiable {
        let task: MaintenanceTask
        var selected: Bool
        let available: Bool
        var id: String { task.id }
    }

    struct TaskResult: Identifiable {
        let id: String
        let title: String
        let ok: Bool
        let output: String
    }

    private(set) var phase: Phase = .idle
    var plan: CleanPlan?
    var artifacts: ArtifactScanResult?
    var tasks: [TaskRow] = []
    var artifactRoots: [String] = []
    private(set) var report: CleanReport?
    private(set) var artifactReport: CleanReport?
    private(set) var taskResults: [TaskResult] = []
    private(set) var loadError: String?

    @ObservationIgnored nonisolated static let rootsKey = "optimize.artifactRoots"

    init() {
        artifactRoots = UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? ArtifactScanner.defaultRoots()
    }

    /// Re-reads the stored scan roots after settings are imported.
    func reload() {
        artifactRoots = UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? ArtifactScanner.defaultRoots()
    }

    // MARK: Scan

    func scan() async {
        phase = .scanning
        loadError = nil
        report = nil
        artifactReport = nil
        taskResults = []
        let roots = artifactRoots
        let helperEnabled = HelperClient.shared.status == .enabled
        do {
            let (plan, artifacts, tasks) = try await Task.detached(priority: .userInitiated) {
                let rules = try RuleSet.load()
                let plan = CleanScanner(rules: rules).scan()
                let artifacts = roots.isEmpty ? nil : ArtifactScanner(detectors: try ArtifactDetector.loadBuiltIn()).scan(roots: roots)
                let tasks = MaintenanceCatalog.all.map { t in
                    let available = t.isAvailable && (!t.requiresRoot || helperEnabled)
                    return TaskRow(task: t, selected: t.selectedByDefault && available, available: available)
                }
                return (plan, artifacts, tasks)
            }.value
            self.plan = plan
            self.artifacts = artifacts
            self.tasks = tasks
            phase = .ready
        } catch {
            loadError = "\(error)"
            phase = .idle
        }
    }

    // MARK: Selection

    func isRuleSelected(_ id: String) -> Bool? {
        guard let r = plan?.results.first(where: { $0.rule.id == id }), !r.candidates.isEmpty else { return nil }
        let n = r.candidates.filter(\.selected).count
        return n == 0 ? false : (n == r.candidates.count ? true : nil)
    }

    func setRule(_ id: String, selected: Bool) {
        guard let i = plan?.results.firstIndex(where: { $0.rule.id == id }) else { return }
        for j in plan!.results[i].candidates.indices { plan!.results[i].candidates[j].selected = selected }
    }

    func toggleCandidate(rule id: String, path: String) {
        guard let i = plan?.results.firstIndex(where: { $0.rule.id == id }),
              let j = plan?.results[i].candidates.firstIndex(where: { $0.path == path }) else { return }
        plan!.results[i].candidates[j].selected.toggle()
    }

    func toggleArtifact(_ path: String) {
        guard let i = artifacts?.artifacts.firstIndex(where: { $0.path == path }) else { return }
        artifacts!.artifacts[i].selected.toggle()
    }

    func addArtifactRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        artifactRoots = Array(Set(artifactRoots + panel.urls.map(\.path))).sorted()
        UserDefaults.standard.set(artifactRoots, forKey: Self.rootsKey)
    }

    func removeArtifactRoot(_ root: String) {
        artifactRoots.removeAll { $0 == root }
        UserDefaults.standard.set(artifactRoots, forKey: Self.rootsKey)
    }

    var selectedBytes: UInt64 {
        (plan?.selectedSize ?? 0) + (artifacts?.selectedSize ?? 0)
    }

    var selectedTaskCount: Int { tasks.filter(\.selected).count }

    /// Selected bytes that will be permanently deleted (only the "empty the Trash" rule does that).
    var selectedPermanentBytes: UInt64 {
        plan?.results.filter { $0.rule.action == .delete }.reduce(0) { $0 + $1.selectedSize } ?? 0
    }

    /// Selected bytes that will be moved to the Trash (recoverable).
    var selectedTrashBytes: UInt64 { selectedBytes - selectedPermanentBytes }

    /// Rules grouped by category, in a fixed display order.
    var groups: [(category: String, title: String, results: [RuleResult])] {
        let order: [(String, String)] = [("caches", String(localized: "App Caches")), ("logs", String(localized: "Logs")), ("browsers", String(localized: "Browsers")),
                                         ("developer", String(localized: "Developer Tools")), ("trash", String(localized: "Trash")), ("downloads", String(localized: "Downloads")),
                                         ("mail", String(localized: "Mail")), ("backups", String(localized: "Device Backups"))]
        guard let plan else { return [] }
        var out: [(String, String, [RuleResult])] = []
        for (cat, title) in order {
            let rs = plan.results.filter { $0.rule.category == cat }
            if !rs.isEmpty { out.append((cat, title, rs)) }
        }
        let known = Set(order.map(\.0))
        let rest = plan.results.filter { !known.contains($0.rule.category) }
        if !rest.isEmpty { out.append(("other", String(localized: "Other Rules"), rest)) }
        return out
    }

    // MARK: Run

    func run() async {
        guard let plan else { return }
        phase = .running
        let items = plan.removalItems
        let artifactItems = artifacts?.artifacts.filter(\.selected).map {
            RemovalItem(path: $0.path, source: "purge.\($0.detector)", bytes: $0.size, action: .trash)
        } ?? []
        let artifactRoots = artifacts?.roots ?? []
        let userTasks = tasks.filter { $0.selected && !$0.task.requiresRoot }.map(\.task)
        let rootTasks = tasks.filter { $0.selected && $0.task.requiresRoot }.map(\.task)

        let (report, artifactReport, userResults) = await Task.detached(priority: .userInitiated) {
            let report = CleanExecutor(safety: .forCleaning()).execute(items, dryRun: false, command: "clean")
            let artifactReport = artifactItems.isEmpty ? nil
                : CleanExecutor(safety: .forArtifacts(roots: artifactRoots)).execute(artifactItems, dryRun: false, command: "purge")
            let runner = MaintenanceRunner()
            let results = userTasks.map { t -> TaskResult in
                let o = runner.run(t, dryRun: false)
                return TaskResult(id: t.id, title: t.title, ok: o.ok, output: o.output)
            }
            return (report, artifactReport, results)
        }.value

        var results = userResults
        for t in rootTasks {
            do {
                let out = try await HelperClient.shared.runMaintenance(t.id)
                results.append(TaskResult(id: t.id, title: t.title, ok: true, output: out))
                OperationLog.shared.append([.init(time: Date(), command: "optimize", path: "", source: t.id, bytes: 0, result: "ok", message: nil)])
            } catch {
                results.append(TaskResult(id: t.id, title: t.title, ok: false, output: "\(error)"))
            }
        }
        self.report = report
        self.artifactReport = artifactReport
        self.taskResults = results
        phase = .finished
    }

    var trashedBytes: UInt64 { (report?.trashedBytes ?? 0) + (artifactReport?.trashedBytes ?? 0) }
    var freedBytes: UInt64 { (report?.freedBytes ?? 0) + (artifactReport?.freedBytes ?? 0) }
    var failures: [ItemOutcome] { (report?.failures ?? []) + (artifactReport?.failures ?? []) }

    /// Empties the Trash through the same rule (permanent; it is what the user asked for).
    func emptyTrash() async {
        guard let rule = try? RuleSet.load().first(where: { $0.id == "user.trash" }) else { return }
        let r = await Task.detached {
            let plan = CleanScanner(rules: [rule]).scan()
            return CleanExecutor(safety: .forCleaning()).execute(plan.removalItems, dryRun: false, command: "clean")
        }.value
        let freed = r.freedBytes
        taskResults.append(TaskResult(id: "trash", title: String(localized: "Empty Trash"), ok: r.failures.isEmpty,
                                      output: String(localized: "Freed \(Fmt.bytes(Int64(clamping: freed)))")))
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
