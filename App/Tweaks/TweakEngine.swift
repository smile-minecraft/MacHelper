import AppKit
import CoreGraphics
import Foundation
import Tweaks

/// Owns the lifecycle of every implemented tweak. It reads settings from the shared file, decides
/// which behaviours need to run, keeps one event tap for the keyboard/mouse tweaks and publishes
/// the status file the CLI reads.
@MainActor
final class TweakEngine {
    static let shared = TweakEngine()

    private let store = TweakStore()
    private var settings = TweakSettings()
    private var granted = false
    private var frontmostBundleID: String?
    private var eventTap: EventTapService?
    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?

    private let music = MusicLaunchBehavior()
    private let cmdTab = CmdTabRestoreBehavior()
    private let quitGuard = QuitGuardBehavior()
    private let dockClick = DockClickBehavior()
    private let finderCutPaste = FinderCutPasteBehavior()
    private let finderNewFile = FinderNewFileBehavior()

    /// Only the event types an enabled behaviour looks at reach the tap: with just the quit guard
    /// on, mouse events never pass through MacHelper at all.
    private static func eventMask(keys: Bool, clicks: Bool) -> CGEventMask {
        func bit(_ t: CGEventType) -> CGEventMask { CGEventMask(1) << CGEventMask(t.rawValue) }
        var mask: CGEventMask = 0
        if keys { mask |= bit(.keyDown) | bit(.keyUp) | bit(.flagsChanged) }
        if clicks { mask |= bit(.leftMouseDown) | bit(.leftMouseUp) }
        return mask
    }

    func start() {
        guard observers.isEmpty else { return }
        settings = store.load()
        granted = AccessibilityAuthority.isGranted
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // The extension's menu items arrive as URLs; the handler exists exactly while the tweak
        // engine runs, so a snapshot or measurement instance never answers one.
        FinderMenuChannel.shared.install()

        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(TweakStore.changeNotification), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.apply() } })
        for name in ["com.apple.accessibility.api", "com.apple.accessibility.API"] {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.apply(force: true) } })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.music.handleLaunch(app) }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock" else { return }
            let pid = app.processIdentifier
            Task { @MainActor in self?.dockClick.updateDock(pid: pid) }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.applicationActivated(app) }
        })
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
        apply(force: true)
    }

    static func requestAccessibility() {
        _ = AccessibilityAuthority.requestPrompt()
        Task { @MainActor in shared.apply(force: true) }
    }

    private func applicationActivated(_ app: NSRunningApplication) {
        frontmostBundleID = app.bundleIdentifier
        quitGuard.updateFrontmost(frontmostBundleID, pid: app.processIdentifier)
        dockClick.updateFrontmost(app)
        cmdTab.handleActivation(app)
        finderCutPaste.updateFrontmost(app)
        finderNewFile.updateFrontmost(app)
    }

    private func apply(force: Bool = false) {
        let latest = store.load()
        let nowGranted = AccessibilityAuthority.isGranted
        if !force, latest == settings, nowGranted == granted { return }
        settings = latest
        granted = nowGranted

        let quitEnabled = latest.isEnabled(.inputQuitGuard)
        let dockEnabled = latest.isEnabled(.dockClickAction)
        let cutPasteEnabled = latest.isEnabled(.finderCutPaste)
        let newFileEnabled = latest.isEnabled(.finderNewFile)
        let frontmost = NSWorkspace.shared.frontmostApplication
        // Configure the behaviours before the tap can deliver anything to them.
        music.configure(enabled: latest.isEnabled(.musicBlockAutolaunch), settings: latest)
        cmdTab.configure(enabled: granted && latest.isEnabled(.windowCmdTabRestore))
        quitGuard.configure(enabled: quitEnabled, settings: latest, frontmostBundleID: frontmostBundleID)
        dockClick.configure(enabled: dockEnabled, settings: latest, frontmost: frontmost)
        finderCutPaste.configure(enabled: cutPasteEnabled, frontmost: frontmost)
        finderNewFile.configure(enabled: newFileEnabled, settings: latest, frontmost: frontmost)

        let wantsKeys = quitEnabled || cutPasteEnabled || newFileEnabled
        if granted && (wantsKeys || dockEnabled) {
            if eventTap == nil {
                // Runs on the tap's own thread: the behaviours are thread-safe and never wait on
                // the main actor.
                let quitGuard = quitGuard, dockClick = dockClick
                let finderCutPaste = finderCutPaste, finderNewFile = finderNewFile
                eventTap = EventTapService { type, event in
                    quitGuard.handle(type, event)
                        ?? finderCutPaste.handle(type, event)
                        ?? finderNewFile.handle(type, event)
                        ?? dockClick.handle(type, event)
                        ?? .pass
                }
            }
            eventTap?.install(mask: Self.eventMask(keys: wantsKeys, clicks: dockEnabled))
        } else {
            eventTap?.remove()
            eventTap = nil
            quitGuard.reset()
            finderCutPaste.reset()
        }
        publishStatus()
    }

    /// The extension's Cut item: from here on the next ⌘V in Finder moves what is on the clipboard.
    func armFinderCut(changeCount: Int) { finderCutPaste.armCut(changeCount: changeCount) }

    private func publishStatus() {
        let automation = FinderAutomation.permission
        let extensionEnabled = FinderExtensionStatus.isEnabled()
        var states: [String: TweakRuntimeStatus.TweakState] = [:]
        for definition in TweakCatalog.all {
            let enabled = settings.isEnabled(definition.id)
            if !definition.implemented {
                states[definition.id.rawValue] = .unavailable(definition.unavailableReason ?? "Coming soon")
            } else if !enabled {
                states[definition.id.rawValue] = .off
            } else if definition.permissions.contains(.accessibility) && !granted {
                states[definition.id.rawValue] = .needsPermission
            } else if definition.id == .finderNewFile && automation == .denied {
                states[definition.id.rawValue] = .needsPermission(
                    "Allow MacHelper to control Finder in System Settings › Privacy & Security › Automation")
            } else if definition.id == .finderContextMenu && extensionEnabled == false {
                states[definition.id.rawValue] = .needsPermission(
                    "Enable the MacHelper Finder extension in System Settings › General › Login Items & Extensions")
            } else {
                states[definition.id.rawValue] = .active
            }
        }
        let status = TweakRuntimeStatus(
            appPID: Int32(ProcessInfo.processInfo.processIdentifier),
            accessibilityGranted: granted,
            eventTapInstalled: eventTap?.isInstalled ?? false,
            automationFinderGranted: automation == .granted,
            finderExtensionEnabled: extensionEnabled,
            tweaks: states)
        try? status.write(to: store.statusURL)
    }
}
