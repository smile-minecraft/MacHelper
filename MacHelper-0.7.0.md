MacHelper adds Universal support for Intel (`x86_64`) Macs alongside Apple Silicon, refines the
**Soft** (neumorphic) theme and **Optimize** navigation with smoother loading, fixes swapped M1 Pro
and M1 Max adapter wattages in **Cable**, and detects Accessibility grants made while the app is
running.

### Universal Mac Support
- MacHelper now builds as a Universal app running natively on Intel (`x86_64`) Macs as well as
  Apple Silicon on macOS 14 or later, and the Homebrew cask no longer requires `arm64`.
- On Intel Macs, temperature readings and fan control use SMC, total system power is read from SMC
  (the Apple-Silicon-only power breakdown is unavailable), `machelper status` and `machelper report`
  include SMC temperatures, dual-GPU Macs report the busiest active GPU, fan control uses tighter
  safety limits (95 °C / 88 °C), and **Cable** includes recommended adapter wattages for Intel
  MacBook Pro and MacBook Air models.
- Intel support has not yet been tested on a physical Intel Mac; if you run into hardware-specific
  issues on Intel, please report them.

### Interface & Optimize
- In the **Soft** (neumorphic) theme, added top padding inside the menu bar panel so the first
  card's top-left highlight is no longer clipped under the tab bar, toned down dark-mode highlights
  and shadows, and widened gaps between narrow fan and power cards.
- On the **Optimize** start screen, **Start Scan** and **Deep Optimize…** now sit side by side at
  equal height; a new **Back to Menu** button in the **Optimize** toolbar and preview/results action
  bars lets you switch between standard and deep optimization without rescanning first.
- Scans start faster and the scanning animation stays smooth during progress updates by moving
  pre-scan checks off the main thread and running the system cleanup preview alongside the rule
  scan.

### Cable
- Fixed swapped recommended adapter wattages for 14-inch and 16-inch M1 Pro and M1 Max MacBook Pro
  models (16-inch is now 140 W and 14-inch is 67 W), so stock 67 W adapters no longer trigger false
  underpowered warnings.

### Tweaks
- Granting Accessibility permission while MacHelper is running is now detected by checking after the
  system notification, when MacHelper becomes active, and every 10 seconds. When macOS needs a
  relaunch to apply the grant, **Tweaks** shows **Restart required** with a **Restart MacHelper**
  button, and `machelper tweaks status` reports `accessibilityRestartRequired`.
- On macOS 27 and later, the grant button and CLI messages name System Settings' renamed **Device
  Control and Data Access** list instead of **Accessibility**.
- Relaunches after changing **Language** or **Import Settings** now wait for MacHelper to quit
  before reopening.

