import Foundation

/// The user's permanent exclusions for cleaning: one path or glob per line in clean-whitelist.txt.
/// Comment lines (#) and blank lines are kept when entries are added or removed.
public struct CleanExclusions: Sendable {
    public let file: URL

    public init(file: URL = MacHelperPaths.whitelistFile) { self.file = file }

    public func entries() -> [String] {
        lines().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// `~/…` for paths in the home folder, so the file stays readable and portable.
    public static func entry(for path: String) -> String {
        let home = MacHelperPaths.home.path
        return path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }

    public func add(_ entry: String) throws {
        let e = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, !e.hasPrefix("#"), !e.contains("\n"), !entries().contains(e) else { return }
        var ls = lines()
        if ls.isEmpty { ls = ["# MacHelper never cleans these paths (one path or glob per line, ~ is your home folder)."] }
        ls.append(e)
        try write(ls)
    }

    public func remove(_ entry: String) throws {
        let ls = lines()
        let kept = ls.filter { $0.trimmingCharacters(in: .whitespaces) != entry }
        if kept.count != ls.count { try write(kept) }
    }

    private func lines() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var ls = text.components(separatedBy: "\n")
        if ls.last == "" { ls.removeLast() }
        return ls
    }

    private func write(_ lines: [String]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
