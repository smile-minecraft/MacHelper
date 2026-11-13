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

