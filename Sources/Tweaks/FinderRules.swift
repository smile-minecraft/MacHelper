import CoreGraphics
import Foundation

/// The rules behind the Finder tweaks that run on the event tap's thread. They are pure so they can
/// be tested on a Mac without Accessibility permission, and so the tap callback stays cheap.
public enum FinderRules {
    public static let bundleID = "com.apple.finder"

    // Virtual key codes (ANSI layout), the same values CGEvent reports.
    public static let keyX: UInt16 = 7
    public static let keyC: UInt16 = 8
    public static let keyV: UInt16 = 9
    public static let keyN: UInt16 = 45
    public static let keyReturn: UInt16 = 36
    public static let keyEscape: UInt16 = 53

    // MARK: - Focus

    /// Accessibility roles that mean the caret is in text: renaming a file, the search field, the
    /// path bar. Keys typed there belong to the text, never to a file move.
    ///
    /// A missing role (Finder did not answer within the timeout) counts as text as well: leaving
    /// ⌘X/⌘V alone is always safe, moving files the person did not mean to move is not.
    public static func isTextFocus(_ role: String?) -> Bool {
        switch role {
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField", "AXWebArea":
            true
        case nil:
            true
        default:
            false
        }
    }

    /// Whether ⌘X should start a cut, from the number of items selected in the focused Finder view
    /// (nil when Finder did not say). With nothing selected Finder copies nothing, and a cut armed
    /// over an unchanged clipboard could pair with whatever writes the clipboard next, so ⌘X is
    /// left to Finder. An unknown count falls back to the clipboard check at paste time.
    public static func shouldArmCut(selectedCount: Int?) -> Bool {
        selectedCount != 0
    }

    // MARK: - Chords

    public enum Chord: Equatable, Sendable {
        case cut, copy, paste, escape
    }

    /// The plain-⌘ chords the tweak replaces. Modified variants (⇧⌘X, ⌥⌘V, ⌃⌘V) keep their meaning.
    /// Escape disarms whatever is left of a cut even when it carries modifiers.
    public static func chord(keyCode: UInt16, flags: UInt64) -> Chord? {
        if keyCode == keyEscape { return .escape }
        guard flags & TweakRules.commandFlag != 0,
              flags & (TweakRules.shiftFlag | TweakRules.alternateFlag | TweakRules.controlFlag) == 0 else { return nil }
        switch keyCode {
        case keyX: return .cut
        case keyC: return .copy
        case keyV: return .paste
        default: return nil
        }
    }
}

/// What the tweak remembers between ⌘X and ⌘V. Finder has no cut of its own, so ⌘X is sent on as a
/// copy and the next plain ⌘V in Finder is sent on as ⌥⌘V.
///
/// The session only lives for a moment (30 s) and is cancelled by Escape, by a new copy, and by
/// switching to another app: after any of those, the clipboard is no longer what the person cut.
public struct FinderCutSession: Equatable, Sendable {
    public static let lifetime: TimeInterval = 30
    private var armedAt: Date?
    /// The clipboard change counts that still hold what was cut. A paste only moves while the
    /// clipboard is one of them: anything else (a copy from a menu, a clipboard manager, Universal
    /// Clipboard, or a ⌘X with nothing selected) means ⌘V would move files the person only copied.
    private var clipboard: ClosedRange<Int>?

    public init() {}

    public var isArmed: Bool { armedAt != nil }

    /// `clipboard` nil leaves the change count unchecked.
    public mutating func arm(at date: Date, clipboard: ClosedRange<Int>? = nil) {
        armedAt = date
        self.clipboard = clipboard
    }

    public mutating func disarm() { armedAt = nil; clipboard = nil }

    /// Whether the clipboard still holds the cut items.
    public func holdsCut(changeCount: Int) -> Bool {
        clipboard.map { $0.contains(changeCount) } ?? true
    }

    public func isArmed(at now: Date) -> Bool {
        guard let armedAt else { return false }
        let elapsed = now.timeIntervalSince(armedAt)
        return elapsed >= 0 && elapsed <= Self.lifetime
    }

    /// Takes an armed session for the paste that is about to happen: a move ends the cut, exactly
    /// like moving a file ends a cut in Finder. An expired session is not taken.
    public mutating func consume(now: Date, changeCount: Int? = nil) -> Bool {
        defer { disarm() }
        guard isArmed(at: now) else { return false }
        if let changeCount, !holdsCut(changeCount: changeCount) { return false }
        return true
    }
}
