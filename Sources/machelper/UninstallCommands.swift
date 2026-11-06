import ArgumentParser
import CleanEngine
import Foundation

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Uninstall an app together with its leftovers in ~/Library.",
        discussion: """
        Leftovers are matched by bundle identifier. Caches, logs, preferences and launch agents are selected;
        Application Support / Containers / Group Containers may hold your documents and are kept unless --with-data.
        Leftovers in /Library (system level) are listed for manual removal.
        Examples:
          machelper uninstall --list --json
          machelper uninstall "Some App"                 # preview
          machelper uninstall com.example.App --yes
          machelper uninstall --orphans                  # leftovers of apps already removed (preview)
        """
    )

    @OptionGroup var output: OutputOptions
    @OptionGroup var apply: ApplyOptions

    @Argument(help: "App name, bundle identifier or path.")
    var app: String?

    @Flag(name: .long, help: "List installed apps.")
    var list = false

    @Flag(name: .long, help: "Also remove app data (Application Support, Containers, Group Containers).")
    var withData = false

    @Flag(name: .long, help: "Find leftovers of apps that are no longer installed.")
    var orphans = false

    @Option(name: .long, help: "With --orphans --yes: remove only these paths (repeatable). Orphans are never removed in bulk.")
    var path: [String] = []

    @Flag(name: .long, help: "Delete permanently instead of moving to the Trash.")
    var permanent = false

    func run() throws {
        if list { return try listApps() }
        if orphans { return try runOrphans() }
        guard let app else { throw ValidationError("Give an app name, bundle id or path (or --list / --orphans).") }

        let apps = AppUninstaller.installedApps()
        let target = try AppUninstaller.find(app, in: apps)
        let plan = AppUninstaller.plan(for: target, includeUserData: withData, otherApps: apps)
        let report = try AppUninstaller.execute(plan, dryRun: !apply.shouldApply, permanent: permanent)

        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let applied: Bool; let plan: UninstallPlan; let report: CleanReport }
            try Output.json(Out(applied: apply.shouldApply, plan: plan, report: report))
        } else {
            Output.line("\(target.name) \(target.version ?? "")  (\(target.bundleID))")
            if let reason = target.protectedReason { Output.line("Cannot uninstall: \(reason)") }
            if target.isRunning { Output.line("\(target.name) is running: quit it before uninstalling.") }
            for i in plan.items {
                let mark = i.selected ? "[x]" : "[ ]"
                let note = i.needsConfirmation ? "  (by \(i.evidence.rawValue), check it)" : "  (\(i.evidence.rawValue)\(i.followsUserData && !i.kind.mayContainUserData ? ", with app data" : ""))"
                Output.line("\(mark) \(Output.lpad(Output.bytes(i.size), 10))  \(Output.pad(i.kind.rawValue, 14)) \(Output.shortPath(i.path))\(note)")
            }
            for k in plan.kept { Output.line("[-] kept: \(Output.shortPath(k.path)): \(k.reason)") }
            for s in plan.systemItems { Output.line("[!] needs admin, remove manually: \(s)") }
            Output.line()
            if report.dryRun {
                Output.line("Preview: \(Output.bytes(plan.selectedSize)) selected. Add --yes to uninstall\(withData ? "" : " (add --with-data to include app data)").")
            } else {
                Output.line("Moved \(Output.bytes(report.trashedBytes)) to the Trash, deleted \(Output.bytes(report.freedBytes)).")
                for f in report.failures { Output.err("failed: \(Output.shortPath(f.path)): \(f.message ?? "")") }
            }
        }
        throw reportExit(report)
    }

    private func listApps() throws {
        let apps = AppUninstaller.installedApps()
        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let apps: [InstalledApp] }
            return try Output.json(Out(apps: apps))
        }
        for a in apps {
            let flags = [a.isRunning ? "running" : nil, a.isAppStore ? "App Store" : nil, a.protectedReason.map { _ in "protected" }]
                .compactMap { $0 }.joined(separator: ", ")
            Output.line("\(Output.lpad(Output.bytes(a.size), 10))  \(Output.pad(a.name, 30)) \(Output.pad(a.bundleID, 40)) \(flags)")
        }
    }

    private func runOrphans() throws {
        let found = AppUninstaller.orphans()
        // Orphans are heuristic: removal only for paths the caller names explicitly.
        let chosen = found.filter { path.map(expandTilde).contains($0.path) }
        let items = chosen.map { RemovalItem(path: $0.path, source: "orphan", bytes: $0.size, action: .trash) }
        let report = CleanExecutor(safety: AppUninstaller.leftoverSafety, permanent: permanent)
            .execute(items, dryRun: !apply.shouldApply, command: "uninstall")
        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let applied: Bool; let orphans: [UninstallItem]; let report: CleanReport }
            try Output.json(Out(applied: apply.shouldApply, orphans: found, report: report))
        } else {
            for o in found {
                Output.line("\(chosen.contains(o) ? "[x]" : "[ ]") \(Output.lpad(Output.bytes(o.size), 10))  \(Output.pad(o.kind.rawValue, 12)) \(Output.shortPath(o.path))")
            }
            Output.line("\n\(found.count) possible leftovers (\(Output.bytes(found.reduce(0) { $0 + $1.size }))). These are guesses: review them, then pass --path <item> --yes for the ones to remove.")
        }
        throw reportExit(report)
    }
}

struct AutoCleanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autoclean",
        abstract: "Scheduled low-risk cleaning (what the MacHelper background agent runs).",
        discussion: """
        Settings live in ~/Library/Application Support/MacHelper/autoclean.json and are edited in the app.
        Only low-risk rules selected by default run; caches of running apps are skipped; the Trash is never emptied.
        Then the enabled safe maintenance tasks run (QuickLook cache reset, deleting unavailable simulators);
        tasks that don't apply on this Mac are skipped.
          machelper autoclean --status          # show settings and last result
          machelper autoclean --run-if-due      # what the hourly agent calls
          machelper autoclean --now             # run immediately
        """
    )

    @OptionGroup var output: OutputOptions

    @Flag(name: .long, help: "Run only if enabled and the interval has passed.")
    var runIfDue = false

    @Flag(name: .long, help: "Run now, regardless of schedule (still low-risk only).")
    var now = false

    @Flag(name: .long, help: "Show settings and the last result.")
    var status = false

    func run() throws {
        var config = AutoClean.load()
        let shouldRun = now || (runIfDue && config.isDue())
        guard shouldRun else {
            if output.json {
                struct Out: Encodable { let schemaVersion = 1; let ran = false; let config: AutoCleanConfig; let due: Bool }
                try Output.json(Out(config: config, due: config.isDue()))
            } else if status || !runIfDue {
                Output.line("Auto clean: \(config.enabled ? "on, \(config.frequency.rawValue)" : "off")\(config.trashInstead == true ? ", to Trash" : config.permanent ? ", permanent" : ", low-risk items deleted directly")")
                if let last = config.lastRun {
                    Output.line("Last run: \(last.formatted()) — \(config.lastItemCount) items, trashed \(Output.bytes(config.lastTrashedBytes)), deleted \(Output.bytes(config.lastFreedBytes))")
                } else {
                    Output.line("Never run.")
                }
                Output.line("Maintenance: \(config.enabledMaintenanceTasks.isEmpty ? "none" : config.enabledMaintenanceTasks.joined(separator: ", "))")
                for t in config.lastTasks ?? [] { Output.line("  last \(t.id): \(t.ok ? "ok" : "failed")") }
                if let e = config.lastError { Output.line("Last error: \(e)") }
                if let next = config.nextRun { Output.line("Next run: \(next.formatted())") }
            }
            return
        }
        let (_, report, tasks) = AutoClean.run(config: config, rules: try RuleSet.load())
        AutoClean.record(report, tasks: tasks, into: &config)
        try AutoClean.save(config)
        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let ran = true; let config: AutoCleanConfig; let report: CleanReport; let tasks: [TaskOutcome] }
            try Output.json(Out(config: config, report: report, tasks: tasks))
        } else {
            Output.line("Auto clean: \(config.lastItemCount) items, trashed \(Output.bytes(report.trashedBytes)), deleted \(Output.bytes(report.freedBytes)).")
            for t in tasks { Output.line("  \(t.id): \(t.ok ? "ok" : "failed — \(t.output.suffix(200))")") }
        }
        throw reportExit(report)
    }
}
