MacHelper now moves smoothly: pages and their states fade in instead of cutting over, and on
macOS 26 the controls that float above content use Liquid Glass. Each section of the menu bar
panel sits on its own glass card, the Battery page is redesigned, and with the CPU page open the
panel uses about a fifth of the CPU it did before. Settings explain the Helper in plain words, and
building from source starts with `make setup`.

### Interface
- Switching pages, and moving between a page's states (start, scanning, results), now fades the
  new content in instead of cutting to it. Tab and filter highlights slide to the new choice, and
  the menu bar panel fades in and out. With Reduce Motion, nothing moves; only fades remain.
- On macOS 26 and later, the smooth style uses Liquid Glass for controls that float above content:
  the action bars under lists, tab highlights, header buttons and the main action button. In the
  menu bar panel, each section (gauges, history, cores, details, processes) sits on its own glass
  card. The pixel style and older systems keep their look.
- The menu bar Battery page is redesigned: a drawn battery with the charge in large type and the
  power state, tiles for health, cycle count, temperature and power, the charge history, and
  accessory rows with their own icons and earbud and case levels.

### Performance
- The menu bar panel no longer animates gauges between readings that arrive every second. With
  the CPU or GPU page open, MacHelper used about 40 % of a CPU core and now uses about 8 %; the
  Memory page dropped from about 23 % to 8 % (Release build, 30-second average).
- The Helper's status is asked of macOS at most once a second instead of on every redraw.

### Settings
- The Helper tab says what the Helper is for, shows its status in plain words and offers the one
  next step (set it up, open Login Items or turn it off). The developer tools moved under
  Diagnostics.
- Alerts put each switch on its own row with its threshold below.
- General keeps Check for Updates next to the version, and the background recording and data
  management explanations are shorter.
- The Fans page shows the Helper's status in the interface language.

### Building
- `make setup`, `make open`, `make run` and `make test` cover day-to-day development without
  touching the installed app; `make install` replaces it. Building needs Xcode 26 or later.
- `make run ARGS=--demo-battery` previews the Battery page with simulated readings on a Mac
  without a battery (Debug builds only; nothing is written to the history).

