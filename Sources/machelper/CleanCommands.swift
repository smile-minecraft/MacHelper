import ArgumentParser
import CleanEngine
import Diagnostics
import Foundation

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clean caches, logs, developer junk, Trash… using the declarative rules.",
        discussion: """
        Selection: rules marked as default are selected, up to --max-risk (default: medium).
        --rule / --category select exactly those instead. Use `machelper rules` to list ids.
        Examples:
          machelper clean                          # preview the default selection
          machelper clean --yes --max-risk low     # scheduled/unattended: low-risk only
          machelper clean --rule xcode.derived-data --rule dev.npm --yes --json
        """
    )

    @OptionGroup var output: OutputOptions
    @OptionGroup var apply: ApplyOptions

    @Option(name: .long, help: "Highest risk level to include: low, medium, high.")
    var maxRisk: RiskArgument = .medium

    @Option(name: .long, help: "Only this rule id (repeatable). Overrides default selection.")
    var rule: [String] = []

    @Option(name: .long, help: "Only rules in this category (repeatable).")
    var category: [String] = []

    @Flag(name: .long, help: "Delete everything permanently, including medium and high risk items.")
    var permanent = false

    @Flag(name: .long, help: "Move everything to the Trash, including low-risk items that are normally deleted directly.")
    var trash = false

    func validate() throws {
        if permanent && trash { throw ValidationError("--permanent and --trash can't be used together") }
    }

    func run() throws {
        let all = try RuleSet.load()
        let unknown = rule.filter { id in !all.contains { $0.id == id } }
        guard unknown.isEmpty else { throw ValidationError("Unknown rule id(s): \(unknown.joined(separator: ", "))") }

        let explicit = !rule.isEmpty || !category.isEmpty
        let rules = all.filter { r in
            guard r.risk <= maxRisk.level || rule.contains(r.id) else { return false }
            if explicit { return rule.contains(r.id) || category.contains(r.category) }
            return true
        }
        var plan = CleanScanner(rules: rules).scan()
        if explicit {
            for i in plan.results.indices {
                for j in plan.results[i].candidates.indices { plan.results[i].candidates[j].selected = true }
            }
        }

        let safety = PathSafety.forCleaning()
        let report = CleanExecutor(safety: safety, permanent: permanent, alwaysTrash: trash)
            .execute(plan.removalItems, dryRun: !apply.shouldApply, command: "clean")

        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let applied: Bool; let plan: CleanPlan; let report: CleanReport }
            try Output.json(Out(applied: apply.shouldApply, plan: plan, report: report))
        } else {
            printPlan(plan, report: report)
        }
        throw reportExit(report)
    }

    private func printPlan(_ plan: CleanPlan, report: CleanReport) {
        for r in plan.results where !r.candidates.isEmpty || r.skippedReason != nil {
            let mark = r.candidates.contains(where: \.selected) ? "[x]" : "[ ]"
            let note = r.skippedReason.map { "  (skipped: \($0))" } ?? ""
            let size = r.totalSize > 0 ? Output.bytes(r.totalSize) : "-"
            let held = r.candidates.filter { $0.note != nil }.count
            let heldNote = held > 0 ? "  (\(held) in use, not selected)" : ""
            Output.line("\(mark) \(Output.pad(r.rule.id, 26)) \(Output.lpad(size, 10))  \(r.rule.risk.rawValue.uppercased())  \(r.rule.title)\(note)\(heldNote)")
        }
        Output.line()
        if report.dryRun {
            let toDelete = report.items.filter { $0.result == .wouldDelete }.reduce(UInt64(0)) { $0 + $1.bytes }
            let toTrash = report.items.filter { $0.result == .wouldTrash }.reduce(UInt64(0)) { $0 + $1.bytes }
            Output.line("Preview: \(Output.bytes(plan.selectedSize)) selected of \(Output.bytes(plan.totalSize)) found (\(Output.bytes(toDelete)) deleted directly, \(Output.bytes(toTrash)) to the Trash). Nothing was removed; add --yes to clean.")
        } else {
            Output.line("Trashed \(Output.bytes(report.trashedBytes)), deleted \(Output.bytes(report.freedBytes)).")
            if report.trashedBytes > 0 { Output.line("Space from trashed items is released when the Trash is emptied.") }
            for f in report.failures { Output.err("failed: \(Output.shortPath(f.path)): \(f.message ?? "")") }
        }
    }
}

struct Purge: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove rebuildable project build artifacts (node_modules, target, .build, …).",
        discussion: """
        Scans --path roots (default: ~/Developer, ~/Projects, ~/code, … plus
        ~/Library/Application Support/MacHelper/purge-paths.txt).
        Artifacts touched in the last 7 days are listed but not selected unless --include-recent.
        Artifacts holding git-tracked files or nested repositories are never touched.
        """
    )

    @OptionGroup var output: OutputOptions
    @OptionGroup var apply: ApplyOptions

    @Option(name: .long, help: "Project root to scan (repeatable).")
    var path: [String] = []

    @Flag(name: .long, help: "Also select artifacts used within the last 7 days.")
    var includeRecent = false

    @Flag(name: .long, help: "Delete permanently instead of moving to the Trash.")
    var permanent = false

    func run() throws {
        let roots = path.isEmpty ? ArtifactScanner.defaultRoots() : path
        guard !roots.isEmpty else { throw ValidationError("No project roots found. Pass --path <dir>.") }
        var result = ArtifactScanner(detectors: try ArtifactDetector.loadBuiltIn()).scan(roots: roots)
        if includeRecent { for i in result.artifacts.indices { result.artifacts[i].selected = true } }

        let items = result.artifacts.filter(\.selected).map {
            RemovalItem(path: $0.path, source: "purge.\($0.detector)", bytes: $0.size, action: .trash)
        }
        let report = CleanExecutor(safety: PathSafety.forArtifacts(roots: result.roots), permanent: permanent)
            .execute(items, dryRun: !apply.shouldApply, command: "purge")

        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let applied: Bool; let scan: ArtifactScanResult; let report: CleanReport }
            try Output.json(Out(applied: apply.shouldApply, scan: result, report: report))
        } else {
            for a in result.artifacts {
                let mark = a.selected ? "[x]" : "[ ]"
                let recent = a.recentlyUsed ? "  (recently used)" : ""
                Output.line("\(mark) \(Output.lpad(Output.bytes(a.size), 10))  \(Output.pad(a.detector, 8)) \(Output.shortPath(a.path))\(recent)")
            }
            for s in result.skipped { Output.line("[-] skipped \(Output.shortPath(s.path)): \(s.reason)") }
            Output.line()
            if report.dryRun {
                Output.line("Preview: \(Output.bytes(result.selectedSize)) selected of \(Output.bytes(result.totalSize)) in \(result.artifacts.count) artifacts. Add --yes to remove.")
            } else {
                Output.line("Trashed \(Output.bytes(report.trashedBytes)), deleted \(Output.bytes(report.freedBytes)).")
                for f in report.failures { Output.err("failed: \(Output.shortPath(f.path)): \(f.message ?? "")") }
            }
        }
        throw reportExit(report)
    }
}

struct Optimize: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run maintenance tasks (QuickLook reset, unavailable simulators, brew cleanup, …).",
        discussion: "Tasks needing root (DNS flush, purge, periodic) are run by the MacHelper app's Helper and are listed here as unavailable."
    )

    @OptionGroup var output: OutputOptions
    @OptionGroup var apply: ApplyOptions

    @Option(name: .long, help: "Run only this task id (repeatable). Default: tasks selected by default.")
    var task: [String] = []

    func run() throws {
        let catalog = MaintenanceCatalog.all
        let unknown = task.filter { id in !catalog.contains { $0.id == id } }
        guard unknown.isEmpty else { throw ValidationError("Unknown task id(s): \(unknown.joined(separator: ", "))") }
        let chosen = catalog.filter { task.isEmpty ? $0.selectedByDefault : task.contains($0.id) }
        let runner = MaintenanceRunner()
        let outcomes = chosen.map { runner.run($0, dryRun: !apply.shouldApply) }

        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let applied: Bool; let tasks: [TaskOutcome] }
            try Output.json(Out(applied: apply.shouldApply, tasks: outcomes))
        } else {
            for (t, o) in zip(chosen, outcomes) {
                let status = o.dryRun ? (o.ok ? "would run" : "unavailable") : (o.ok ? "done" : "failed")
                Output.line("\(Output.pad(t.id, 26)) \(Output.pad(status, 12)) \(t.title)")
                if !o.ok || o.dryRun { Output.line("    \(o.output.split(separator: "\n").first ?? "")") }
            }
            if !apply.shouldApply { Output.line("\nPreview only. Add --yes to run.") }
        }
        let attempted = outcomes.filter { !$0.dryRun }
        if attempted.contains(where: { !$0.ok }) { throw ExitCode(attempted.allSatisfy { !$0.ok } ? 1 : 2) }
    }
}

struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List cleaning rules, maintenance tasks and artifact detectors.")

    @OptionGroup var output: OutputOptions

    func run() throws {
        let rules = try RuleSet.load()
        let tasks = MaintenanceCatalog.all
        let detectors = try ArtifactDetector.loadBuiltIn()
        if output.json {
            struct Task: Encodable { let id, title, description: String; let risk: RiskLevel; let requiresRoot, available, selectedByDefault: Bool }
            struct Out: Encodable { let schemaVersion = 1; let rules: [CleanRule]; let tasks: [Task]; let detectors: [ArtifactDetector] }
            try Output.json(Out(rules: rules,
                                tasks: tasks.map { Task(id: $0.id, title: $0.title, description: $0.description, risk: $0.risk,
                                                        requiresRoot: $0.requiresRoot, available: $0.isAvailable,
                                                        selectedByDefault: $0.selectedByDefault) },
                                detectors: detectors))
            return
        }
        Output.line("Cleaning rules (user rules: \(Output.shortPath(MacHelperPaths.userRulesDirectory.path))/*.json):")
        for r in rules {
            Output.line("  \(r.selectedByDefault ? "*" : " ") \(Output.pad(r.id, 26)) \(Output.pad(r.risk.rawValue, 7)) \(Output.pad(r.category, 11)) \(r.title)")
        }
        Output.line("\nMaintenance tasks:")
        for t in tasks {
            let note = !t.isAvailable ? " (not available)" : t.requiresRoot ? " (needs app Helper)" : ""
            Output.line("  \(t.selectedByDefault ? "*" : " ") \(Output.pad(t.id, 26)) \(Output.pad(t.risk.rawValue, 7)) \(t.title)\(note)")
        }
        Output.line("\nProject artifact detectors:")
        for d in detectors { Output.line("    \(Output.pad(d.id, 10)) \(d.markers.joined(separator: ", ")) → \(d.artifacts.joined(separator: ", "))") }
        Output.line("\n* = selected by default")
    }
}

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the operation log.")

    @OptionGroup var output: OutputOptions

    @Option(name: .long, help: "Number of entries.")
    var limit = 50

    @Flag(name: .long, help: "Totals per rule, detector or task over the whole log, instead of entries.")
    var byRule = false

    func run() throws {
        if byRule {
            let stats = OperationSourceStats.compute(OperationLog.shared.readAll().entries)
            if output.json {
                struct Row: Encodable { let source: String; let bytes: UInt64; let items, days: Int; let last: Date }
                struct Out: Encodable { let schemaVersion = 1; let sources: [Row] }
                try Output.json(Out(sources: stats.map { Row(source: $0.source, bytes: $0.bytes, items: $0.items, days: $0.days, last: $0.last) }))
                return
            }
            for s in stats {
                Output.line("\(Output.pad(s.source, 28)) \(Output.lpad(Output.bytes(s.bytes), 10))  \(s.items) items on \(s.days) days")
            }
            if stats.isEmpty { Output.line("Nothing removed yet.") }
            return
        }
        let entries = OperationLog.shared.read(limit: limit)
        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let entries: [OperationLog.Entry] }
            try Output.json(Out(entries: entries))
            return
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for e in entries {
            let what = e.path.isEmpty ? e.source : Output.shortPath(e.path)
            Output.line("\(f.string(from: e.time))  \(Output.pad(e.command, 9)) \(Output.pad(e.result, 8)) \(Output.lpad(e.bytes > 0 ? Output.bytes(e.bytes) : "", 9))  \(what)")
        }
        if entries.isEmpty { Output.line("No operations logged yet.") }
    }
}

struct Ignore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List or change the paths MacHelper never cleans (clean-whitelist.txt).",
        subcommands: [List.self, Add.self, Remove.self], defaultSubcommand: List.self)

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the excluded paths and globs.")
        @OptionGroup var output: OutputOptions

        func run() throws {
            let entries = CleanExclusions().entries()
            if output.json {
                struct Out: Encodable { let schemaVersion = 1; let file: String; let entries: [String] }
                try Output.json(Out(file: MacHelperPaths.whitelistFile.path, entries: entries))
                return
            }
            for e in entries { Output.line(e) }
            if entries.isEmpty { Output.line("Nothing excluded. Add paths with: machelper ignore add <path>") }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Never clean these paths or globs (~ is your home folder).")
        @Argument(help: "Paths or globs.") var paths: [String]

        func run() throws {
            let ex = CleanExclusions()
            for p in paths {
                // Existing paths are stored as absolute (~/…) paths; anything else is kept as a glob.
                let url = URL(fileURLWithPath: expandTilde(p))
                let entry = FileManager.default.fileExists(atPath: url.path) ? CleanExclusions.entry(for: url.standardizedFileURL.path) : p
                try ex.add(entry)
                Output.line("Excluded: \(entry)")
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Clean these entries again (as listed by `machelper ignore`).")
        @Argument(help: "Entries exactly as listed.") var entries: [String]

        func run() throws {
            let ex = CleanExclusions()
            for e in entries {
                guard ex.entries().contains(e) else { Output.err("Not in the list: \(e)"); throw ExitCode(1) }
                try ex.remove(e)
                Output.line("Removed: \(e)")
            }
        }
    }
}

struct Updates: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List apps installed with Homebrew that have updates, and update them.",
        subcommands: [List.self, Upgrade.self], defaultSubcommand: List.self)

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List outdated Homebrew apps (casks).")
        @OptionGroup var output: OutputOptions
        @Flag(name: .long, help: "Also list apps that update themselves.") var greedy = false
        @Flag(name: .long, help: "Run `brew update` first.") var refresh = false

        func run() throws {
            // This CLI is installed by the same cask as the app; symlinked or not it never lists an
            // update for itself, because Homebrew keeps the version the user installed.
            switch HomebrewUpdates.outdated(greedy: greedy, refresh: refresh,
                                            excludingAppBundleNames: [Bundle.main.bundleURL.lastPathComponent],
                                            excludingTokens: [HomebrewUpdates.appCaskToken]) {
            case .failure(.notInstalled):
                Output.err("Homebrew is not installed.")
                throw ExitCode(1)
            case .failure(.failed(let message)):
                Output.err("brew failed: \(message)")
                throw ExitCode(1)
            case .success(let casks):
                if output.json {
                    struct Out: Encodable { let schemaVersion = 1; let casks: [OutdatedCask] }
                    try Output.json(Out(casks: casks))
                    return
                }
                for c in casks {
                    let notes = [c.pinned ? "pinned" : nil, c.autoUpdates ? "updates itself" : nil,
                                 c.needsAdmin ? "needs a password: \(c.terminalCommand)" : nil].compactMap { $0 }
                    Output.line("\(Output.pad(c.token, 28)) \(Output.pad(c.installedVersion, 14)) → \(Output.pad(c.currentVersion, 14))\(notes.isEmpty ? "" : " (" + notes.joined(separator: ", ") + ")")")
                }
                if casks.isEmpty { Output.line("All Homebrew apps are up to date.") }
            }
        }
    }

    struct Upgrade: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update these casks (preview unless --yes).")
        @OptionGroup var apply: ApplyOptions
        @Argument(help: "Cask names as listed by `machelper updates`.") var casks: [String]

        func run() throws {
            for c in casks where !HomebrewUpdates.isValidToken(c) {
                Output.err("Not a cask name: \(c)")
                throw ExitCode(1)
            }
            guard apply.shouldApply else {
                for c in casks { Output.line("Would run: brew upgrade --cask \(c)") }
                Output.line("Nothing was changed; add --yes to update.")
                return
            }
            var failed = false
            for c in casks {
                let r = HomebrewUpdates.upgrade(c)
                Output.line(r.ok ? "Updated \(c)" : "Failed \(c)\(r.neededPassword ? " (needs a password; run brew upgrade --cask \(c) in Terminal)" : ""):\n\(r.output)")
                failed = failed || !r.ok
            }
            if failed { throw ExitCode(1) }
        }
    }
}

struct Security: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show macOS security settings (read-only).")
    @OptionGroup var output: OutputOptions

    func run() throws {
        let checks = SecurityAudit.run()
        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let checks: [SecurityCheck] }
            try Output.json(Out(checks: checks))
            return
        }
        for c in checks {
            Output.line("\(Output.pad(c.id, 12)) \(Output.pad(c.state.rawValue, 8)) \(c.detail ?? "")")
        }
    }
}
