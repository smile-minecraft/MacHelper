MacHelper adds password-protected **Deep Optimize** for system folders, lets you turn individual
tool modules on or off under **Settings → Features**, introduces the **Neumorphic** (`Soft`) look
and **Soft Clay** theme, and smooths out settings transitions while keeping menu bar CPU usage low.

### Deep Optimize
- Added **Deep Optimize…** below **Start Scan** in **Optimize** to scan and clean system-level
  caches, rotated and compressed logs, diagnostic reports, simulator caches, and week-old temporary
  files that require root privileges.
- All target paths and matching rules are fixed inside the Helper (the app sends only target IDs).
  Scanning and previewing never ask for a password, while deleting prompts for an administrator
  password or Touch ID every time; medium-risk items start unchecked by default.
- Skips symbolic links, hard-linked files, Apple-owned system caches, and items with protected,
  immutable, append-only, data-vault, or SIP flags; never touches APFS or Time Machine snapshots,
  SIP-protected files, or the unified log.
- Requires the updated Helper (protocol v7); when the Helper is missing or outdated, **Deep
  Optimize…** stays disabled and links to **Set Up or Repair the Helper…**.

### Feature Modules
- Added **Settings → Features** with individual switches for all eight tools (**Monitor**, **Health
  Check**, **Fans**, **Optimize**, **Disk Analysis**, **Uninstall**, **Homebrew Updates**, and
  **Startup Items**); **Overview** always remains visible, and every module defaults to on so
  upgrading changes nothing by default.
- Turning a tool off removes it from the sidebar, `⌘1`–`⌘9` menu shortcuts (remaining items keep
  their numbers), the menu bar quick bar, and **Overview** shortcuts; an open hidden page falls
  back to **Overview**.
- Pauses background work for disabled tools while keeping saved settings intact: **Monitor**
  unregisters its background recording agent, **Optimize** pauses scheduled cleanup, **Fans** stops
  polling and returns fans to automatic system control, and **Homebrew Updates** stops update
  checks. Re-enabling **Monitor** or **Optimize** restores saved schedules; **Fans** stays on
  automatic control until switched back.
- Turning off **Fans** (when a manual policy or rules are active) or **Optimize** (when scheduled
  cleanup is on) asks for confirmation first. Simple mode continues to work alongside module
  switches, settings backups include the switches while older backups still import, and **Shortcuts**
  actions for **Optimize** and **Health Check** report when a feature is turned off.

### Neumorphic Theme
- Added the **Soft** shape option, the built-in **Soft Clay** (`builtin.soft`) light and dark
  theme, and the **Neumorphic** preset under **Settings → Appearance**.
- Cards and controls appear raised from the canvas, tracks and wells sit recessed, and buttons
  press from raised to recessed with subtle top-left lighting; in **Soft** shape, **Material** is
  fixed to **Solid** so highlights and shadows stay crisp.

### Motion & Animations
- Fixed option captions and conditional rows in **Settings** cutting in a single frame by keeping
  stable view identity with cross-fade and shared state transitions; with **Reduce Motion** enabled,
  movement drops to a plain fade.
- Audited all animation call sites across the app for **Reduce Motion** compliance and removed
  per-second numeric rolling transitions from menu bar panel readings to avoid extra CPU work.

