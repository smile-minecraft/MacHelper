# MacHelper

English · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md)

An all-in-one, fully local Mac utility for macOS 14 and later: fan control, a menu-bar system monitor,
one-click cleanup, disk analysis, an app uninstaller and startup-item management. MIT licensed.

## Features

- **Menu-bar monitor** — CPU (P/E cores), GPU, memory pressure, disk and network throughput, temperatures,
  fans, power and battery, each configurable as text, line, bar or ring. Top processes by CPU and memory.
- **History** — per-minute averages (SQLite) kept for 7 days by default; choose 1, 3, 7, 14 or 30 days
  in Settings → General → Data management. Browsable for 1 h / 24 h / 7 d.
- **Optional process, sensor and core history** — off by default; enable each under Settings → General → Data
  management. Process history stores only the process name, CPU use and memory (no paths, command-line
  arguments or user names), keeping each minute’s top 10 by CPU and by memory. Sensor and core history stores
  one average per minute for every temperature sensor and CPU core cluster, adding several dozen rows per
  minute. Both use the same retention setting and can be cleared separately.
- **Alerts** — notifications for high CPU temperature, critical memory pressure and low disk space.
- **Fan control** — automatic, fixed speed or temperature curves (quiet / balanced / performance / custom),
  "only increase" mode, hard safety limits, and automatic profile switching by running app or power source.
  Runs through a root helper (`SMAppService` daemon) that verifies the caller's code signature.
- **One-click optimize** — declarative JSON cleaning rules with preview (low-risk caches deleted directly, medium and high risk to the Trash), protected paths,
  a whitelist, an operation log, maintenance tasks, project build-artifact purge and scheduled auto-clean of
  low-risk items.
- **Disk analysis** — sunburst and treemap, largest files with kind/age filters, duplicate files (APFS clones
  and hard links understood), what changed since the last scan, and a collector to trash items in one go.
- **App uninstaller** — finds what an app left behind using bundle IDs, embedded helpers, entitlements,
  container metadata, launchd ownership, Homebrew zap lists and per-app rules; name matches are flagged
  for review. Also finds leftovers of apps that are already gone.
- **Startup items** — your launch agents (disable / enable / remove), all-users agents and system daemons,
  with the owning app and broken items flagged.
- **App updates** — updates apps installed with Homebrew.
- **Security check** — reads Gatekeeper, FileVault, firewall, SIP, automatic security updates and XProtect
  (read-only).
- **Space suggestions** — big files not used for six months and folders that look bloated, marked in the
  disk charts.
- **CLI** — everything scriptable for automation and AI agents: previews by default, `--json` everywhere.
  Run `machelper guide` for an overview and `machelper <command> --help` for each command.
- **Languages** — English, Traditional Chinese, Simplified Chinese, Japanese, Korean and Spanish (String
  Catalogs; see below to add one). Settings → General → Language overrides the system language.

## Install

Download `MacHelper-<version>.dmg` from [Releases](https://github.com/smile-minecraft/MacHelper/releases)
and drag MacHelper to Applications. Or with Homebrew:

```sh
brew install --cask smile-minecraft/tap/machelper
```

MacHelper is signed with a Developer ID and notarized by Apple, so it opens like any other app. Fan
control and system cleanup need the helper: allow it in **System Settings → General → Login Items** when MacHelper asks.

To see the whole disk, turn on MacHelper in **System Settings → Privacy & Security → Full Disk Access**.
Folders under System Integrity Protection or owned by another user stay unreadable even then; that's
macOS protecting them, and disk analysis lists them separately as protected.

Checksums for each download are in `SHA256SUMS.txt` on the release page.

## Building

Requirements: Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
scripts/install.sh          # Release build → /Applications/MacHelper.app, then relaunch
swift test                  # unit tests for the Swift packages
```

Signing: `Config/Signing.xcconfig` defaults to ad-hoc. For a stable helper registration, create a
git-ignored `Config/Local.xcconfig` with your team (a free Apple ID's Personal Team works):

```
DEVELOPMENT_TEAM = XXXXXXXXXX
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
```

The first launch asks you to allow the helper in **System Settings → General → Login Items**.

## Layout

| Path | |
|---|---|
| `App/` | The SwiftUI/AppKit menu-bar app |
| `Helper/` | Root helper daemon (fan writes, root-only maintenance) |
| `Sources/SMCKit`, `Metrics`, `FanControl` | Hardware access, sampling, fan curves and policies |
| `Sources/DiskScan` | Fast `getattrlistbulk` scanner, chart layouts, duplicates, scan snapshots |
| `Sources/CleanEngine` | Cleaning rules, safety checks, uninstaller, startup items, auto-clean |
| `Sources/Storage` | Metric history (GRDB) |
| `Sources/machelper` | The CLI |

## Releasing

1. Move the changes under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) to a new `## [x.y.z]` section.
2. `scripts/release.sh build x.y.z` — a trial run: tests, a clean Release build, the DMG and zip.
3. `scripts/release.sh prepare x.y.z` — the same, then commits the version and tags `vx.y.z` locally.
4. `scripts/release.sh publish x.y.z` — pushes `main` and the tag, creates the GitHub release with the
   DMG, zip, checksums and the changelog section as notes (0.x versions are pre-releases), then updates
   `Casks/machelper.rb` in the [Homebrew tap](https://github.com/smile-minecraft/homebrew-tap) and pushes it.

CI (`.github/workflows/ci.yml`) runs the tests and an ad-hoc signed build on every push and pull request.

## Translating

Source strings are English. Translations live in String Catalogs:
`App/Resources/Localizable.xcstrings`, `Sources/CleanEngine/Localizable.xcstrings` and
`Sources/CleanEngine/Rules.xcstrings` (rule text, keyed `rule.<id>.title`). Open them in Xcode and add a
language, or use `scripts/l10n/add.py --lang ja`. After a build, `scripts/l10n/check.py` lists strings missing in any
shipped language. A new language also goes into `AppLanguage.all` (`App/Main/AppLanguage.swift`) for the language
picker, and gets a README.

## License

MIT — see [LICENSE](LICENSE).
