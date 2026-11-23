import AppKit
import CoreGraphics
import SwiftUI
import Tweaks

/// A non-focus-stealing, non-interactive label shown when a guarded shortcut was blocked.
@MainActor
enum QuitGuardHUD {
    private static var panel: NSPanel?
    private static var hosted: NSHostingView<QuitGuardHUDView>?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String) {
        if panel == nil { createPanel() }
        guard let panel, let hosted else { return }
        hosted.rootView = QuitGuardHUDView(message: message)
        panel.setFrame(NSRect(x: 0, y: 0, width: 320, height: 48), display: false)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 160, y: frame.maxY - 96))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0.14
        panel.animator().alphaValue = 1
        NSAnimationContext.endGrouping()

        hideTask?.cancel()
        hideTask = Task { @MainActor in
            // A newer hint replaced this one: leave it on screen.
            guard (try? await Task.sleep(for: .milliseconds(1600))) != nil, !Task.isCancelled else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.2
            panel.animator().alphaValue = 0
            NSAnimationContext.endGrouping()
        }
    }

    private static func createPanel() {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosted = NSHostingView(rootView: QuitGuardHUDView(message: ""))
        hosted.frame = NSRect(x: 0, y: 0, width: 320, height: 48)
        panel.contentView = hosted
        Self.panel = panel
        Self.hosted = hosted
    }
}

private struct QuitGuardHUDView: View {
    let message: String

    var body: some View {
        ZStack {
            SurfaceShape(cornerRadius: 10).fill(Palette.card)
            SurfaceShape(cornerRadius: 10).stroke(Palette.stroke, lineWidth: 1)
            Text(message)
                .font(.mhCallout.weight(.medium))
                .foregroundStyle(Palette.text)
        }
        .contentTransition(.opacity)
        .animation(Motion.fade, value: message)
    }
}

/// Decides whether a ⌘Q / ⌘W key event is released or swallowed. It runs on the event tap's
/// thread: configuration and timing state sit behind a lock, the hold timer runs on a private queue
/// and only the HUD is drawn on the main queue.
final class QuitGuardBehavior: @unchecked Sendable {
    private struct Config {
        var enabled = false
        var doublePress = false
        var holdSeconds: Double = 0.6
        var guardCloseWindow = false
        var excludedApps: [String] = []
        var frontmostBundleID: String?
    }

    /// A swallowed key-down waiting for the hold to complete. `token` tells a late timer apart
    /// from the press it was started for.
    private struct Press {
        let keyCode: UInt16
        let event: CGEvent
        let token: UInt64
    }

    private struct State {
        var config = Config()
        var press: Press?
        var lastPress: (keyCode: UInt16, at: Date)?
        var nextToken: UInt64 = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "com.machelper.MacHelper"
    private let doublePressInterval: TimeInterval = 0.4
    private let timerQueue = DispatchQueue(label: "MacHelper.quit-guard", qos: .userInteractive)

    func configure(enabled: Bool, settings: TweakSettings, frontmostBundleID: String?) {
        lock.withLock {
            if state.config.enabled && !enabled { state.press = nil; state.lastPress = nil }
            state.config = Config(enabled: enabled,
                                  doublePress: settings.string("mode", for: .inputQuitGuard) == "doublePress",
                                  holdSeconds: settings.double("holdSeconds", for: .inputQuitGuard),
                                  guardCloseWindow: settings.bool("guardCloseWindow", for: .inputQuitGuard),
                                  excludedApps: settings.stringList("excludedApps", for: .inputQuitGuard),
                                  frontmostBundleID: frontmostBundleID)
        }
    }

    /// A pending press belongs to the app that was in front when ⌘Q went down; switching apps
    /// drops it, so the hold can never complete on a different app.
    func updateFrontmost(_ bundleID: String?) {
        lock.withLock {
            if state.config.frontmostBundleID != bundleID { state.press = nil; state.lastPress = nil }
            state.config.frontmostBundleID = bundleID
        }
    }

    func reset() { lock.withLock { state.press = nil; state.lastPress = nil } }

    /// Nil: not a guarded event, let the next behaviour look at it.
    func handle(_ type: CGEventType, _ event: CGEvent) -> EventTapService.Outcome? {
        lock.lock()
        defer { lock.unlock() }
        let config = state.config
        guard config.enabled else { return nil }
        if type == .flagsChanged {
            // Releasing ⌘, or adding ⇧/⌥/⌃, before the hold completes cancels the pending quit:
            // the shortcut being held is no longer plain ⌘Q / ⌘W.
            if let press = state.press,
               !TweakRules.isGuardedKey(keyCode: press.keyCode, flags: event.flags.rawValue, guardCloseWindow: true) {
                state.press = nil
            }
            return nil
        }
        guard type == .keyDown || type == .keyUp else { return nil }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        // The release of a press still waiting means it was let go too early, whatever the
        // modifiers or the frontmost app are by now.
        if type == .keyUp, let press = state.press, press.keyCode == keyCode {
            state.press = nil
            showHint(keyCode: keyCode, doublePress: false)
            return .suppress
        }
        guard TweakRules.isGuardedKey(keyCode: keyCode, flags: event.flags.rawValue, guardCloseWindow: config.guardCloseWindow),
              TweakRules.shouldGuardQuit(bundleID: config.frontmostBundleID, excludedApps: config.excludedApps,
                                         ownBundleID: ownBundleID) else { return nil }

        if type == .keyUp { return nil }
        // Auto-repeat is not a second deliberate press.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return .suppress }

        if config.doublePress {
            let now = Date()
            if let last = state.lastPress, last.keyCode == keyCode,
               TweakRules.doublePressAllowed(previousPressAt: last.at, now: now, interval: doublePressInterval) {
                state.lastPress = nil
                return .pass
            }
            state.lastPress = (keyCode, now)
            showHint(keyCode: keyCode, doublePress: true)
            return .suppress
        }

        if state.press != nil { return .suppress }
        state.nextToken &+= 1
        let token = state.nextToken
        // The tap's event is only valid during the callback; keep a copy to post later.
        guard let copy = event.copy() else { return nil }
        state.press = Press(keyCode: keyCode, event: copy, token: token)
        timerQueue.asyncAfter(deadline: .now() + max(config.holdSeconds, 0.2)) { [weak self] in
            self?.holdElapsed(token: token)
        }
        // The key-down is swallowed; once held long enough the same key-down is posted again.
        return .suppress
    }

    private func holdElapsed(token: UInt64) {
        let event: CGEvent? = lock.withLock {
            guard let press = state.press, press.token == token else { return nil }
            state.press = nil
            return press.event
        }
        if let event { EventTapService.post(event) }
    }

    private func showHint(keyCode: UInt16, doublePress: Bool) {
        let message = switch TweakRules.guardHint(keyCode: keyCode, doublePress: doublePress) {
        case .holdToQuit: String(localized: "Hold ⌘Q to quit")
        case .holdToClose: String(localized: "Hold ⌘W to close")
        case .pressTwiceToQuit: String(localized: "Press ⌘Q twice to quit")
        case .pressTwiceToClose: String(localized: "Press ⌘W twice to close")
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { QuitGuardHUD.show(message) } }
    }
}
