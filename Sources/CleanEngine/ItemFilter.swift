import Foundation

/// Filters for the cleaning preview: a search text, a minimum size and age, and a sort order.
public struct ItemFilter: Equatable, Sendable {
    public enum Sort: String, CaseIterable, Identifiable, Sendable { case size, name, oldest; public var id: String { rawValue } }
    public var text: String
    public var minBytes: UInt64
    public var minAgeDays: Int
    public var sort: Sort

    public init(text: String = "", minBytes: UInt64 = 0, minAgeDays: Int = 0, sort: Sort = .size) {
        self.text = text
        self.minBytes = minBytes
        self.minAgeDays = minAgeDays
        self.sort = sort
    }

    public var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty || minBytes > 0 || minAgeDays > 0 }

    /// The text matches the item's name or path, or the title of its rule (then all its items match).
    public func matches(_ c: CleanCandidate, ruleTitle: String, now: Date = Date()) -> Bool {
        if c.size < minBytes { return false }
        if minAgeDays > 0 {
            guard let m = c.modified, now.timeIntervalSince(m) >= TimeInterval(minAgeDays) * 86_400 else { return false }
        }
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || c.path.localizedCaseInsensitiveContains(t) || ruleTitle.localizedCaseInsensitiveContains(t)
    }

    public func sorted(_ cs: [CleanCandidate]) -> [CleanCandidate] {
        switch sort {
        case .size: cs.sorted { $0.size > $1.size }
        case .name: cs.sorted { ($0.path as NSString).lastPathComponent.localizedStandardCompare(($1.path as NSString).lastPathComponent) == .orderedAscending }
        case .oldest: cs.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
        }
    }

    public func apply(_ r: RuleResult, now: Date = Date()) -> [CleanCandidate] {
        sorted(r.candidates.filter { matches($0, ruleTitle: r.rule.title, now: now) })
    }
}
