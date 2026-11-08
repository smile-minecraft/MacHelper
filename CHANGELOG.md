# Changelog

Each release's notes on GitHub come from its section here (`scripts/release.sh`). Add changes under
**Unreleased** as they land, then rename it to the version before releasing.

## [Unreleased]

## [0.2.0]

The first public release. MacHelper is signed with a Developer ID and notarized by Apple, so it opens
like any other app, without a Gatekeeper warning or an "Open Anyway" step. Requires macOS 14 or later.

### Languages
- Simplified Chinese, Japanese, Korean and Spanish, alongside English and Traditional Chinese.
- One language list for the language picker and settings backups.
- The localization check covers every shipped language, including health check findings and rule text.

### Health
- A health score on Overview, Health Check and the menu bar, from current disk and memory readings and
  the latest health check (which covers the last 24 hours; security settings excluded); refreshed every
  5 minutes.
- Health check findings translated into all six languages.
- Free-space levels use absolute values: 25 GB or more is fine, under 10 GB is critical; Overview, the
  menu bar, the attention list and Health Check share the same thresholds.

### Disk
- Folders macOS protects (System Integrity Protection, data vaults, other user accounts) no longer count
  as unreadable; they are listed separately as protected, and disk analysis no longer looks incomplete
  because of them.

### Interface
- Removed reassurance captions ("only reads", "nothing is removed without your confirmation") and
  free-space forecasts ("full in about N days"); free space does not change linearly, so those numbers
  were misleading.
- Page switches and disk chart changes animate more smoothly, and the monitor charts and mascot use less
  CPU; Reduce Motion is respected.

### Internal
- The macOS CI job is skipped while the repository is private; private-repository runner minutes are
  billed at 10x, and the job runs once the repository is public.

## [0.1.0]

An internal trial build; it was never published. The first public release is 0.2.0.

### Monitor
- Menu bar readings for CPU (performance and efficiency cores), GPU, memory pressure, disk and network
  speed, temperatures, fans, power and battery, each shown as text, a line, a bar or a ring.
- Per-minute history kept for 1 to 30 days, with optional process, sensor and core history.
- Alerts for high CPU temperature, critical memory pressure and low disk space.
- A health check with a free-space trend, and a read-only check of macOS security settings
  (Gatekeeper, FileVault, firewall, System Integrity Protection, automatic security updates, XProtect).

### Fans
- Automatic, fixed speed or temperature curves, an "only increase" mode, hard safety limits, and
  profiles that switch by running app or power source, through a root helper that checks the
  caller's code signature.

### Clean up
- Rule-based cleanup with a preview: low-risk caches and logs are deleted, everything else goes to the
  Trash. Search, filters, sorting and a list of paths never to clean.
- Developer junk (Xcode, simulators, npm, Docker and more), AI tool logs and caches (oMLX, Ollama,
  LM Studio), Trash folders on other drives, and project build folders.
- Scheduled cleanup of low-risk items, maintenance tasks and an operation history.
- Updates for apps installed with Homebrew.

### Disk
- Sunburst and treemap, largest files, duplicates and what changed since the last scan.
- Suggestions: big files not used for six months, and folders that grew, have oversized caches or
  logs, or hold too many files, marked in the charts.

### Apps and startup
- An uninstaller that finds an app's leftovers, including those of apps already removed.
- Startup items: your launch agents, all-users agents and system daemons, with broken items flagged.

### Command line and agents
- The `machelper` command: previews by default, `--json` everywhere, JSON errors.
- A skill for Claude Code and Codex that teaches them to use it safely, offered on first launch.

### Appearance
- Themes (Instrument, Pixel Night, Pixel Day, Classic), custom colours, VS Code theme import, fonts,
  text size, simple and advanced modes, replaceable icons and an optional pixel logo.
- English and Traditional Chinese.

[Unreleased]: https://github.com/smile-minecraft/MacHelper/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/smile-minecraft/MacHelper/releases/tag/v0.2.0
