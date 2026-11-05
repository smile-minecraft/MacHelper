# machelper CLI

Command-line access to MacHelper's cleaning, project-artifact purge, maintenance, disk analysis and
system status. Designed for scripts and AI agents: previews by default, JSON everywhere, stable exit codes.

The app ships the CLI at `MacHelper.app/Contents/MacOS/machelper-cli`. **Settings → Command-line tool → Install**
links it as `~/.local/bin/machelper` (no administrator needed). To build it on its own:

```sh
swift build -c release --product machelper
.build/release/machelper --help
```

Keep `MacHelperKit_CleanEngine.bundle` next to a standalone binary (it holds the built-in rules). The copy
inside the app follows the app's language; a standalone build prints English.

## Safety model

- **Nothing is removed without `--yes`.** Without it every command prints the plan and exits 0.
- Removed items go to the **Trash** unless `--permanent`. The only exception is the `user.trash`
  rule, which empties the Trash (that is its purpose).
- Protected paths (Keychains, Preferences, iCloud Drive, Mail, Photos, Messages, `~/.ssh`, `~/Documents`,
  `~/Desktop`, system folders, …) can never be removed, nor can anything containing them.
  Safety is checked when scanning **and again right before each removal**.
- Your own exclusions: one glob per line in `~/Library/Application Support/MacHelper/clean-whitelist.txt`.
- Caches of running apps are found but not selected; rules for running browsers / Xcode are skipped.
- `purge` never touches artifacts that contain git-tracked files or a nested repository, nor anything under
  a docker-compose project's `volumes/` or `data/`. Artifacts used in the last 7 days are not selected.
- Every real operation is appended to `~/Library/Logs/MacHelper/operations.jsonl` (`machelper history`).

## Commands

| Command | What it does |
|---|---|
| `machelper clean` | Caches, logs, browser and developer caches, Trash, installers… (declarative rules) |
| `machelper purge --path DIR` | Project build artifacts: `node_modules`, `target`, `.build`, `.venv`, … |
| `machelper optimize` | Maintenance: QuickLook reset, unavailable simulators, `brew cleanup`, … |
| `machelper uninstall APP` | An app plus everything it left behind (see below); `--list`, `--orphans` |
| `machelper autoclean` | The scheduled low-risk clean: `--status`, `--now`, `--run-if-due` |
| `machelper startup` | Launch agents / daemons; `--disable`, `--enable`, `--remove LABEL --yes`, `--broken` |
| `machelper analyze [PATH]` | Where the space goes (allocated size, hard links and APFS clones counted once) |
| `machelper duplicates [PATH]` | Files with identical content (size → 64 KB head/tail → SHA-256), clones marked |
| `machelper stats --range 24h` | Recorded per-minute metric history (retention defaults to 7 days and is adjustable in Settings → General → Data management; background recording continues after the app quits when enabled) |
| `machelper status` | CPU, GPU, memory, disk, network, temperatures, fans, power, battery |
| `machelper rules` | Lists rule ids, maintenance task ids and artifact detectors |
| `machelper history` | The operation log |

All accept `--json`. Root-only tasks (`dns.flush`, `memory.purge`) run through the app's Helper and show
as unavailable in the CLI.

## History

`machelper stats` reads the per-minute monitoring history. The same database holds two optional kinds of
history, both off by default and enabled under **Settings → General → Data management**: process history and
sensor and core history. Process history stores only the process name, CPU use and memory (no paths, command-line
arguments or user names), with each minute’s top 10 by CPU and by memory. Sensor and core history stores one
average per minute for every temperature sensor and CPU core cluster, so it grows faster. Both use the same
retention as the monitoring history (7 days by default, adjustable to 1, 3, 7, 14 or 30 days) and can be
cleared separately in the app.

## Recipes

```sh
# Unattended / scheduled: low-risk rules only.
machelper clean --max-risk low --yes --json

# Exactly these rules, nothing else.
machelper clean --rule xcode.derived-data --rule dev.npm --yes

# Agent workflow: preview, inspect, then apply the same selection.
machelper clean --json > plan.json            # read .plan.results[].candidates
machelper clean --rule user.caches --yes --json

# Build artifacts in your projects folder.
machelper purge --path ~/Developer --json
machelper purge --path ~/Developer --yes

# Uninstall an app with its data (preview first).
machelper uninstall "Hermes" --with-data
machelper uninstall com.nousresearch.hermes.setup --with-data --yes

# Background items whose program is gone.
machelper startup --broken --json

# Status as NDJSON stream.
machelper status --json --watch 10 --interval 2
```

## JSON notes

- Every document has `"schemaVersion": 1`.
- `clean`/`purge` output `{applied, plan|scan, report}`; `report.items[].result` is one of
  `trashed`, `deleted`, `wouldTrash`, `wouldDelete`, `skipped`, `failed`.
- `analyze --json` has `"status": "complete" | "partial"`; partial means some folders were unreadable
  (grant Full Disk Access to the terminal). Partial scans still exit 0, so check this field.
- Exit codes: `0` success, `1` failure, `2` partial (some items failed), `64` usage error.

## Adding rules

Drop a JSON file in `~/Library/Application Support/MacHelper/rules/` (same format as
`Sources/CleanEngine/Rules/*.json`). A rule with an existing id replaces the built-in one.
Rules describe paths only; they cannot run commands.

```json
{
  "schemaVersion": 1,
  "rules": [{
    "id": "my.app-cache", "title": "My App cache", "category": "caches", "risk": "low",
    "paths": ["~/Library/Caches/com.example.MyApp/*"], "minAgeDays": 0,
    "skipIfRunning": ["com.example.MyApp"]
  }]
}
```

## How `uninstall` finds leftovers

Every item carries its **evidence**; strong evidence is selected by default, name-based matches are shown
for you to confirm, and app data (Application Support, containers, `~/.name` folders) is only selected with
`--with-data`.

| Evidence | Meaning |
|---|---|
| `bundleID` | Named by the bundle ID (also `id.ShipIt`, `group.id`, `TEAM.id`, `/var/folders/…/C/id`) |
| `embeddedID` | Named by a helper, XPC service, login item or extension inside the app |
| `appGroup` | An App Group from the app's entitlements |
| `containerMetadata` | A UUID-named container whose metadata names the app |
| `program` | A launch agent, `~/.local/bin` command or browser native host whose program lives in the app |
| `homebrew` | Listed by the app's Homebrew cask (`zap`) |
| `rule` | A per-app rule in `Sources/CleanEngine/UninstallRules/apps.json` |
| `family` | The parent bundle ID (`com.foo.app.setup` → `com.foo.app`) when no other app uses it |
| `teamID` | A Team-ID group container, team used by no other installed app |
| `reference` | A launch agent or command that runs something from the app's data folder (goes with the data) |
| `name` / `vendor` | The app's (normalized, channel/version-less) name or the developer's folder — check these |

Dot-folders of separately installed command-line tools that share the app's name (`~/.claude` for
Claude.app, and anything a command on your PATH runs from) are reported under **kept**, never removed.
