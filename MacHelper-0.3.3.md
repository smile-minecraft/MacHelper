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

