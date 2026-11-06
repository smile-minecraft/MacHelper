# Changelog

Each release's notes on GitHub come from its section here (`scripts/release.sh`). Add changes under
**Unreleased** as they land, then rename it to the version before releasing.

## [Unreleased]

## [0.1.0]

The first public release. Requires macOS 14 or later; tested on Apple silicon.

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

[Unreleased]: https://github.com/smile-minecraft/MacHelper/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/smile-minecraft/MacHelper/releases/tag/v0.1.0
