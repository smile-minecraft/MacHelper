MacHelper fixes the **Finder automation** permission prompt under Hardened Runtime so clicking
**Continue** reliably asks macOS or opens System Settings, repairs broken **Tweaks** actions across
Finder, Mission Control, window buttons, and app lists, removes page-switch and **Optimize**
transition jitter, and fixes scanning size readouts.

### Permissions & Tweaks
- Added the `com.apple.security.automation.apple-events` entitlement to the app and preserved it
  when release builds re-sign after Sparkle, fixing clicking **Continue** on the **Finder
  automation** explanation sheet doing nothing and unblocking the **New file in Finder** shortcut.
- Updated the Finder automation request flow to launch Finder in the background if it is not
  running, open **Privacy & Security → Automation** when previously denied or when macOS declines to
  prompt, and respect choosing **Don't Allow**.
- Fixed right-clicking a file in Finder and choosing **New File** so the new file is created in the
  window's current folder instead of failing on the selected file path.
- Registered the Finder menu URL handler during launch and queued incoming requests until the tweak
  engine starts, so a Finder menu click that launches MacHelper is no longer dropped.
- Fixed **Mission Control** overlay window buttons ignoring the first click while MacHelper is
  inactive, and widened the traffic light button hit strip from `30 pt` to `56 pt` for taller
  toolbar windows.
- Fixed excluded app-list fields in **Tweaks** eating commas on every keystroke by saving when
  editing ends, sharing parsing rules with the CLI.
- Added direct **Allow Finder Control** and **Turn On Finder Extension** actions next to tweaks that
  require them, and refreshed Finder automation status whenever MacHelper becomes active.

### Interface & Scanning
- Switched full-page state transitions in **Optimize**, **Disk Analysis**, and **Uninstall** to
  remove the previous state immediately without fractional scaling, eliminating the stutter and text
  shimmer when returning to the **Optimize** start screen or switching states.
- Computed page content width during the layout pass instead of one update later, eliminating the
  wide-to-narrow reflow jump during sidebar page switches, and removed a duplicate animation on
  restored **Disk Analysis** scans.
- Replaced `"Zero KB"` and inconsistent size formatting with a unified byte-size formatter showing
  `"0 bytes"`, clamping negative or oversized values, following the system locale's decimal
  separator, and handling non-finite rates safely.
- Fixed **Disk Analysis** rescans keeping the previous scan's totals or jumping backwards from
  overlapping progress polls by owning a single poll per scan and clamping counters monotonically.
- Fixed **Uninstall** briefly showing the previous app's leftovers and selected size when switching
  apps, and prevented stale background plan loads from leaving the spinner stuck.

