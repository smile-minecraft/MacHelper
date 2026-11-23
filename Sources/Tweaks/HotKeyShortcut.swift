import Foundation

/// A system-wide keyboard shortcut stored as text in tweaks.json.
///
/// The format is the way people write shortcuts: `ctrl+opt+w`, `⌃⌥⌘W` or `cmd+shift+1`. Every
/// combination must include ⌘, ⌃ or ⌥; a bare letter or a ⇧-only shortcut would take a key away from
/// every app on the Mac.
public struct HotKeyShortcut: Equatable, Sendable, CustomStringConvertible {
    public let keyCode: UInt16
    /// The Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`), so registering the
    /// shortcut needs no second conversion.
    public let carbonModifiers: UInt32
    /// The key as written in the shortcut, lowercased: "w", "1".
    public let key: String

    // Carbon's modifier masks (Carbon/HIToolbox/Events.h).
    public static let commandMask: UInt32 = 0x0100
    public static let shiftMask: UInt32 = 0x0200
    public static let optionMask: UInt32 = 0x0800
    public static let controlMask: UInt32 = 0x1000

    /// ANSI virtual key codes for the keys a shortcut can use.
    public static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50,
    ]

    private init(keyCode: UInt16, carbonModifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.key = key
    }

    /// Nil for an empty string (no shortcut), an unknown key, or a combination that would fire while
    /// typing in another app.
    public static func parse(_ text: String) -> HotKeyShortcut? {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        for (symbol, name) in [("⌘", "cmd+"), ("⌃", "ctrl+"), ("⌥", "opt+"), ("⇧", "shift+")] {
            normalized = normalized.replacingOccurrences(of: symbol, with: name)
        }
        let parts = normalized.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 2, let key = parts.last, let keyCode = keyCodes[key] else { return nil }

        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "⌘": modifiers |= commandMask
            case "ctrl", "control", "⌃": modifiers |= controlMask
            case "opt", "option", "alt", "⌥": modifiers |= optionMask
            case "shift", "⇧": modifiers |= shiftMask
            default: return nil
            }
        }
        // ⇧ alone (or nothing) would steal a key from every app; one of ⌘/⌃/⌥ is required.
        guard modifiers & (commandMask | controlMask | optionMask) != 0 else { return nil }
        return HotKeyShortcut(keyCode: keyCode, carbonModifiers: modifiers, key: key)
    }

    /// The canonical spelling, the one the CLI accepts back: "ctrl+opt+w".
    public var description: String {
        var parts: [String] = []
        if carbonModifiers & Self.controlMask != 0 { parts.append("ctrl") }
        if carbonModifiers & Self.optionMask != 0 { parts.append("opt") }
        if carbonModifiers & Self.shiftMask != 0 { parts.append("shift") }
        if carbonModifiers & Self.commandMask != 0 { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}
