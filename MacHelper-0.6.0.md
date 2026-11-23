MacHelper adds the read-only **Cable** page for USB-C port specs, charging diagnostics, and
connected devices, introduces the **Tweaks** page for Finder, Dock, window, shortcut, and Mission
Control controls alongside matching CLI commands, and updates **Deep Optimize** so administrator
authentication runs before anything is deleted.

### Cable
- Added **Cable** (`⌘U`) under **This Mac** as a read-only view that needs no Helper; can be
  switched off in **Settings → Features**.
- Shows decoded e-marker ratings for every USB-C and Thunderbolt port: data rate, max current,
  negotiable voltage, **EPR** support, **Active cable** or **Passive cable** type, and latency.
- Diagnoses slow charging and link bottlenecks: underpowered adapters, 3 A or missing-e-marker
  cables capping charging at 60 W, macOS `NotChargingReason` pauses, power shared through a hub or
  display, battery overheating, and USB 3 devices running at USB 2.0 speed.
- Lists Thunderbolt/USB4 devices, the **USB Device Tree** (with hubs and negotiated link speeds),
  and **Displays** (with resolution, refresh rate, and link rate).
- Added `machelper cable` (`status`, `ports`, `devices`, `displays`, and `charging`, each supporting
  `--json`).

### Tweaks
- Added **Tweaks** (`⌘T`) with toggles and options saved to `tweaks.json` (on by default in
  **Settings → Features**), plus `machelper tweaks list|status|enable|disable|set|reset` (with
  `--json`). Most tweaks require Accessibility permission.
- **Finder**: **Cut and paste files in Finder** moves files with `⌘X` / `⌘V` while leaving text
  fields untouched and only arming when items are selected. **New file in Finder** (`⌃⌥N` by
  default, customizable; requires Finder automation) creates files from **Plain text**,
  **Markdown**, **Rich text**, or **Custom extension** templates, adds a sequence number on name
  conflicts, and enters rename immediately. **Finder context menu items** (requires enabling
  MacHelper's Finder extension in System Settings) adds **New File** (with template choices),
  **Copy Path**, **Open in Terminal**, and **Cut** to Finder's right-click menu. **Fit Finder
  column widths** appears as unavailable because Finder does not let Accessibility set column
  widths.
- **Dock & Media**: **Dock icon click action** lets a click on the foreground app's Dock icon
  **Hide app**, **Minimize windows**, or **Cycle windows**. **Block Music auto-launch** closes
  Music as soon as it starts, with an optional replacement app bundle ID.
- **Windows & Shortcuts**: **Traffic light buttons** customizes the close (**Quit app on the last
  window**), minimize (**Hide app**), and zoom (**Fill the screen** without entering full screen,
  or **System zoom**) buttons; holding `⌥` keeps standard macOS behavior, and excluded apps can be
  listed by bundle ID. **Restore minimized windows on ⌘Tab** brings back the last minimized window
  when switching to an app with no visible windows. **Quit shortcut guard** requires holding or
  double-pressing `⌘Q` (and optionally `⌘W`) before closing, with per-app exclusions.
- **Window Management**: **Window list in the menu bar** groups open and minimized windows by app
  with per-window **Show**, **Minimize** / **Restore**, and **Close** actions, per-app **Hide** /
  **Quit** actions, and an optional global shortcut. **Window buttons in Mission Control** adds
  close and minimize buttons to Mission Control thumbnails.
- Added `machelper windows list|focus|minimize|restore|close` (supporting `--json`).

### Deep Optimize
- Clicking **Authorize and Clean…** in **Optimize** now prompts for an administrator password or
  Touch ID before deleting anything; cancelling stops the entire run so no regular items are
  removed either.
- Added **Deep Clean Only…** in the preview action bar when both deep targets and regular items
  are selected, letting you run only the administrator cleanup.

