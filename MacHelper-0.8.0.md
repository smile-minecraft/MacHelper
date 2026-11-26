MacHelper adds a **Permissions** tab in Settings with pre-prompt explanations and a floating System
Settings guide, lets you hide the menu bar icon and navigate from a Dock menu, adds an **Actions**
menu and a customizable window toolbar with `⌘F` search, shrinks the main window down to half a
screen (`720 × 520`), and supports `Delete` and drag-and-drop `.app` selection in **Uninstall**
and **Startup Items**.

### Permissions
- Added **Settings → Permissions**, grouping permissions by whether your current setup needs them,
  optional, or not needed right now, with each item's live status, what it is **Used by**, what
  stops working **Without it**, what is **Never accessed**, and a one-click action button.
- Added pre-prompt explanation sheets before macOS asks for Helper installation, **Accessibility**,
  **Finder automation**, or **Notifications**, showing what macOS will display next before
  continuing.
- Added a non-activating floating guide beside System Settings when a manual switch or approval is
  needed (including a draggable MacHelper icon for **Full Disk Access**), closing automatically once
  the grant is detected or when you return to MacHelper.
- Unified permission entry points across the **Welcome Guide** (starting with the Helper step), the
  Helper warning banner, sidebar Helper status, **Optimize**, **Disk Analysis**, **Tweaks**,
  **Alerts**, **Background recording**, **Auto Clean**, and **Settings → Helper**; background tasks
  whose feature is on without an active agent offer **Set Up Again**, and denied notifications offer
  **Open Notification Settings**.
- Updated the **Full Disk Access** privacy note to clarify that file contents are read locally on
  this Mac only when searching for duplicates or previewing a file, and included five-language
  translations (`es`, `ja`, `ko`, `zh-Hans`, `zh-Hant`) for all permission descriptions and guides.

### Dock & Menu Bar
- Added a Dock icon menu with quick access to visible main pages (**Overview**, **Monitor**,
  **Optimize**, **Disk Analysis**, **Uninstall**) and **Settings…**.
- Added **Show MacHelper in the menu bar** at the top of **Settings → Menu Bar**. Switching it off
  hides the menu bar item and closes any open panel while keeping the Dock icon visible (disabling
  the **Dock icon** options that hide it in **Settings → General**) so the app stays reachable;
  settings backups preserve this preference.
- Fixed clicking the menu bar icon while another app is in full-screen mode so the panel opens on
  that Space instead of an off-screen Space.

### Menus, Toolbar & Window
- Added the **Actions** menu between **View** and **Window** for the current page's primary action
  and refresh command (`⌘R`), keeping fixed menu slots across pages.
- Made the window toolbar customizable (**View → Customize Toolbar…**), added **Show Toolbar** and
  **Show Sidebar** to **View**, moved page refresh and **Optimize** actions into the toolbar, and
  moved search fields in **Optimize**, **Disk Analysis** (**Largest Files**), **Uninstall**
  (**Apps**), and **Startup Items** into the toolbar with **Edit → Find…** (`⌘F`) focus.
- Removed the duplicate **Make Interface Bigger** item from **View**; `⌘=` remains in the menu
  while `⌘+` also works with Caps Lock on or from the numeric keypad.
- Reduced the main window minimum size from `980 × 640` to `720 × 520` (half of a 13-inch MacBook
  Air screen) and added narrow layouts across **Overview**, **Monitor**, **Health Check**,
  **Cable**, **Optimize**, **Disk Analysis**, **Uninstall**, and **Startup Items**, with scrolling
  empty states so buttons stay accessible.
- Fixed **Disk Analysis** overflowing a half-screen window when showing a saved scan, and floated
  the Helper warning banner over the detail area so it no longer pushes layouts off-screen while
  VoiceOver continues reading it first.

### Uninstall & Startup Items
- Pressing **Delete** on a selected app or checked leftover item in **Uninstall**, or on a removable
  user agent or switchable system daemon in **Startup Items**, opens the same confirmation dialog as
  its button under the same conditions.
- Dragging a `.app` bundle from Finder onto **Uninstall** switches to **Apps** and selects the
  matching installed app (even when dragging a copy from another location such as a DMG or
  Downloads); apps not installed in an Applications folder are rejected with an inline explanation.

