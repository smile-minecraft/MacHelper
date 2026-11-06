import Foundation

/// The agent skill that teaches Claude Code, Codex and similar agents to use the `machelper` CLI, and
/// its installation into each agent's global skills folder. MacHelper only ever writes, updates or
/// removes a SKILL.md that carries its own marker; a file the user wrote is never touched.
public enum AgentSkill {
    public static let name = "machelper"
    /// Bump when the text changes: installed copies are refreshed when the app starts.
    public static let version = 2
    static let marker = "<!-- managed by MacHelper: skill version"

    public struct Target: Sendable, Identifiable, Hashable {
        public let id: String
        public let title: String
        /// The agent's home folder (~/.claude); the skill goes into `<home>/skills/machelper/SKILL.md`.
        public let home: URL
        public var file: URL { home.appending(path: "skills/\(AgentSkill.name)/SKILL.md") }
        /// The agent seems to be in use on this Mac (its folder exists).
        public var detected: Bool { FileManager.default.fileExists(atPath: home.path) }
    }

    public enum State: Equatable, Sendable { case notInstalled, installed, outdated, foreign }

    public static func targets(home: URL = MacHelperPaths.home) -> [Target] {
        [Target(id: "claude", title: "Claude Code", home: home.appending(path: ".claude")),
         Target(id: "codex", title: "Codex", home: home.appending(path: ".codex"))]
    }

    public static func state(_ t: Target) -> State {
        guard let text = try? String(contentsOf: t.file, encoding: .utf8) else { return .notInstalled }
        guard let r = text.range(of: marker) else { return .foreign }
        let rest = text[r.upperBound...].prefix(while: { $0 == " " || $0.isNumber }).trimmingCharacters(in: .whitespaces)
        return Int(rest) == version ? .installed : .outdated
    }

    /// Writes the skill; refuses to replace a SKILL.md that MacHelper didn't write.
    public static func install(_ t: Target, command: String, fallback: String? = nil) throws {
        if state(t) == .foreign { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: t.file.path]) }
        try FileManager.default.createDirectory(at: t.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown(command: command, fallback: fallback).write(to: t.file, atomically: true, encoding: .utf8)
    }

    /// Removes only MacHelper's own skill folder.
    public static func uninstall(_ t: Target) throws {
        guard state(t) == .installed || state(t) == .outdated else { return }
        let dir = t.file.deletingLastPathComponent()
        let others = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != "SKILL.md" && $0 != ".DS_Store" }
        if others.isEmpty { try FileManager.default.removeItem(at: dir) } else { try FileManager.default.removeItem(at: t.file) }
    }

    /// Refreshes installed copies after an update; returns the targets that were rewritten.
    @discardableResult
    public static func refreshInstalled(command: String, fallback: String? = nil, home: URL = MacHelperPaths.home) -> [Target] {
        targets(home: home).filter { state($0) == .outdated }.filter { (try? install($0, command: command, fallback: fallback)) != nil }
    }

    /// `command` is how the agent should call the CLI: `machelper` when it is on the PATH, otherwise the
    /// full path of the copy inside the app.
    public static func markdown(command: String, fallback: String? = nil) -> String {
        let m = command
        let notFound = fallback.map { "\nIf `\(m)` isn't found, run `\($0)` instead (the copy inside MacHelper.app).\n" } ?? ""
        return """
        ---
        name: machelper
        description: Inspect and clean up this Mac with the MacHelper command-line tool. Use when the user asks to free up disk space, find what is taking space, find large unused files or bloated folders, clean caches, logs or developer junk (Xcode, npm, Docker, node_modules), uninstall an app with its leftovers, update apps installed with Homebrew, check CPU, memory, temperatures, fans, battery or overall Mac health, review startup and background items, or check macOS security settings.
        ---

        \(marker) \(version) -->

        # MacHelper CLI

        Run `\(m)`. Every command previews by default and changes nothing until `--yes` is added. Add `--json`
        to get one JSON document on stdout with a `schemaVersion` field; parse that instead of the text output.
        \(notFound)
        ## Rules

        1. Preview first, then show the user what would happen (items, sizes, Trash or permanent) and get a clear
           yes before running the same command again with `--yes`. Never add `--yes` on your own initiative.
        2. Don't add `--permanent` unless the user asks for it. Low-risk caches and logs are deleted directly,
           everything else goes to the Trash, where the user can get it back.
        3. `insights` only suggests. A file that "looks unused" may still matter: list it, explain why it was
           flagged, and let the user decide. Don't remove findings yourself with `rm`.
        4. Paths the user never wants cleaned go in the exclusion list: `\(m) ignore add <path>`.
        5. Check the exit code: 0 success, 1 failure, 2 partial (some items failed; read the report), 64 usage error.
           With `--json`, errors come back as `{"schemaVersion":1,"error":{"message":…}}`.
        6. A scan that reports `"status": "partial"` couldn't read some folders. Tell the user to give their
           terminal app Full Disk Access (System Settings → Privacy & Security) for a complete result.
           `protectedDirectories` are folders macOS keeps from every app (SIP, data vaults, other accounts):
           expected on a whole-disk scan, nothing to fix.
        7. If `analyze` or `insights` prints that it is waiting, macOS is showing a permission dialog: ask the
           user to answer it. Scanning a specific folder (`~/Downloads`, a project folder) is faster than `~`.

        ## Tasks

        | The user wants to… | Run |
        |---|---|
        | See where the space goes | `\(m) analyze ~ --json --depth 2` (or a folder path) |
        | Find unused big files and bloated folders | `\(m) insights ~ --json` (`--unused-days 365`, `--min-size 500MB`) |
        | Free up space safely | `\(m) clean --json`, then after approval `\(m) clean --yes --json` |
        | Clean one kind of thing | `\(m) rules` lists ids; `\(m) clean --rule xcode.derived-data --json`, `--category developer` |
        | Remove project build folders | `\(m) purge --path ~/Projects --json` (node_modules, target, .build, …) |
        | Find duplicate files | `\(m) duplicates ~/Downloads --json` |
        | Uninstall an app and its leftovers | `\(m) uninstall "App Name" --json`; leftovers of removed apps: `\(m) uninstall --orphans --json` |
        | Update Homebrew apps | `\(m) updates --json`, then `\(m) updates upgrade <cask>… --yes` |
        | Check the Mac right now | `\(m) status --json` (CPU, GPU, memory, disk, network, temperatures, fans, power, battery) |
        | See history or trends | `\(m) stats --range 24h --json`; past cleanups: `\(m) history --json` |
        | Review startup items | `\(m) startup --json`; `--disable <label>` / `--enable <label>` |
        | Check security settings | `\(m) security --json` (read-only) |
        | Run maintenance | `\(m) optimize --json` (QuickLook reset, unavailable simulators, brew cleanup, …) |

        `\(m) guide` prints this guide; `\(m) <command> --help` explains each command and its options.

        ## Reading results

        - `clean`: `plan.results[]` per rule with `candidates[]` (`path`, `size`, `selected`) and `rule.action`
          (`delete` or `trash`); after `--yes`, `report.items[].result` is `deleted`, `trashed`, `skipped` or `failed`.
        - `insights`: `insights.unusedFiles[]` (`path`, `size`, `lastUsed`, `kind`) and `insights.bloatedFolders[]`
          (`path`, `size`, `reasons` among `grew`, `largeCache`, `largeLogs`, `manyFiles`, plus `grownBy`, `since`,
          `largestChild`). Growth needs an earlier scan of the same path; `previousScan` is null on the first run.
        - Sizes are bytes on disk. Show them to the user in GB or MB.
        """
    }
}
