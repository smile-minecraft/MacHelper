The menu bar Battery page now shows the charge of connected accessories alongside the internal
battery, and the panel's pages can be reordered and switched off. Disk analysis combines filters
in its largest-files list, explains how its scan total relates to the volume's used space and
lists local snapshots. The SSD page shows which apps are reading and writing the disk. Clean gains
rules for Claude Code, Codex and OpenCode, and Auto Clean can run every 30 minutes and clean
expired temporary files.

### Battery
- Connected accessories appear below the internal battery: Bluetooth devices such as a Magic
  Keyboard, Mouse, Trackpad or AirPods, devices that report their charge over USB, and Logitech
  devices behind their wireless receiver. Each row shows the charge with a bar and a charging
  mark, AirPods add the left bud, right bud and charging case, and the accessory with the least
  charge comes first.
- Wired and receiver devices are queried in the background through the battery protocols they
  already speak; nothing is paired or installed, and no input is intercepted.

### Menu bar
- Settings → Menu Bar now lists every panel page with a toggle and up/down buttons, so you choose
  which pages appear and in what order. The last visible page can't be switched off, and a page
  whose hardware this Mac doesn't have stays hidden on its own.

### Disk analysis
- The largest-files list combines filters: a search over the file's name or its full path, a
  minimum size, a kind (video, image, audio, archive, disk image, application, document,
  developer, other) and an age such as unchanged for 90 days. Every set condition must hold; Clear
  Filters returns the full list.
- A full-volume scan now breaks down its total: how much of the space the volume reports as
  used the scan measured, and that the rest is system data or space shared with other APFS
  volumes, not space you can clean. When the scan counted more than the volume reports, the note
  says files changed while it ran; a scan of one folder says its total can't be compared with the
  whole volume's usage.
- Local APFS and Time Machine snapshots are listed with their dates. They share space with the
  volume and macOS manages them, so the list is read-only: no size is invented and nothing is
  offered for deletion.

### SSD
- A new "Disk I/O by app" section ranks apps by the reading and writing the kernel attributes to
  their processes, with each app's rates and its share; the busiest six rows are listed and the
  rest are summed into one. The figures are process counters, not physical disk throughput, and
  the section says so. Processes this user may not inspect are left out and counted in a footnote
  instead of shown as zero, and sampling runs only while the SSD page is open.

### Clean
- New rules cover Claude Code, Codex and OpenCode. Their low-risk files (caches, logs older than
  a week and temporary files) are cleaned by default. Session history from each agent (Claude
  Code transcripts, Codex sessions and OpenCode tool output) is only offered, never preselected,
  and moves to the Trash after a month. The rules do not touch any agent's own program, installed
  plugins, settings or credentials. Every agent rule pauses while the agent itself is running,
  checked freshly before each removal, and a file that changed after the preview, for example from
  a resumed session, is left in place. The rule text is translated into all six languages.

### Auto Clean
- New frequencies: every 30 minutes, hourly and every 3 hours, alongside daily and weekly. The
  background agent now checks every 30 minutes and runs only when your frequency is due. Existing
  schedules migrate to it automatically; a migration that is interrupted or fails is retried on
  the next refresh, and a failure is reported with a Retry button.
- "Clean expired temporary files" is off by default. With it on, entries in your temporary folder
  that are at least seven days old, unchanged and not in use are removed after each scheduled
  clean, either to the Trash or deleted outright depending on your "Move to the Trash instead of
  deleting" setting. Entries the system manages itself, and anything in use or still being written,
  are skipped.

### Documentation
- Every README now opens with a plain definition and adds a section for AI agents and an FAQ; the
  repository adds llms.txt and CITATION.cff.

### Languages
- New text is translated into all six languages.

