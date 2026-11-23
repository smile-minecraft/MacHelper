import CoreGraphics
import Foundation

/// A system-wide shortcut, stored in tweaks.json as text such as "ctrl+option+n".
///
/// The tweak reads the text and matches events against the parsed value, so a person can move the
/// shortcut without a rebuild. The modifiers are compared exactly: a shortcut never fires on a
/// modified variant of itself (⇧⌃⌥N stays with the system).
public struct TweakShortcut: Equatable, Sendable, CustomStringConvertible {
    public let keyCode: UInt16
    /// Only the ⌘ ⌥ ⌃ ⇧ bits; caps lock and the numeric keypad never belong to a shortcut.
    public let flags: UInt64

    public init(keyCode: UInt16, flags: UInt64) {
        self.keyCode = keyCode
        self.flags = flags & Self.relevantFlags
    }

    public static let relevantFlags: UInt64 =
        TweakRules.commandFlag | TweakRules.alternateFlag | TweakRules.controlFlag | TweakRules.shiftFlag

    /// "⌃⌥N", the order macOS uses in menus.
    public var description: String {
        var text = ""
        if flags & TweakRules.controlFlag != 0 { text += "⌃" }
        if flags & TweakRules.alternateFlag != 0 { text += "⌥" }
        if flags & TweakRules.shiftFlag != 0 { text += "⇧" }
        if flags & TweakRules.commandFlag != 0 { text += "⌘" }
        return text + (Self.keyCodes.first { $0.value == keyCode }?.key.uppercased() ?? "?")
    }

    /// Whether a key event with these modifiers is this shortcut and nothing else.
    public func matches(keyCode: UInt16, flags: UInt64) -> Bool {
        keyCode == self.keyCode && (flags & Self.relevantFlags) == self.flags
    }

    /// Parses "ctrl+alt+n", "⌃⌥N" or "cmd-shift-k". At least one modifier is required: a bare
    /// letter as a global shortcut would take that key away from every app.
    public static func parse(_ text: String) -> TweakShortcut? {
        let tokens = expanded(text)
            .replacingOccurrences(of: " ", with: "")
            .split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map(String.init)
        guard tokens.count >= 2, let key = tokens.last else { return nil }
        var flags: UInt64 = 0
        for token in tokens.dropLast() {
            switch token {
            case "cmd", "command", "⌘": flags |= TweakRules.commandFlag
            case "opt", "alt", "option", "⌥": flags |= TweakRules.alternateFlag
            case "ctrl", "control", "⌃": flags |= TweakRules.controlFlag
            case "shift", "⇧": flags |= TweakRules.shiftFlag
            default: return nil
            }
        }
        guard flags != 0, let keyCode = keyCodes[key] else { return nil }
        return TweakShortcut(keyCode: keyCode, flags: flags)
    }

    /// "⌃⌥N" (how menus write a shortcut) spelled out as "ctrl+opt+n" so one tokenizer handles both.
    private static func expanded(_ text: String) -> String {
        var out = ""
        for character in text.lowercased() {
            switch character {
            case "⌃": out += "ctrl+"
            case "⌥": out += "opt+"
            case "⇧": out += "shift+"
            case "⌘": out += "cmd+"
            default: out.append(character)
            }
        }
        return out
    }

    /// ANSI key codes of the keys a shortcut may use. A table instead of Carbon's keyboard layout
    /// table: the value has to be the same for every input source.
    public static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20,
        "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34,
        "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
}
