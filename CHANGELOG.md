# Changelog

Each release's notes on GitHub come from its section here (`scripts/release.sh`). Add changes under
**Unreleased** as they land, then rename it to the version before releasing.

## [0.3.4]

The menu bar SSD page switches between local disks, the Network page keeps to the system’s primary
interfaces and active tunnels, and Homebrew Updates shows its first result while the index
refreshes.

### SSD
- The SSD tab has a disk menu for the startup disk, its data volume and every other local volume
  mounted under `/Volumes`. Each disk keeps its own capacity figures and its own seven-day
  free-space chart; a disk that is unplugged or cannot be identified is reported instead of
  silently replaced.
- Every disk with a stable identity gets one free-space point an hour. Missing hours stay gaps:
  the chart does not fill in zeroes or join two runs across them. A disk that shares free space
  with other APFS volumes in the same container says so, and the read and write rates below the
  chart are labelled as covering every disk in the Mac.
- Recording follows “Keep recording after MacHelper quits”: with it on, the hourly points continue
  while MacHelper is closed; with it off, they stop when it quits.
- Clearing monitoring history now names the per-disk free-space history, and the SSD page drops
  its stale chart as soon as the clear succeeds.

### Network
- Live download and upload rates work again. The reader behind them stopped at the address
  records macOS writes between interface records; it now steps over those records and reads every
  interface, which also gives the new interface cards their link speed.
- The menu bar Network page is compact: it lists the system primary interfaces and the tunnels
  that are up and running. Each card shows the name, state, one IPv4 address and the link speed;
  IPv6 addresses and MTU stay off the cards.
- A note under the cards says that a primary interface does not prove internet access; when a
  tunnel is listed, a second note says it is not necessarily a VPN. The rates at the top are
  labelled “All interfaces · bytes per second”, separate from each interface’s link speed.

### Monitor
- Switching from 7 days back to Live no longer freezes the window; with a week of minute data it
  could block for about 35 seconds. Live main charts draw from memory at once, and a history range
  keeps the previous chart until its own query finishes, so a late reply cannot replace a newer
  range.
- 24 hours and 7 days average into 5- and 30-minute buckets, so a week of one sensor draws about
  320 points instead of 9,500. A gap still leaves a gap, and a range that holds a single bucket
  shows a visible point instead of an empty chart.

### Homebrew Updates
- The page shows the list from Homebrew’s existing index first and reads app details in the
  background. When the index is older than Homebrew’s own 24-hour window, it refreshes the index
  after that first result and replaces the list when the refresh finishes.
- “Check Again” runs `brew update` first and keeps the previous list on screen while it works.
  Rows are marked as unconfirmed and cannot be updated from the app until their details have been
  read again.
- The time the index was updated and the list’s own age are reported separately: a list read from
  an old index is not presented as current, and “all up to date” is only claimed after this check
  refreshed the index successfully without a warning.

### Optimize
- The Optimize start screen has an Auto Clean card with its on/off state and what the schedule
  does. It opens the existing schedule settings; it never turns the schedule on or starts a clean
  itself.

### Languages
- New and changed text is translated into all six languages.

## [0.3.3]

Pages open with the last result already on screen, the fan presets are step curves, and Homebrew
Updates no longer offers MacHelper itself.

### Speed
- Health Check shows its previous report immediately and refreshes in the background. The first load drops from about 718 ms to 60 ms; switching between 1 hour, 24 hours and 7 days takes 1–2 ms after the first time.
- Disk Analysis restores a location you already opened in about 0.2 ms instead of 818 ms; Uninstall reopens with its app list in 114 ms instead of 683 ms, and Startup Items takes 27 ms instead of 199 ms.
- Caches are bounded: health reports (3 periods, 60 s), security (5 min), disk trees (2, one after leaving the page), volume figures (8, 60 s), app lists (2 min), startup items (1 min), sensor and process history (6 and 4 selections, 1 min).
- Memory stays at the same level after launch and after visiting six pages; the disk page uses about 245 MB at the same point where it used 654 MB before.

### Fans
- Quiet, Balanced and Performance are step curves now: the fans hold a speed for a few degrees, then climb. Quiet stays below Balanced, which stays below Performance at every temperature.
- Existing custom curves are untouched; an old preset is shown as Custom until you choose a preset again.
- Automatic switching retries after a temporary Helper failure or when the Helper becomes available again.

### Homebrew Updates
- MacHelper no longer appears in its own Homebrew update list, even with “Include apps that update themselves”. The check recognizes the cask that installed the running app, so a stale cask version can’t offer a downgrade.
- Reopening the page shows the previous list at once and refreshes it in the background.

### UI and fixes
- The Optimize filter bar becomes two rows in a narrow window; the Never Clean sheet grows with its content; totals are right-aligned; an empty selection no longer says “0 maintenance tasks”.
- Fan speed values are no longer clipped at large text sizes; full error messages are available on hover or by selecting the text; unsupported fans no longer show an internal strategy string.
- Checkboxes and icon buttons have VoiceOver labels; the health page’s CPU note stays under the CPU list and its columns no longer truncate at large text sizes.
- New text is translated into Traditional Chinese.

## [0.3.2]

MacHelper now tells you about updates instead of installing them silently, shows the update notes in
your language, and the menu bar item finally keeps its full width.

### Updates
- When a background check finds a new version, an **Update to x.y.z** button appears in the sidebar, the menu bar panel and Settings. Clicking it shows what's new and installs the update; nothing is installed without asking.
- MacHelper checks every four hours instead of once a day.
- The update window shows the release notes in the language MacHelper runs in (English, Traditional Chinese, Simplified Chinese, Japanese, Korean or Spanish).
- 0.3.0 and 0.3.1 turned on silent installs at every launch; this version turns that off once.

### Fixes
- The menu bar item no longer gets stuck at its launch width with the readings clipped on both sides. Its width is now measured whenever the items, styles, labels or font change.
- Disk analysis: the side panel's tabs (Contents, Largest, Duplicates, Changes, Suggestions) were cut off in English and other longer languages. The panel is a little wider, and when the names still don't fit, the tabs become a menu with the full names.

### Documentation
- A new README with the slime animation and screenshots of the app, in all six languages.

## [0.3.1]

A guided Helper setup, smoother slime animation, clearer chart warning lines, and a sunburst that
opens the folder you click.

### Helper
- A setup guide walks through installing the Helper, allowing it in System Settings → General → Login Items & Extensions, and confirms it answers. It appears once on first launch (after Full Disk Access) and from “Set up Helper…” in the sidebar whenever the Helper is off.

### Mascot
- Taps, double-clicks, cleanup and health celebrations are real hops now: crouch, rise, hang, fall and land.
- Hands rise and lower over a couple of frames, and hovering gives a short wave.
- Frames no longer stutter: the animation timer samples the middle of each frame instead of its edge.

### Charts
- Warning-line labels sit at the right end of their line on a small tag; the higher line’s label goes above it and the lower one’s below, so close lines no longer overlap and labels stay clear of the title.
- The memory chart’s scale stops at 100 %, and other charts leave room above the highest warning line.

### Disk analysis
- Clicking a folder in the sunburst opens that folder directly instead of the next level down; clicking a file opens its folder.

### Fixes
- The menu bar item re-applies its full width when something else leaves it narrower, so its contents aren’t clipped on both sides.

## [0.3.0]

MacHelper now updates itself with Sparkle, keeps the Dock icon only while a window is open, lets the
slime react to what is happening, and adds focused chart options. The overview and menu bar use less
CPU, and background recording is stopped and restored around updates.

### Updates
- MacHelper checks for a new version in the background and asks before installing it. “Check for Updates” is in Settings → General. Every release is a normal release; there is no pre-release channel.
- The appcast is served from GitHub Pages; updates are signed with EdDSA and the Developer ID signature.
- Background recording is paused before the update replaces the app and restored afterwards, unless it was off or the Login Items permission was revoked.
- The Homebrew page is now “Homebrew Updates” and only updates apps installed with Homebrew; MacHelper itself uses the button in Settings.

### Dock
- The Dock icon can follow the app’s windows: it disappears when the last window closes and returns when a window is opened from the menu bar. Existing “Show in Dock” settings migrate automatically.
- Always, While a window is open (the new default), and Never modes.

### Mascot
- The slime reacts to taps, double-clicks, hovering, dragging and long presses, and to system events such as high CPU, memory pressure, low disk space, heat, battery, health changes, cleanup and the Helper connection.
- Quiet, Normal and Lively control how often it reacts; Reduce Motion only changes the expression, and VoiceOver describes every reaction.

### Charts
- Menu bar: Heat (a value pill that uses the status color only for warnings) and Dual (network download and upload on one scale).
- Monitor: warning lines for temperature (80/95 °C) and memory (80/95 %), and a “Fill under line” switch for the single-series charts.
- Live charts keep their existing downsampling; hidden windows stop updating their UI.

### Performance
- The overview and monitor pages no longer do UI-only work while the main window is closed or minimized.
- The menu bar only re-renders when its formatted contents change.
- Live series use a fixed-size ring buffer instead of copying the whole history every sample.
- Process sampling resolves each executable path once, and history explicitly uses WAL.

### Fixes
- The main window appears on launch in “While a window is open” mode; “Never” starts without a Dock icon.
- The slime no longer keeps a sustained reaction after its condition ends, and interaction reactions respect the frequency cooldown.
- Localization updated for all six languages.

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
