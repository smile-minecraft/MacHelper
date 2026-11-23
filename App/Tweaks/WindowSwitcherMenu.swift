import AppKit
import Foundation
import Tweaks

/// A menu bar item that lists every app's windows, minimized ones included, and acts on them. The
/// list is what Accessibility reports, which for most apps is the current desktop only.
///
/// Nothing is read from other apps until the menu opens: `menuNeedsUpdate` asks the accessibility API
/// for the window list, builds the menu, and the menu is thrown away when it closes. A status item
/// only exists while the tweak is on.
@MainActor
final class WindowSwitcherMenu: NSObject, NSMenuDelegate {
    private struct State: Equatable {
        var enabled = false
        var showIcons = true
        var shortcut = ""
    }

    private var state = State()
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private let hotKey = GlobalHotKey()
    private var hotKeyFailed = false

    /// Set MACHELPER_TWEAKS_TRACE=1 to see the status item and the menu on stderr.
    private static let trace = ProcessInfo.processInfo.environment["MACHELPER_TWEAKS_TRACE"] != nil

    private func log(_ message: String) {
        guard Self.trace else { return }
        FileHandle.standardError.write(Data("switcher: \(message)\n".utf8))
    }

    func configure(enabled: Bool, settings: TweakSettings) {
        let next = State(enabled: enabled,
                         showIcons: settings.bool("showIcons", for: .windowSwitcherMenu),
                         shortcut: settings.string("hotkey", for: .windowSwitcherMenu))
        guard next != state else { return }
        state = next
        tearDown()
        guard enabled else { return }
        setUpStatusItem()
        registerHotKey()
    }

    /// A note for the status file and the CLI when macOS refused the configured shortcut.
    var hotKeyProblem: String? {
        guard state.enabled else { return nil }
        return HotKeyShortcut.statusReason(for: state.shortcut, refused: hotKeyFailed)
    }

    // MARK: - Installation

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                accessibilityDescription: String(localized: "Window List"))
            image?.isTemplate = true
            button.image = image
            button.toolTip = String(localized: "Window List")
        }
        let menu = NSMenu(title: String(localized: "Window List"))
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        self.menu = menu
        log("status item installed")
    }

    private func tearDown() {
        hotKey.unregister()
        hotKeyFailed = false
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        menu = nil
    }

    private func registerHotKey() {
        guard !state.shortcut.isEmpty, let shortcut = HotKeyShortcut.parse(state.shortcut) else { return }
        hotKeyFailed = !hotKey.register(shortcut) { [weak self] in self?.openMenu() }
        log(hotKeyFailed ? "shortcut \(state.shortcut) was refused" : "shortcut \(shortcut) registered")
    }

    /// Opens the menu from the global shortcut, as though the status item was clicked.
    private func openMenu() {
        guard let button = statusItem?.button else { return }
        button.performClick(nil)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        log("menu opened")
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let apps = WindowCatalog.applications()
        let snapshots = WindowCatalog.snapshots()
        let groups = WindowCatalog.groups(snapshots, apps: apps)
        guard !groups.isEmpty else {
            let empty = NSMenuItem(title: String(localized: "No Open Windows"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        // Rebuilt on every open, so the list is always current without a Refresh item.
        for group in groups {
            menu.addItem(appItem(for: group))
        }
    }

    private func appItem(for group: WindowCatalog.AppGroup) -> NSMenuItem {
        let name = group.app.localizedName ?? ""
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        if state.showIcons { item.image = group.app.icon }
        let appMenu = NSMenu(title: name)
        appMenu.autoenablesItems = false
        for window in group.windows {
            appMenu.addItem(windowItem(for: window))
        }
        appMenu.addItem(.separator())
        appMenu.addItem(appAction(String(localized: "Hide \(name)"), #selector(hideApp(_:)), pid: group.id))
        appMenu.addItem(appAction(String(localized: "Quit \(name)"), #selector(quitApp(_:)), pid: group.id))
        item.submenu = appMenu
        return item
    }

    private func windowItem(for window: WindowSnapshot) -> NSMenuItem {
        let title = window.title.isEmpty ? String(localized: "Untitled Window") : window.title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: title)
        windowMenu.autoenablesItems = false
        windowMenu.addItem(windowAction(String(localized: "Show"), #selector(showWindow(_:)), window: window))
        let toggle = window.minimized ? String(localized: "Restore") : String(localized: "Minimize")
        windowMenu.addItem(windowAction(toggle, #selector(toggleWindowMinimize(_:)), window: window))
        windowMenu.addItem(windowAction(String(localized: "Close"), #selector(closeWindow(_:)), window: window))
        item.submenu = windowMenu
        return item
    }

    private func windowAction(_ title: String, _ selector: Selector, window: WindowSnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = window.id.description
        return item
    }

    private func appAction(_ title: String, _ selector: Selector, pid: pid_t) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = NSNumber(value: pid)
        return item
    }

    // MARK: - Debug aid

    /// What the menu would list, as plain lines. `--dump-window-menu` prints this so the menu's
    /// contents can be checked without opening it (and without a pointer).
    static func menuDescription() -> [String] {
        let groups = WindowCatalog.groups(WindowCatalog.snapshots(), apps: WindowCatalog.applications())
        guard !groups.isEmpty else { return ["(no windows)"] }
        var lines: [String] = []
        for group in groups {
            lines.append("\(group.app.localizedName ?? "") [pid \(group.id)] \(group.windows.count) window(s)")
            for window in group.windows {
                let state = window.minimized ? "minimized" : (window.visible ? "visible" : "hidden")
                let title = window.title.isEmpty ? "(untitled)" : window.title
                lines.append("  \(window.id) \(state) \(title)")
            }
        }
        return lines
    }

    // MARK: - Actions

    @objc private func showWindow(_ sender: NSMenuItem) {
        guard let identity = Self.identity(of: sender) else { return }
        AccessibilityWindows.perform(.focus, on: identity)
    }

    @objc private func toggleWindowMinimize(_ sender: NSMenuItem) {
        guard let identity = Self.identity(of: sender),
              let window = AccessibilityWindows.resolve(identity) else { return }
        AccessibilityWindows.setMinimized(window, !AccessibilityWindows.isMinimized(window))
    }

    @objc private func closeWindow(_ sender: NSMenuItem) {
        guard let identity = Self.identity(of: sender) else { return }
        AccessibilityWindows.perform(.close, on: identity)
    }

    @objc private func hideApp(_ sender: NSMenuItem) {
        guard let pid = Self.pid(of: sender) else { return }
        NSRunningApplication(processIdentifier: pid)?.hide()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        guard let pid = Self.pid(of: sender) else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    private static func identity(of item: NSMenuItem) -> WindowIdentity? {
        (item.representedObject as? String).flatMap(WindowIdentity.init)
    }

    private static func pid(of item: NSMenuItem) -> pid_t? {
        (item.representedObject as? NSNumber).map { pid_t($0.int32Value) }
    }
}
