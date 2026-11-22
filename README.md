<p align="center">
  <img src="docs/images/mascot.gif" width="200" alt="The MacHelper slime breathing, waving, hopping and celebrating">
</p>

<h1 align="center">MacHelper</h1>

<p align="center">
  <b>Native macOS system monitor, fan controller, cleaner, disk analyzer, and AI-ready CLI — local-first, open source, and built for Apple Silicon.</b>
</p>

<p align="center">
  <a href="https://github.com/smile-minecraft/MacHelper/releases/latest"><img src="https://img.shields.io/github/v/release/smile-minecraft/MacHelper?label=Release&color=5b8def" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1f2430" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-1f2430" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-4cc38a" alt="MIT license"></a>
  <a href="https://smile-minecraft.github.io/MacHelper/"><img src="https://img.shields.io/badge/Website-Docs-5b8def" alt="Website and documentation"></a>
</p>

<p align="center">
  <b>English</b> ·
  <a href="README.zh-Hant.md">繁體中文</a> ·
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.es.md">Español</a>
</p>

<p align="center">
  <a href="#why-machelper">Why MacHelper</a> ·
  <a href="#install">Install</a> ·
  <a href="#features">Features</a> ·
  <a href="#privacy-and-telemetry">Privacy</a> ·
  <a href="#first-launch">First Launch</a> ·
  <a href="#command-line">CLI</a> ·
  <a href="#use-it-with-ai-agents">AI Agents</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="#building">Building</a>
</p>

<p align="center">
  <img src="docs/images/menubar.png" width="320" alt="MacHelper in the menu bar: CPU with a sparkline, memory and temperature">
</p>

<p align="center">
  <img src="docs/images/overview.png" width="860" alt="Overview: health score, live readings and the apps using the most resources">
</p>

---

MacHelper is a free, MIT-licensed menu bar app and command-line tool written in native Swift for Apple Silicon Macs running macOS 14 or later. It combines a **system monitor** (CPU, GPU, memory, temperatures, fans, power, battery, disk, and network), **fan control**, a **cache and junk cleaner**, a **disk space analyzer**, and an **app uninstaller** in a single lightweight app.

It also ships the `machelper` CLI with `--json` output, a one-shot redacted diagnostic report (`machelper report --json`), and built-in skills for AI coding assistants such as Claude Code, Codex, and OpenCode — always previewing first and asking before anything is removed.

## Why MacHelper

Instead of juggling five separate paid utilities, MacHelper covers the full toolkit in one native app:

| Capability | Replaces | MacHelper Approach |
|---|---|---|
| **System & Menu Bar Monitor** | iStat Menus | Native SwiftUI/AppKit sensors, P/E core split, 1h/24h/7d history, 8 menu bar styles |
| **Fan Speed & Curves** | Macs Fan Control | Fixed RPM or custom temperature curves, "only increase" mode, app/power profiles |
| **Cleanup & Maintenance** | CleanMyMac | Declarative rules, preview-by-default, Trash for medium/high risk, protected paths |
| **Disk Space Analyzer** | DaisyDisk | Fast `getattrlistbulk` sunburst & treemap, APFS clone-aware duplicates, growth tracking |
| **App Uninstaller** | AppCleaner | Bundle ID, helper, container, launchd, and Homebrew zap matching + orphan cleanup |
| **AI Agent Automation** | *Unique to MacHelper* | `machelper report --json` redacted diagnostics, `--yes` safety gate, agent skills |

> **Free · Open Source (MIT) · Native Swift · Apple Silicon · Local-First by Default**

## Install

```sh
brew install --cask smile-minecraft/tap/machelper
```

Or download `MacHelper-<version>.dmg` from [Releases](https://github.com/smile-minecraft/MacHelper/releases/latest) and drag **MacHelper** into Applications. Releases are signed with a Developer ID and notarized by Apple, with checksums published in `SHA256SUMS.txt` on each release page. You can also visit the [MacHelper Website](https://smile-minecraft.github.io/MacHelper/) for an overview and release highlights.

**Automatic updates:** MacHelper checks for updates in the background and shows an **Update to x.y.z** button in the sidebar, menu bar panel, and Settings — nothing is installed until you click it. Release notes appear in your selected app language.

## Features

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>System Monitor</h3>
      <img src="docs/images/monitor.png" alt="Monitor: CPU, GPU, memory, temperature, fans and power charts with warning lines">
      <p>Live charts and per-minute history (1 hour, 24 hours, or 7 days) for CPU (performance and efficiency cores), GPU, memory pressure, temperatures, fans, power, battery, disk, and network throughput — with warning lines for memory and heat. Customize each menu bar item as text, sparkline, columns, bar, ring, blocks, heat pill, or dual lines.</p>
    </td>
    <td width="50%" valign="top">
      <h3>Health Check</h3>
      <img src="docs/images/health.png" alt="Health check: score, readings over the last 24 hours and free space history">
      <p>Computes a health score from recent system history, free disk space, and background items, explaining what lowered it and what to do. Includes a read-only security audit of Gatekeeper, FileVault, Firewall, System Integrity Protection (SIP), automatic security updates, and XProtect.</p>
    </td>
  </tr>
  <tr>
    <td colspan="2" valign="top">
      <h3>Disk Analysis</h3>
      <img src="docs/images/disk.png" alt="Disk analysis: a sunburst of the home folder next to its largest folders">
      <p>Interactive sunburst and treemap (click any folder to drill in), largest files with kind and age filters, duplicate detection (APFS clones and hard links understood), scan-over-scan growth changes, and space suggestions for large unused files and bloated folders. Drag items to the collector and move them to the Trash in one go.</p>
    </td>
  </tr>
</table>

| Area | Highlights |
|---|---|
| **Fan control** | Automatic, fixed speed, or temperature curves (Quiet, Balanced, Performance, Custom), an "only increase" mode, hard safety limits, and profiles that switch automatically by running app or power source. |
| **One-click optimize** | Declarative cleaning rules with a preview: low-risk caches are deleted directly, while medium- and high-risk items go to the Trash. Includes protected paths, a never-clean list, an operation log, maintenance tasks, project build-artifact cleanup, and scheduled auto-clean. |
| **App uninstaller** | Traces leftovers via bundle IDs, embedded helpers, entitlements, container metadata, `launchd` ownership, Homebrew zap lists, and per-app rules. Name-only matches are flagged for review, and leftovers from already-deleted apps can be scanned too. |
| **Startup items** | Manage your user Launch Agents (disable, enable, remove) and inspect all-users agents and system daemons, with owning apps and broken items clearly marked. |
| **Homebrew updates** | Review and update casks and apps installed with Homebrew right from MacHelper. |
| **Alerts** | Configurable notifications for high CPU temperature, critical memory pressure, and low disk space. |
| **Optional history** | Process, sensor, and core history are off by default. Process history keeps only name, CPU, and memory (no paths, arguments, or user names) with 1–30 days retention. |
| **The slime** | The mascot reflects your Mac's state (blue, yellow, red), reacts to clicks, hovering, dragging, heat, and completed cleanups, and respects Reduce Motion and VoiceOver. |
| **Themes & Materials** | Light, Dark, or System mode; Solid, Frosted, or Liquid Glass surface materials; Instrument and Pixel Retro presets; VS Code theme import; and contrast-checked readability across every surface. |
| **Languages** | English, Traditional Chinese, Simplified Chinese, Japanese, Korean, and Spanish. Set independently of macOS under **Settings → General → Language**. |

## Privacy and Telemetry

- **Local-first by default.** Everything MacHelper measures, scans, and stores stays on your Mac. There are no user accounts, no cloud sync, and no background tracking. Aside from update checks, MacHelper makes zero network requests unless you explicitly opt in.
- **Optional Telemetry (OFF by default).** Under **Settings → General → Privacy & Diagnostics**, you can choose to share strictly anonymous usage counts and coarse performance diagnostics (app version, macOS version, chip family, and anonymized feature counters).
- **Zero sensitive data.** File paths, process names, disk contents, hostnames, and personal identifiers are never collected. You can preview the exact JSON payload inside Settings before anything is sent and disable telemetry at any time — turning it off immediately clears the anonymous identifier and any queued events.

## First Launch

MacHelper opens a guided 6-step **Welcome Guide** (replayable anytime via **Help → Welcome Guide…**) that walks through your preferences, optional **Full Disk Access**, **the Helper**, and **AI Agent skills**. Every other feature works without the optional permissions:

1. **Full Disk Access** lets disk analysis and cleanup inspect protected locations such as Mail downloads and other apps' caches. Enable MacHelper in **System Settings → Privacy & Security → Full Disk Access**; the Welcome Guide detects the change automatically. Folders protected by System Integrity Protection (SIP) remain unreadable and are listed separately.
2. **The Helper** is a lightweight root daemon for fan control, system cache and log cleanup, system background items, and system process usage. The guide installs it, opens **System Settings → General → Login Items & Extensions** for approval, and verifies it responds. Every caller's code signature is verified. If disabled, **Set up Helper…** at the bottom of the sidebar reopens the Helper setup.
3. **AI Agent Skills** can be installed for detected agents (such as Claude Code and Codex) directly from the guide without overwriting existing custom `SKILL.md` files.

## Command Line

MacHelper bundles the `machelper` CLI (linked automatically by Homebrew). Every command previews by default and supports `--json`, making it ideal for scripts and AI agents. Run `machelper guide` for an overview or `machelper <command> --help` for per-command options.

```sh
machelper report --json                 # redacted full-system diagnostic report
machelper status --json                 # live hardware, thermal, fan, and battery snapshot
machelper clean                         # preview what would be cleaned
machelper clean --max-risk low --yes    # clean only low-risk items
```

## Use It with AI Agents

When you ask an AI assistant (Claude Code, Codex, OpenCode, etc.) to diagnose why your Mac is slow or running hot, free up disk space, clean `node_modules` or Xcode leftovers, uninstall an app completely, or audit startup items, `machelper` gives it a safe, structured interface.

- **One-shot redacted diagnostics (`machelper report`).** Run `machelper report --json` (or `machelper report --format markdown`) to generate a complete system diagnostic report in a single call — covering hardware, live metrics, health score, storage usage, security audit, cleanup preview, and startup items. Personal usernames, home paths, hostnames, IPs, and MAC addresses are scrubbed by default, and the JSON output includes structured `suggestedActions` and `availableTools` so agents can safely chain follow-up `machelper` commands.
- **Safe by default.** Mutating commands preview only and change nothing until `--yes` is passed. Removed items move to the Trash unless `--permanent` is specified, and protected paths (Keychains, Mail, Photos, `~/.ssh`, `~/Documents`, …) can never be deleted.
- **Machine-readable.** `--json` works across commands with a `schemaVersion` field, predictable exit codes, and `machelper --experimental-dump-help` for the full JSON command tree.
- **Built-in agent skill.** `machelper skill install claude` or `machelper skill install codex` (also available in Settings) installs a `SKILL.md` instructing the agent to inspect/preview first and ask for confirmation before applying changes.

```sh
brew install --cask smile-minecraft/tap/machelper
machelper guide                          # guide an agent should read first
machelper report --json                  # full redacted diagnostic report + suggestedActions
machelper insights ~ --json              # large unused files and bloated folders
machelper clean --json                   # preview cleanup; confirm with the user before --yes
```

A machine-friendly index for language models is available in [llms.txt](llms.txt).

## FAQ

**Is there a free, open-source alternative to CleanMyMac or iStat Menus?**
Yes. MacHelper is MIT licensed and combines cleanup, menu bar system monitoring, fan control, disk analysis, and app uninstalling in one native app — no accounts and no subscriptions.

**How do I control the fan speed of an Apple Silicon Mac?**
Install MacHelper and set up its Helper (guided on first launch). You can then run fans automatically, at a fixed RPM, or on a custom temperature curve with hard safety limits and automatic profiles per app or power source.

**How do I get a safe system report for an AI assistant without leaking personal info?**
Run `machelper report --json` (or `--format markdown`). It collects hardware, metrics, health score, storage, security checks, cleanup previews, and startup items in one shot while automatically scrubbing usernames, paths, hostnames, IPs, and MAC addresses.

**How do I free up disk space on a Mac from the terminal?**
Install via `brew install --cask smile-minecraft/tap/machelper`, run `machelper clean` to preview, and `machelper clean --max-risk low --yes` to clean low-risk caches. Use `machelper insights ~` to find large unused files or bloated folders, and `machelper purge --path ~/Developer` to remove build folders such as `node_modules`, `target`, and `.build`.

**How do I completely uninstall a Mac app and its leftovers?**
Run `machelper uninstall "App Name"` to preview preferences, caches, containers, launch agents, and Homebrew zap matches; add `--yes` to move them to the Trash. Run `machelper uninstall --orphans` to locate leftovers of apps already removed.

**Does it work on Intel Macs or older macOS?**
No. MacHelper requires an Apple Silicon Mac running macOS 14 or later.

**What data does MacHelper collect?**
By default, nothing leaves your Mac except update checks. If you explicitly opt in under **Settings → General → Privacy & Diagnostics**, MacHelper sends strictly anonymous usage counts and coarse performance diagnostics (app version, macOS version, chip family) with zero file paths, process names, or personal identifiers. You can inspect the exact JSON payload and turn it off anytime.

## Building

Requirements: an Apple Silicon Mac, Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Run `make` to list all available targets.

```sh
make setup      # check tools, download Sparkle, generate MacHelper.xcodeproj
make open       # open the project in Xcode, then build and run with ⌘R
make run        # or build a Debug copy under build/ and open it
make test       # run unit tests for the Swift packages
make install    # Release build → /Applications/MacHelper.app, then relaunch
```

Day-to-day builds target `build/` without modifying `/Applications`. Quit any installed copy of MacHelper before running from `build/`, since both share settings and data. Testing root Helper changes (fan control, system cleanup) is easiest with `make install`. Run `make project` after adding or removing source files, or `make run ARGS=--demo-battery` to simulate battery readings on desktop Macs.

**Performance profiling:** MacHelper includes Apple-native `OSSignposter` instrumentation across scanning, sampling, and UI hot paths. Use `scripts/perf/xctrace-profile.sh` to capture Instruments traces directly from the command line during development.

<details>
<summary><b>Developer reference: local Xcode config, repository structure, screenshots, releasing, and translating</b></summary>

### Local Overrides & Signing

The build uses the active Xcode from `xcode-select`. To pin a specific Xcode for this repo only, create a git-ignored `Config/Local.env`:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.app/Contents/Developer
```

`Config/Signing.xcconfig` signs ad-hoc by default. For a Helper registration that survives rebuilds, create a git-ignored `Config/Local.xcconfig` with your team (a free Apple ID Personal Team works):

```
DEVELOPMENT_TEAM = XXXXXXXXXX
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
```

### Repository Structure

| Path | Purpose |
|---|---|
| `App/` | SwiftUI/AppKit menu bar app |
| `Helper/` | Root helper daemon (fan writes, root-only maintenance) |
| `Sources/SMCKit`, `Metrics`, `FanControl` | Hardware access, sampling, fan curves and policies |
| `Sources/DiskScan` | Fast `getattrlistbulk` scanner, chart layouts, duplicates, scan snapshots |
| `Sources/CleanEngine` | Cleaning rules, safety checks, uninstaller, startup items, auto-clean |
| `Sources/Storage` | Metric history (GRDB) |
| `Sources/machelper` | The CLI |
| `docs/release-notes/` | Translated release notes shown in the update window |
| `scripts/perf/` | `xctrace-profile.sh` performance tracing helpers |

### Regenerating README Images

Run `make screenshots` (or `MacHelper --snapshot-demo DIR` in Debug builds) to render synthetic fake-data screenshots for `overview`, `monitor`, `health`, `disk`, and `menubar.png`, and `--export-mascot-gif FILE` to export the slime animation.

### Releasing

1. Move changes under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) to a new `## [x.y.z]` section (becomes GitHub release notes and English update-window notes).
2. Translate that section into `docs/release-notes/x.y.z/<lang>.md` for `zh-Hant`, `zh-Hans`, `ja`, `ko`, and `es`.
3. `scripts/release.sh build x.y.z` — dry run: tests, clean Release build, DMG and zip.
4. `SPARKLE_APPCAST=1 scripts/release.sh prepare x.y.z` — tests, Developer ID build, notarization, version commit, `vx.y.z` tag, and Sparkle appcast generation.
5. `scripts/release.sh publish x.y.z` — pushes `main` and tag, creates the GitHub release, updates the [Homebrew tap](https://github.com/smile-minecraft/homebrew-tap), and publishes the appcast to GitHub Pages.

CI (`.github/workflows/ci.yml`) runs unit tests and an ad-hoc signed build on every push and pull request.

### Translating

English is the source language. Translations live in String Catalogs: `App/Resources/Localizable.xcstrings`, `Sources/CleanEngine/Localizable.xcstrings`, and `Sources/CleanEngine/Rules.xcstrings` (`rule.<id>.title`). Add a language in Xcode or via `scripts/l10n/add.py --lang <code>`, then run `scripts/l10n/check.py` after building to verify completeness. New languages also register in `AppLanguage.all` (`App/Main/AppLanguage.swift`), `NOTE_LANGS` (`scripts/sparkle/appcast.sh`), and add a localized README.

</details>

## License

MIT — see [LICENSE](LICENSE).
