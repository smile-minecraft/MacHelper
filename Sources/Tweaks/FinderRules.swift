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

    public init() {}

    public var isArmed: Bool { armedAt != nil }

    public mutating func arm(at date: Date) { armedAt = date }

    public mutating func disarm() { armedAt = nil }

    public func isArmed(at now: Date) -> Bool {
        guard let armedAt else { return false }
        let elapsed = now.timeIntervalSince(armedAt)
        return elapsed >= 0 && elapsed <= Self.lifetime
    }

    /// Takes an armed session for the paste that is about to happen: a move ends the cut, exactly
    /// like moving a file ends a cut in Finder. An expired session is not taken.
    public mutating func consume(now: Date) -> Bool {
        guard isArmed(at: now) else { armedAt = nil; return false }
        armedAt = nil
        return true
    }
}
