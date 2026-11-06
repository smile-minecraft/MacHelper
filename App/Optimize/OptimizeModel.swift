import AppKit
import CleanEngine
import Foundation
import Observation
import os
import PrivilegedOps

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

    /// One root-only cleanup target, previewed by the Helper during the scan.
    struct SystemRow: Identifiable {
        let info: SystemCleanupInfo
        var preview: SystemCleanupResult.Target?
        var selected: Bool
        var id: String { info.id }
        var bytes: UInt64 { preview?.bytes ?? 0 }
        var count: Int { preview?.count ?? 0 }
    }

    struct TaskResult: Identifiable {
        let id: String
        let title: String
        let ok: Bool
        let output: String
    }

    private(set) var phase: Phase = .idle
    /// Rules checked so far during a scan, and how many there are.
    private(set) var scanProgress: (done: Int, total: Int)?
    /// The last scan was stopped early: the plan holds only the rules finished before that.
    private(set) var scanStopped = false
    @ObservationIgnored private let stopFlag = OSAllocatedUnfairLock(initialState: false)
    /// Whether MacHelper can read folders protected by Full Disk Access (checked at each scan and when the app comes back).
    private(set) var fullDiskAccess = FullDiskAccess.isGranted
    /// Paths and globs the user never wants cleaned (clean-whitelist.txt).
    private(set) var exclusions: [String] = CleanExclusions().entries()
    private(set) var exclusionError: String?
    var filter = ItemFilter()
    var plan: CleanPlan?
    var artifacts: ArtifactScanResult?
    var tasks: [TaskRow] = []
    var artifactRoots: [String] = []
    private(set) var report: CleanReport?
    private(set) var artifactReport: CleanReport?
    private(set) var taskResults: [TaskResult] = []
    private(set) var loadError: String?
    /// `docker system df`, read during the scan when a Docker CLI exists; nil otherwise.
    private(set) var dockerUsage: Result<DockerUsage, DockerUsage.Failure>?
    var systemRows: [SystemRow] = []
    /// Why system cleanup can't be previewed (Helper off, older Helper, XPC error); nil when it worked.
    private(set) var systemError: String?
    private(set) var systemReport: SystemCleanupResult?

    @ObservationIgnored nonisolated static let rootsKey = "optimize.artifactRoots"

    init() {
        artifactRoots = UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? ArtifactScanner.defaultRoots()
    }

    /// Re-reads the stored scan roots after settings are imported.
    func reload() {
        artifactRoots = UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? ArtifactScanner.defaultRoots()
    }

    // MARK: Scan

    func stopScan() { stopFlag.withLock { $0 = true } }

    func scan() async {
        phase = .scanning
        scanProgress = nil
        scanStopped = false
        stopFlag.withLock { $0 = false }
        fullDiskAccess = FullDiskAccess.isGranted
        exclusions = CleanExclusions().entries()
        loadError = nil
        report = nil
        artifactReport = nil
        systemReport = nil
        taskResults = []
        let roots = artifactRoots
        let helperEnabled = HelperClient.shared.status == .enabled
        do {
            async let docker: Result<DockerUsage, DockerUsage.Failure>? = Task.detached(priority: .userInitiated) {
                MaintenanceCatalog.docker == nil ? nil : DockerUsage.read()
            }.value
            let stop = stopFlag
            let (plan, artifacts, tasks, stopped) = try await Task.detached(priority: .userInitiated) { [weak self] in
                let rules = try RuleSet.load()
                var plan = CleanScanner(rules: rules).scan(progress: { done, total in
                    Task { @MainActor in self?.scanProgress = (done, total) }
                }, shouldStop: { stop.withLock { $0 } })
                let stopped = stop.withLock { $0 }
                if !stopped {
                    let volumes = VolumeTrash.scan()
                    if !volumes.candidates.isEmpty { plan.results.append(volumes) }
                }
                let artifacts = roots.isEmpty || stopped ? nil : ArtifactScanner(detectors: try ArtifactDetector.loadBuiltIn()).scan(roots: roots)
                let tasks = MaintenanceCatalog.all.map { t in
                    let available = t.isAvailable && (!t.requiresRoot || helperEnabled)
                    return TaskRow(task: t, selected: t.selectedByDefault && available, available: available)
                }
                return (plan, artifacts, tasks, stopped)
            }.value
            scanStopped = stopped
            guard !stopped || !plan.results.isEmpty else {
                // Stopped before any rule finished: nothing to show.
                self.plan = nil
                phase = .idle
                return
            }
            self.plan = plan
            self.artifacts = artifacts
            self.tasks = tasks
            self.dockerUsage = await docker
            if stopped {
                systemRows = SystemCleanupCatalog.all.map { SystemRow(info: $0, preview: nil, selected: false) }
                systemError = String(localized: "Scan stopped")
            } else {
                await previewSystemCleanup(helperEnabled: helperEnabled)
            }
            phase = .ready
        } catch {
            loadError = "\(error)"
            phase = .idle
        }
    }

    private func previewSystemCleanup(helperEnabled: Bool) async {
        let infos = SystemCleanupCatalog.all
        guard helperEnabled else {
            systemRows = infos.map { SystemRow(info: $0, preview: nil, selected: false) }
            systemError = String(localized: "Helper not enabled")
            return
        }
        do {
            let result = try await HelperClient.shared.systemCleanup(SystemCleanupRequest(targetIDs: infos.map(\.id), dryRun: true))
            systemRows = infos.map { info in
                let preview = result.targets.first { $0.id == info.id }
                return SystemRow(info: info, preview: preview, selected: info.selectedByDefault && (preview?.count ?? 0) > 0)
            }
            systemError = nil
        } catch {
            systemRows = infos.map { SystemRow(info: $0, preview: nil, selected: false) }
            systemError = "\(error)"
        }
    }

    var selectedSystemBytes: UInt64 { systemRows.filter(\.selected).reduce(0) { $0 + $1.bytes } }

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
        (plan?.selectedSize ?? 0) + (artifacts?.selectedSize ?? 0) + selectedSystemBytes
    }

    var selectedTaskCount: Int { tasks.filter(\.selected).count }

    /// Selected bytes that will be permanently deleted: low-risk rules, emptying the Trash and old system logs.
    var selectedPermanentBytes: UInt64 {
        (plan?.results.filter { $0.rule.action == .delete }.reduce(0) { $0 + $1.selectedSize } ?? 0) + selectedSystemBytes
    }

    /// The part of `selectedPermanentBytes` that empties the Trash.
    var selectedEmptyTrashBytes: UInt64 {
        plan?.results.filter { $0.rule.id == "user.trash" || $0.rule.id == VolumeTrash.ruleID }.reduce(0) { $0 + $1.selectedSize } ?? 0
    }

    /// Selected bytes that will be moved to the Trash (recoverable).
    var selectedTrashBytes: UInt64 { selectedBytes - selectedPermanentBytes }

    /// Rules grouped by category, in a fixed display order.
    var groups: [(category: String, title: String, results: [RuleResult])] {
        let order: [(String, String)] = [("caches", String(localized: "App Caches")), ("logs", String(localized: "Logs")), ("browsers", String(localized: "Browsers")),
                                         ("developer", String(localized: "Developer Tools")), ("ai", String(localized: "AI Tools")), ("trash", String(localized: "Trash")), ("downloads", String(localized: "Downloads")),
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

    /// Selects or deselects every item that passes the current filter.
    func setMatching(selected: Bool, in category: String?) {
        guard plan != nil else { return }
        let now = Date()
        for i in plan!.results.indices where category == nil || plan!.results[i].rule.category == category {
            let title = plan!.results[i].rule.title
            for j in plan!.results[i].candidates.indices where filter.matches(plan!.results[i].candidates[j], ruleTitle: title, now: now) {
                plan!.results[i].candidates[j].selected = selected
            }
        }
    }

    // MARK: Exclusions

    /// Never clean this path again: saved to the exclusion list and dropped from the current preview.
    func exclude(_ path: String) {
        do {
            try CleanExclusions().add(CleanExclusions.entry(for: path))
            exclusionError = nil
        } catch {
            exclusionError = "\(error.localizedDescription)"
            return
        }
        exclusions = CleanExclusions().entries()
        guard plan != nil else { return }
        for i in plan!.results.indices {
            plan!.results[i].candidates.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        }
    }

    func addExclusion(_ entry: String) {
        do { try CleanExclusions().add(entry); exclusionError = nil } catch { exclusionError = "\(error.localizedDescription)" }
        exclusions = CleanExclusions().entries()
    }

    func addExclusionsFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "Never Clean")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addExclusion(CleanExclusions.entry(for: url.path)) }
    }

    /// Removed exclusions show up again on the next scan.
    func removeExclusion(_ entry: String) {
        do { try CleanExclusions().remove(entry); exclusionError = nil } catch { exclusionError = "\(error.localizedDescription)" }
        exclusions = CleanExclusions().entries()
    }

    // MARK: Full Disk Access

    /// Called when MacHelper becomes active again; scans again once access was just turned on.
    func recheckFullDiskAccess() {
        let now = FullDiskAccess.isGranted
        defer { fullDiskAccess = now }
        if now, !fullDiskAccess, phase == .ready {
            Task { await scan() }
        }
    }

    /// Rules that found nothing and need Full Disk Access to see their folders.
    var hiddenByFullDiskAccess: Int {
        fullDiskAccess ? 0 : (plan?.results.filter { $0.rule.needsFullDiskAccess && $0.candidates.isEmpty }.count ?? 0)
    }

    // MARK: Run

    func run() async {
        guard let plan else { return }
        phase = .running
        let items = plan.removalItems.filter { $0.source != VolumeTrash.ruleID }
        let volumeItems = plan.removalItems.filter { $0.source == VolumeTrash.ruleID }
        let artifactItems = artifacts?.artifacts.filter(\.selected).map {
            RemovalItem(path: $0.path, source: "purge.\($0.detector)", bytes: $0.size, action: .trash)
        } ?? []
        let artifactRoots = artifacts?.roots ?? []
        let userTasks = tasks.filter { $0.selected && !$0.task.requiresRoot }.map(\.task)
        let rootTasks = tasks.filter { $0.selected && $0.task.requiresRoot }.map(\.task)
        let systemIDs = systemRows.filter { $0.selected && $0.count > 0 }.map(\.id)

        let (report, artifactReport, userResults) = await Task.detached(priority: .userInitiated) {
            var report = CleanExecutor(safety: .forCleaning()).execute(items, dryRun: false, command: "clean")
            if !volumeItems.isEmpty {
                // Other drives' Trash: only items inside <volume>/.Trashes/<uid>, re-checked right before removal.
                let v = CleanExecutor(safety: VolumeTrash.safety(trashFolders: VolumeTrash.trashFolders()))
                    .execute(volumeItems, dryRun: false, command: "clean")
                report = CleanReport(schemaVersion: 1, dryRun: false, items: report.items + v.items)
            }
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
        var systemReport: SystemCleanupResult?
        if !systemIDs.isEmpty {
            do {
                // The Helper scans again with the same fixed rules; only what is still old enough goes.
                let r = try await HelperClient.shared.systemCleanup(SystemCleanupRequest(targetIDs: systemIDs, dryRun: false))
                SystemCleanupCatalog.record(r)
                systemReport = r
                if let f = r.targets.flatMap(\.failures).first {
                    results.append(TaskResult(id: "system", title: String(localized: "System logs"), ok: false, output: "\(f.path): \(f.message)"))
                }
            } catch {
                results.append(TaskResult(id: "system", title: String(localized: "System logs"), ok: false, output: "\(error)"))
            }
        }
        self.report = report
        self.artifactReport = artifactReport
        self.systemReport = systemReport
        self.taskResults = results
        phase = .finished
    }

    var trashedBytes: UInt64 { (report?.trashedBytes ?? 0) + (artifactReport?.trashedBytes ?? 0) }
    var freedBytes: UInt64 { (report?.freedBytes ?? 0) + (artifactReport?.freedBytes ?? 0) + (systemReport?.bytes ?? 0) }
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

    func openFullDiskAccessSettings() { FullDiskAccess.openSettings() }
}
