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

