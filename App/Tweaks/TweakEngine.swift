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
    /// A new process sees the grant although this one does not (see `AccessibilityGrant`).
    private var grantedInFreshProcess = false
    private var probingGrant = false
    private var frontmostBundleID: String?
    private var eventTap: EventTapService?
    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?
    /// Finder automation and extension state change only in System Settings, so they are read in
    /// the background every few seconds while a Finder tweak needs them, never on the main thread
    /// (the extension check runs pluginkit).
    private var automation: FinderAutomation.Permission = .unavailable
    private var extensionEnabled: Bool?
    private var pollTick = 0
    private var refreshingFinderStatus = false
    /// Polls that read System Settings state (Finder automation, the extension, the Accessibility
    /// grant through a new process) run every this many one-second ticks.
    private static let slowCheckEvery = 10

    private let music = MusicLaunchBehavior()
    private let cmdTab = CmdTabRestoreBehavior()
    private let quitGuard = QuitGuardBehavior()
    private let dockClick = DockClickBehavior()
    private let finderCutPaste = FinderCutPasteBehavior()
    private let finderNewFile = FinderNewFileBehavior()
    private let trafficLights = TrafficLightBehavior()
    private let switcher = WindowSwitcherMenu()
    private let missionControl = MissionControlOverlay()

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
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.apply(force: true)
                    // The notification can arrive before the new grant is readable.
                    try? await Task.sleep(for: .seconds(1))
                    self?.refreshFreshGrant()
                }
            })
        }
        // Coming back from System Settings is when a grant has most likely just been made.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refreshFreshGrant() } })
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
            Task { @MainActor in
                self?.apply()
                self?.slowChecksIfDue()
            }
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
        if granted { grantedInFreshProcess = false }

        let quitEnabled = latest.isEnabled(.inputQuitGuard)
        let dockEnabled = latest.isEnabled(.dockClickAction)
        let trafficEnabled = latest.isEnabled(.windowTrafficLights)
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
        trafficLights.configure(enabled: granted && trafficEnabled, settings: latest,
                                ownBundleID: Bundle.main.bundleIdentifier ?? "com.machelper.MacHelper")

        let wantsKeys = quitEnabled || cutPasteEnabled || newFileEnabled
        let wantsClicks = dockEnabled || trafficEnabled
        if granted && (wantsKeys || wantsClicks) {
            if eventTap == nil {
                // Runs on the tap's own thread: the behaviours are thread-safe and never wait on
                // the main actor.
                let quitGuard = quitGuard, dockClick = dockClick, trafficLights = trafficLights
                let finderCutPaste = finderCutPaste, finderNewFile = finderNewFile
                eventTap = EventTapService { type, event in
                    trafficLights.handle(type, event)
                        ?? quitGuard.handle(type, event)
                        ?? finderCutPaste.handle(type, event)
                        ?? finderNewFile.handle(type, event)
                        ?? dockClick.handle(type, event)
                        ?? .pass
                }
            }
            eventTap?.install(mask: Self.eventMask(keys: wantsKeys, clicks: wantsClicks))
        } else {
            eventTap?.remove()
            eventTap = nil
            quitGuard.reset()
            trafficLights.reset()
            finderCutPaste.reset()
        }
        // These two own what they show (a status item, overlay panels) and only exist while their
        // tweak is on and Accessibility is granted.
        switcher.configure(enabled: granted && latest.isEnabled(.windowSwitcherMenu), settings: latest)
        missionControl.configure(enabled: granted && latest.isEnabled(.missionControlWindowButtons), settings: latest)
        publishStatus()
        // A tweak that was just turned on reports its permission without waiting a cycle.
        if needsFinderStatus { refreshFinderStatus() }
        refreshFreshGrant()
    }

    private var needsAccessibility: Bool {
        TweakCatalog.all.contains {
            $0.implemented && $0.permissions.contains(.accessibility) && settings.isEnabled($0.id)
        }
    }

    private var accessibilityGrant: AccessibilityGrant {
        AccessibilityGrant(inProcess: granted, freshProcess: grantedInFreshProcess)
    }

    /// Only runs while a tweak waits for Accessibility, since each check starts a process.
    private func refreshFreshGrant() {
        guard !granted, needsAccessibility, !probingGrant else { return }
        probingGrant = true
        Task { [weak self] in
            let fresh = await AccessibilityAuthority.isGrantedInFreshProcess()
            guard let self else { return }
            probingGrant = false
            guard !granted, fresh != grantedInFreshProcess else { return }
            grantedInFreshProcess = fresh
            publishStatus()
        }
    }

    private var needsFinderStatus: Bool {
        settings.isEnabled(.finderNewFile) || settings.isEnabled(.finderContextMenu)
    }

    private func slowChecksIfDue() {
        pollTick += 1
        guard pollTick % Self.slowCheckEvery == 0 else { return }
        if needsFinderStatus { refreshFinderStatus() }
        refreshFreshGrant()
    }

    private func refreshFinderStatus() {
        guard !refreshingFinderStatus else { return }
        refreshingFinderStatus = true
        Task { [weak self] in
            let (automation, extensionEnabled) = await Task.detached(priority: .utility) {
                (FinderAutomation.permission, FinderExtensionStatus.isEnabled())
            }.value
            guard let self else { return }
            refreshingFinderStatus = false
            guard automation != self.automation || extensionEnabled != self.extensionEnabled else { return }
            self.automation = automation
            self.extensionEnabled = extensionEnabled
            publishStatus()
        }
    }

    /// The extension's Cut item: from here on the next ⌘V in Finder moves what is on the clipboard.
    func armFinderCut(changeCount: Int) { finderCutPaste.armCut(changeCount: changeCount) }

    private func publishStatus() {
        var states: [String: TweakRuntimeStatus.TweakState] = [:]
        for definition in TweakCatalog.all {
            let enabled = settings.isEnabled(definition.id)
            if !definition.implemented {
                states[definition.id.rawValue] = .unavailable(definition.unavailableReason ?? "Coming soon")
            } else if !enabled {
                states[definition.id.rawValue] = .off
            } else if definition.permissions.contains(.accessibility) && !granted {
                states[definition.id.rawValue] = accessibilityGrant == .restartRequired
                    ? .needsPermission("Restart MacHelper to use the \(AccessibilityGrant.settingsListName) permission")
                    : .needsPermission
            } else if definition.id == .windowSwitcherMenu, let problem = switcher.hotKeyProblem {
                states[definition.id.rawValue] = TweakRuntimeStatus.TweakState(.active, reason: problem)
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
            accessibilityRestartRequired: accessibilityGrant == .restartRequired,
            eventTapInstalled: eventTap?.isInstalled ?? false,
            // Nil until it was read: automation is only checked while a Finder tweak needs it.
            automationFinderGranted: automation == .unavailable ? nil : automation == .granted,
            finderExtensionEnabled: extensionEnabled,
            tweaks: states)
        try? status.write(to: store.statusURL)
    }
}
