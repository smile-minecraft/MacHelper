import AppKit
import CoreGraphics
import Foundation
import Tweaks

/// Turns ⌘X / ⌘V in Finder into a real move. Finder has no cut of its own, so ⌘X is forwarded as a
/// copy and the next plain ⌘V is forwarded as ⌥⌘V.
///
/// It runs on the event tap's thread for every key press, so it stays cheap: the chord test is a few
/// bit operations, and the only accessibility query (the focused element, to leave text fields
/// alone) carries a short messaging timeout and is reused for a moment. Nil from the accessibility
/// API means "Finder did not answer", and then the keys are left alone.
final class FinderCutPasteBehavior: @unchecked Sendable {
    private struct Config {
        var enabled = false
        var frontmostBundleID: String?
        var finderPID: pid_t?
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var config = Config()
    private var session = FinderCutSession()
    private var focusCache: (pid: pid_t, at: Date, role: String?)?
    /// A held ⌘V must not paste the files a second time: the first paste already moved them, and
    /// the clipboard still holds the same files, so the repeat would copy them back as duplicates.
    private var repeatGuardUntil = Date.distantPast

    /// Short on purpose: this sits in front of every ⌘X and ⌘V on the Mac.
    private let focusTimeout: Float = 0.05
    private let focusCacheLifetime: TimeInterval = 0.25

    func configure(enabled: Bool, frontmost: NSRunningApplication?) {
        let finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: FinderRules.bundleID).first?.processIdentifier
        lock.withLock {
            if !enabled { session.disarm() }
            config = Config(enabled: enabled,
                            frontmostBundleID: frontmost?.bundleIdentifier,
                            finderPID: finderPID)
            if !enabled { focusCache = nil }
        }
    }

    /// Switching apps ends a cut: from then on the clipboard is no longer what the person cut.
    func updateFrontmost(_ app: NSRunningApplication) {
        // MacHelper itself can come forward for a moment while it handles the extension's URL;
        // that is not the person leaving Finder, so it neither ends a cut nor changes the app.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lock.withLock {
            if config.frontmostBundleID != app.bundleIdentifier { session.disarm() }
            config.frontmostBundleID = app.bundleIdentifier
            if app.bundleIdentifier == FinderRules.bundleID { config.finderPID = app.processIdentifier }
        }
    }

    func reset() { lock.withLock { session.disarm(); focusCache = nil; repeatGuardUntil = .distantPast } }

    /// The extension's Cut menu item arms the same session the keyboard does.
    /// The menu wrote the clipboard itself, so it holds the cut exactly while the count is unchanged.
    func armCut(changeCount: Int) { lock.withLock { session.arm(at: Date(), clipboard: changeCount...changeCount) } }

    /// Nil: not a key this behaviour changes.
    func handle(_ type: CGEventType, _ event: CGEvent) -> EventTapService.Outcome? {
        guard type == .keyDown else { return nil }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        guard let chord = FinderRules.chord(keyCode: keyCode, flags: event.flags.rawValue) else { return nil }
        let config = lock.withLock { self.config }
        guard config.enabled else { return nil }

        switch chord {
        case .escape:
            lock.withLock { session.disarm() }
            return nil
        case .copy:
            // Any copy, in any app, replaces what ⌘V would paste.
            lock.withLock { session.disarm() }
            return nil
        case .cut:
            guard isFinderFrontmost(config), let pid = config.finderPID else { return nil }
            // One accessibility trip answers both questions: is the caret in text, and is
            // anything selected. It also refreshes the focus cache the paste reads.
            let focus = AXWindowTools.focusedState(for: pid, timeout: focusTimeout)
            lock.withLock { focusCache = (pid, Date(), focus.role) }
            guard !FinderRules.isTextFocus(focus.role) else { return nil }
            // Nothing selected: Finder copies nothing, so there is nothing to cut.
            guard FinderRules.shouldArmCut(selectedCount: focus.selectedCount) else {
                lock.withLock { session.disarm() }
                return nil
            }
            // Finder's copy bumps the change count by exactly one (measured). No change means
            // nothing was selected, and any further change means something replaced the copy; in
            // both cases ⌘V stays a plain paste, the safe direction.
            let count = NSPasteboard.general.changeCount
            lock.withLock { session.arm(at: Date(), clipboard: (count + 1)...(count + 1)) }
            // Finder has nothing to do with ⌘X itself; the files reach the clipboard as a copy.
            EventTapService.postKey(keyCode: FinderRules.keyC, flags: TweakRules.commandFlag)
            return .suppress
        case .paste:
            guard isFinderFrontmost(config) else { return nil }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return lock.withLock { Date() < repeatGuardUntil } ? .suppress : nil
            }
            guard lock.withLock({ session.isArmed(at: Date()) }) else { return nil }
            // Pasting into a name field is text, not a file move; the cut is no longer what the
            // person meant.
            guard !isTextFocus(config) else {
                lock.withLock { session.disarm() }
                return nil
            }
            let taken = lock.withLock { () -> Bool in
                guard session.consume(now: Date(), changeCount: NSPasteboard.general.changeCount) else { return false }
                repeatGuardUntil = Date().addingTimeInterval(2)
                return true
            }
            guard taken else { return nil }
            EventTapService.postKey(keyCode: FinderRules.keyV,
                                    flags: TweakRules.commandFlag | TweakRules.alternateFlag)
            return .suppress
        }
    }

    private func isFinderFrontmost(_ config: Config) -> Bool {
        config.frontmostBundleID == FinderRules.bundleID
    }

    private func isTextFocus(_ config: Config) -> Bool {
        guard let pid = config.finderPID else { return true }
        if let cached = lock.withLock({ focusCache }), cached.pid == pid,
           Date().timeIntervalSince(cached.at) < focusCacheLifetime {
            return FinderRules.isTextFocus(cached.role)
        }
        // Called from the tap's thread: Finder gets a short timeout and never a main-thread hop.
        let role = AXWindowTools.focusedRole(for: pid, timeout: focusTimeout)
        lock.withLock { focusCache = (pid, Date(), role) }
        return FinderRules.isTextFocus(role)
    }
}
