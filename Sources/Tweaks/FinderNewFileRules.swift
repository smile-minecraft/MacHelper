import Foundation

/// What a new file starts with. The values are the ones stored in tweaks.json.
public enum FinderFileTemplate: String, CaseIterable, Codable, Sendable {
    case text, markdown, rtf, custom

    public var fileExtension: String {
        switch self {
        case .text: "txt"
        case .markdown: "md"
        case .rtf: "rtf"
        case .custom: ""
        }
    }

    /// The document a new file starts as. Text-like templates start empty on purpose: an empty file
    /// opens in whatever editor the person uses, without a placeholder they have to delete.
    public var contents: Data {
        switch self {
        case .rtf:
            // A minimal, valid RTF document so TextEdit opens it as rich text instead of asking.
            Data(#"{\rtf1\ansi\ansicpg1252\cocoartf2761\cocoatextscaling0{\fonttbl\f0\fswiss\fcharset0 Helvetica;}\f0\fs24 \par}"#
                .utf8)
        case .text, .markdown, .custom:
            Data()
        }
    }
}

/// Rules for the file the Finder tweak creates. Naming is pure so conflicts can be tested without
/// touching a disk.
public enum FinderNewFileRules {
    public static let defaultBaseName = "Untitled"
    /// Long enough for the digits of any realistic folder; stops a pathological folder from
    /// turning one keystroke into thousands of `lstat` calls.
    public static let uniqueAttempts = 1_000

    /// A name that is safe to create: no path separators (Finder shows them as "/" and ":"), no
    /// control characters, no leading dot (which would hide the file), and never empty.
    public static func sanitizedBaseName(_ raw: String) -> String {
        var name = raw.components(separatedBy: .controlCharacters).joined()
        name = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return defaultBaseName }
        return String(name.prefix(120))
    }

    /// "Untitled.txt", then "Untitled 2.txt", "Untitled 3.txt" … when the name is taken. The
    /// comparison is case-insensitive because the default volume is, and two names that only differ
    /// in case would collide the moment the file is created.
    public static func uniqueFileName(base: String, pathExtension: String, existing: Set<String>) -> String {
        let base = sanitizedBaseName(base)
        let taken = Set(existing.map { $0.lowercased() })
        let suffix = pathExtension.isEmpty ? "" : "." + pathExtension
        func candidate(_ number: Int) -> String {
            number == 1 ? base + suffix : "\(base) \(number)" + suffix
        }
        for number in 1...uniqueAttempts where !taken.contains(candidate(number).lowercased()) {
            return candidate(number)
        }
        return candidate(uniqueAttempts + 1)
    }

    /// The extension the tweak creates: the template's own, or the one the person typed for a
    /// custom template. A leading dot and any path separator in the option are dropped.
    public static func fileExtension(template: FinderFileTemplate, customExtension: String) -> String {
        guard template == .custom else { return template.fileExtension }
        var cleaned = customExtension
            .components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces)
        // ".swift" is how people write an extension, "../evil" is how a typo tries to escape the
        // folder: both end up as a plain suffix after the dot.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned
    }
}
