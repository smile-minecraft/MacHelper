MacHelper refines surfaces and legibility across Light Mode and Liquid Glass, replaces the separate
first-launch sheets with a single Welcome Guide, and hardens the Helper across Sparkle and manual
DMG updates. AI agents gain a one-shot redacted diagnostic report (`machelper report`), and
opt-in anonymous diagnostics and developer profiling arrive with privacy built in.

### Themes & Surface Materials
- Unified **Appearance** (`System` / `Light` / `Dark`) and **Material** (`Solid` / `Frosted`, now
  the default / `Liquid Glass`) under **Settings → Appearance**, with automatic accessibility
  fallbacks (Reduce Transparency uses Solid; Liquid Glass falls back to Frosted on older macOS
  versions, in Pixel style, or with Increase Contrast).
- Fixed Light Mode Liquid Glass readability in the menu bar panel: selected tab pills, the Quit
  button, cards, chips, icon buttons, chart axes, faint labels (4.5:1 contrast), and untinted text
  now stay legible over both light and dark wallpapers instead of washing out or mixing text inks.
- Added semantic contrast tokens across surfaces and a contrast safety net for custom and imported
  VS Code themes, leaving built-in themes unchanged.
- Redesigned **Settings → Appearance** with Light/Dark/System and Material pickers, fallback notes,
  and theme cards displaying light/dark previews, polarity, and contrast audit status.

### Welcome Guide
- Replaced the three separate first-launch sheets (Full Disk Access, Helper, and agent skill) with
  a unified 6-step interactive **Welcome Guide** covering preferences, a menu bar tour, optional
  permissions, and AI agent skills.
- Replayable anytime from **Help → Welcome Guide…**; existing users who completed any prior
  onboarding sheet are not prompted again on upgrade.

### Helper Reliability & Recovery
- Added seamless Sparkle update handoff and manual DMG update detection so Helper state survives
  app replacement.
- Replaced registration-only checks with verified live XPC liveness monitoring and automatic,
  non-destructive recovery for safe failures.
- Added a clear in-app warning banner with one-click **Repair Helper** and **Open Login Items**
  actions, accurate sidebar status indicators, and deduplicated local notifications when the
  Helper needs attention.

### AI Agent CLI
- Added `machelper report` (`--json` / `--format markdown`) to generate a redacted whole-Mac
  diagnostic report in one call, automatically scrubbing usernames, home paths, hostnames, IP and
  MAC addresses, and external volume names.
- Added structured `suggestedActions` and `availableTools` to JSON reports, `machelper guide
  --json`, and upgraded the built-in Agent Skill to v3.

### Privacy & Performance
- Added optional anonymous usage counts and coarse performance diagnostics, **off by default** under
  **Settings → General → Privacy & Diagnostics**, with zero PII or file paths, a live JSON sample
  payload preview, and immediate erasure of the anonymous ID and pending queue when turned off.
- Added native `OSSignposter` instrumentation on hot paths and `scripts/perf/xctrace-profile.sh`
  for developer performance profiling.

### Documentation & Website
- Revamped the READMEs in all six languages, replaced README screenshots with synthetic demo data
  via `make screenshots`, and redesigned the GitHub Pages site.

