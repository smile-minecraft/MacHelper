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
            try? await Task.sleep(for: .milliseconds(1600))
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

/// Decides whether a ⌘Q / ⌘W key event is released or swallowed. Timing state lives here; the
/// event tap only calls this class on the main actor and never performs slow work itself.
@MainActor
final class QuitGuardBehavior {
    private struct Press {
        let keyCode: UInt16
        let event: CGEvent
        var timer: Timer?
    }

    private var settings = TweakSettings()
    private var enabled = false
    private var frontmostBundleID: String?
    private var press: Press?
    private var lastPressAt: Date?
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "com.machelper.MacHelper"
    private let doublePressInterval: TimeInterval = 0.4

    func configure(enabled: Bool, settings: TweakSettings, frontmostBundleID: String?) {
        if self.enabled && !enabled { reset() }
        self.enabled = enabled
        self.settings = settings
        self.frontmostBundleID = frontmostBundleID
    }

    func updateFrontmost(_ bundleID: String?) { frontmostBundleID = bundleID }

    func handle(_ event: CGEvent) -> EventTapService.Outcome? {
        guard enabled else { return nil }
        if event.type == .flagsChanged {
            // Releasing ⌘ before the hold completes cancels the pending quit.
            if let active = press, !TweakRules.isCommandHeld(event.flags.rawValue) {
                active.timer?.invalidate()
                press = nil
            }
            return nil
        }
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let guardClose = settings.bool("guardCloseWindow", for: .inputQuitGuard)
        guard TweakRules.isGuardedKey(keyCode: keyCode, flags: flags, guardCloseWindow: guardClose),
              TweakRules.shouldGuardQuit(bundleID: frontmostBundleID,
                                         excludedApps: settings.stringList("excludedApps", for: .inputQuitGuard),
                                         ownBundleID: ownBundleID) else { return nil }

        if event.type == .keyUp { return release(keyCode: keyCode) }
        // Auto-repeat is not a second deliberate press.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return .suppress }
        return press(keyCode: keyCode, event: event)
    }

    private func press(keyCode: UInt16, event: CGEvent) -> EventTapService.Outcome {
        let now = Date()
        if settings.string("mode", for: .inputQuitGuard) == "doublePress" {
            if TweakRules.doublePressAllowed(previousPressAt: lastPressAt, now: now, interval: doublePressInterval) {
                lastPressAt = nil
                return .pass
            }
            lastPressAt = now
            QuitGuardHUD.show(String(localized: "Press ⌘Q twice to quit"))
            return .suppress
        }

        if press != nil { return .suppress }
        let required = settings.double("holdSeconds", for: .inputQuitGuard)
        var current = Press(keyCode: keyCode, event: event)
        let timer = Timer.scheduledTimer(withTimeInterval: max(required, 0.2), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let active = self.press, active.keyCode == keyCode else { return }
                self.press = nil
                EventTapService.post(active.event)
            }
        }
        current.timer = timer
        press = current
        // The initial keydown is swallowed; the timer reposts the same event once held long enough.
        return .suppress
    }

    private func release(keyCode: UInt16) -> EventTapService.Outcome? {
        guard let active = press, active.keyCode == keyCode else { return nil }
        active.timer?.invalidate()
        press = nil
        QuitGuardHUD.show(String(localized: "Hold ⌘Q to quit"))
        return .suppress
    }

    func reset() {
        press?.timer?.invalidate()
        press = nil
        lastPressAt = nil
    }
}
