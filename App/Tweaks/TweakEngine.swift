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

    private static var eventMask: CGEventMask {
        CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
    }

    func start() {
        guard observers.isEmpty else { return }
        settings = store.load()
        granted = AccessibilityAuthority.isGranted
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

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
        quitGuard.updateFrontmost(frontmostBundleID)
        dockClick.updateFrontmost(frontmostBundleID)
        cmdTab.handleActivation(app)
    }

    private func apply(force: Bool = false) {
        let latest = store.load()
        let nowGranted = AccessibilityAuthority.isGranted
        if !force, latest == settings, nowGranted == granted { return }
        settings = latest
        granted = nowGranted

        let quitEnabled = latest.isEnabled(.inputQuitGuard)
        let dockEnabled = latest.isEnabled(.dockClickAction)
        if granted && (quitEnabled || dockEnabled) {
            if eventTap == nil {
                eventTap = EventTapService(handler: { [weak self] event in
                    self?.handle(event) ?? .pass
                })
            }
            eventTap?.install(mask: Self.eventMask)
        } else {
            eventTap?.remove()
            eventTap = nil
            quitGuard.reset()
        }

        music.configure(enabled: latest.isEnabled(.musicBlockAutolaunch), settings: latest)
        cmdTab.configure(enabled: granted && latest.isEnabled(.windowCmdTabRestore))
        quitGuard.configure(enabled: quitEnabled, settings: latest, frontmostBundleID: frontmostBundleID)
        dockClick.configure(enabled: dockEnabled, settings: latest, frontmostBundleID: frontmostBundleID)
        publishStatus()
    }

    private func handle(_ event: CGEvent) -> EventTapService.Outcome {
        if let outcome = quitGuard.handle(event) { return outcome }
        if let outcome = dockClick.handle(event) { return outcome }
        return .pass
    }

    private func publishStatus() {
        var states: [String: TweakRuntimeStatus.TweakState] = [:]
        for definition in TweakCatalog.all {
            let enabled = settings.isEnabled(definition.id)
            if !definition.implemented {
                states[definition.id.rawValue] = .unavailable("Coming soon")
            } else if !enabled {
                states[definition.id.rawValue] = .off
            } else if definition.permissions.contains(.accessibility) && !granted {
                states[definition.id.rawValue] = .needsPermission
            } else {
                states[definition.id.rawValue] = .active
            }
        }
        let status = TweakRuntimeStatus(
            appPID: Int32(ProcessInfo.processInfo.processIdentifier),
            accessibilityGranted: granted,
            eventTapInstalled: eventTap?.isInstalled ?? false,
            tweaks: states)
        try? status.write(to: store.statusURL)
    }
}
