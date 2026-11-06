import Foundation
import Testing
@testable import CleanEngine

@Suite struct AutoCleanMaintenanceTests {
    private func task(_ id: String, risk: RiskLevel = .low, root: Bool = false) -> MaintenanceTask {
        MaintenanceTask(id: id, title: id, description: "", risk: risk, selectedByDefault: true,
                        runner: root ? .helper : .user([["/usr/bin/true"]]), requires: [])
    }

    @Test func allowlistIsTheTwoSafeTasks() {
        #expect(AutoClean.maintenanceTaskIDs == ["quicklook.reset", "simulators.unavailable"])
        for id in AutoClean.maintenanceTaskIDs {
            let t = MaintenanceCatalog.all.first { $0.id == id }
            #expect(t != nil, "\(id) exists in the catalog")
            #expect(t?.risk == .low)
            #expect(t?.requiresRoot == false)
        }
    }

    @Test func nilMeansAllAndOrderFollowsAllowlist() {
        var c = AutoCleanConfig()
        #expect(c.enabledMaintenanceTasks == AutoClean.maintenanceTaskIDs)
        c.maintenanceTasks = ["simulators.unavailable", "quicklook.reset"]
        #expect(c.enabledMaintenanceTasks == ["quicklook.reset", "simulators.unavailable"])
        c.maintenanceTasks = []
        #expect(c.enabledMaintenanceTasks.isEmpty)
    }

    @Test func configCannotWidenWhatRunsUnattended() {
        var c = AutoCleanConfig()
        c.maintenanceTasks = ["quicklook.reset", "launchservices.rebuild", "memory.purge", "docker.images.unused", "rm -rf"]
        #expect(c.enabledMaintenanceTasks == ["quicklook.reset"])
        #expect(AutoClean.maintenanceTasks(for: c).map(\.id) == ["quicklook.reset"])
    }

    @Test func catalogChangesAreRecheckedForRiskAndRoot() {
        let c = AutoCleanConfig()
        let catalog = [task("quicklook.reset", risk: .medium), task("simulators.unavailable", root: true)]
        #expect(AutoClean.maintenanceTasks(for: c, catalog: catalog).isEmpty)
    }

    @Test func runsEnabledAvailableTasksAndSkipsUnavailableOnes() {
        var c = AutoCleanConfig()
        let catalog = [task("quicklook.reset"), task("simulators.unavailable")]
        var ran: [String] = []
        let outcomes = AutoClean.runMaintenance(config: c, catalog: catalog, isAvailable: { $0.id != "simulators.unavailable" }) { t in
            ran.append(t.id)
            return TaskOutcome(id: t.id, ok: true, dryRun: false, output: "")
        }
        #expect(ran == ["quicklook.reset"])
        #expect(outcomes.map(\.id) == ["quicklook.reset"])

        c.maintenanceTasks = []
        ran = []
        #expect(AutoClean.runMaintenance(config: c, catalog: catalog, isAvailable: { _ in true }) { t in
            ran.append(t.id); return TaskOutcome(id: t.id, ok: true, dryRun: false, output: "")
        }.isEmpty)
        #expect(ran.isEmpty)
    }

    @Test func recordKeepsTaskOutcomesAndReportsFailures() {
        var c = AutoCleanConfig()
        let report = CleanReport(schemaVersion: 1, dryRun: false, items: [])
        AutoClean.record(report, tasks: [TaskOutcome(id: "quicklook.reset", ok: true, dryRun: false, output: "")], into: &c)
        #expect(c.lastTasks?.map(\.id) == ["quicklook.reset"])
        #expect(c.lastError == nil)

        AutoClean.record(report, tasks: [TaskOutcome(id: "simulators.unavailable", ok: false, dryRun: false, output: "boom")], into: &c)
        #expect(c.lastError?.contains("simulators.unavailable") == true)
    }

    @Test func olderConfigFilesStillDecode() throws {
        let old = #"{"enabled":true,"frequency":"daily","permanent":false,"lastTrashedBytes":0,"lastFreedBytes":0,"lastItemCount":0}"#
        let dir = FileManager.default.temporaryDirectory.appending(path: "autoclean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "autoclean.json")
        try Data(old.utf8).write(to: url)
        let c = AutoClean.load(from: url)
        #expect(c.enabled && c.frequency == .daily)
        #expect(c.maintenanceTasks == nil && c.lastTasks == nil)
        #expect(c.enabledMaintenanceTasks == AutoClean.maintenanceTaskIDs)

        var edited = c
        edited.maintenanceTasks = ["simulators.unavailable"]
        try AutoClean.save(edited, to: url)
        #expect(AutoClean.load(from: url).enabledMaintenanceTasks == ["simulators.unavailable"])
    }

    @Test func simulatorProbeChecksDeveloperToolsBeforeXcrun() {
        let t = MaintenanceCatalog.all.first { $0.id == "simulators.unavailable" }
        let probe = t?.probe?.joined(separator: " ") ?? ""
        let select = probe.range(of: "xcode-select -p")
        let xcrun = probe.range(of: "xcrun --find simctl")
        #expect(select != nil && xcrun != nil)
        if let select, let xcrun { #expect(select.lowerBound < xcrun.lowerBound) }
        #expect(probe.contains("&&"), "xcrun runs only when developer tools are selected")
    }
}
