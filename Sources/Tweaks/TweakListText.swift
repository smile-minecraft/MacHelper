import Foundation

/// The text form of an app-list option ("com.apple.Safari, com.apple.Terminal"), shared by the
/// Tweaks page and the CLI so both read a list the same way.
public enum TweakListText {
    /// Splits on commas and line breaks, trims each entry and drops empty and repeated ones (bundle
    /// ids compare case-insensitively, so "com.apple.Safari" and "com.apple.safari" are one app).
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let entry = part.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty, seen.insert(entry.lowercased()).inserted else { continue }
            result.append(entry)
        }
        return result
    }

    public static func format(_ list: [String]) -> String {
        list.joined(separator: ", ")
    }
}
