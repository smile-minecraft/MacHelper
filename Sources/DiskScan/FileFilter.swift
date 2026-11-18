import Foundation

/// Filter conditions for the largest-files list: a name-or-path search, a minimum allocated
/// size, a file kind and an age bound. Every set condition must hold (AND). The text match is
/// case-insensitive and looks at the file's name and its full path.
public struct FileFilter: Equatable, Sendable {
    public var text: String
    public var minBytes: UInt64
    public var kind: FileKind?
    public var olderThanDays: Int?

    public init(text: String = "", minBytes: UInt64 = 0, kind: FileKind? = nil, olderThanDays: Int? = nil) {
        self.text = text
        self.minBytes = minBytes
        self.kind = kind
        self.olderThanDays = olderThanDays
    }

    public var isActive: Bool {
        !trimmedText.isEmpty || minBytes > 0 || kind != nil || olderThanDays != nil
    }

    /// A file matches when every set condition holds. Directories never match: the filter
    /// describes files, and folders are pointed out as the ancestors of matches instead.
    public func matches(_ node: DiskNode, now: Date = Date()) -> Bool {
        guard !node.isDirectory else { return false }
        if node.size < minBytes { return false }
        if let kind, FileKind.of(node.name) != kind { return false }
        if let days = olderThanDays, node.modified >= now.addingTimeInterval(-Double(days) * 86_400) { return false }
        let t = trimmedText
        return t.isEmpty || node.name.localizedCaseInsensitiveContains(t) || node.path.localizedCaseInsensitiveContains(t)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The outcome of applying a filter to a scanned tree: the matching files (largest first),
/// their identity set, and the identity set of every directory that contains a match.
/// A class so a cached result can be handed out without copying its sets.
public final class FileFilterResult: @unchecked Sendable {
    public let files: [DiskNode]
    public let matching: Set<ObjectIdentifier>
    public let containingFolders: Set<ObjectIdentifier>

    public init(files: [DiskNode], matching: Set<ObjectIdentifier>, containingFolders: Set<ObjectIdentifier>) {
        self.files = files
        self.matching = matching
        self.containingFolders = containingFolders
    }
}

public extension FileFilter {
    /// One traversal of `node`. The filter is applied first, then the matches are ranked by
    /// size, so a matching file is never dropped just because many larger files fail the filter.
    func evaluate(in node: DiskNode, now: Date = Date()) -> FileFilterResult {
        var order: [DiskNode] = []
        var stack: [DiskNode] = [node]
        while let n = stack.popLast() {
            order.append(n)
            stack.append(contentsOf: n.children)
        }
        var files: [DiskNode] = []
        var matching = Set<ObjectIdentifier>()
        var containingFolders = Set<ObjectIdentifier>()
        // Reverse pre-order visits descendants before their ancestors.
        for n in order.reversed() {
            if n.isDirectory {
                let hasMatchBelow = n.children.contains { child in
                    child.isDirectory ? containingFolders.contains(ObjectIdentifier(child)) : matching.contains(ObjectIdentifier(child))
                }
                if hasMatchBelow { containingFolders.insert(ObjectIdentifier(n)) }
            } else if matches(n, now: now) {
                files.append(n)
                matching.insert(ObjectIdentifier(n))
            }
        }
        files.sort { $0.size > $1.size }
        return FileFilterResult(files: files, matching: matching, containingFolders: containingFolders)
    }
}

/// Memoizes filter evaluations per tree. Entries are keyed by the tree node, a revision
/// counter the caller bumps whenever the tree changes, and the filter itself, so the
/// charts can ask on every frame without walking the tree again.
public final class FileFilterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ObjectIdentifier: (revision: Int, filter: FileFilter, result: FileFilterResult)] = [:]
    private static let limit = 4

    public init() {}

    public func result(for node: DiskNode, revision: Int, filter: FileFilter) -> FileFilterResult {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(node)
        if let entry = entries[key], entry.revision == revision, entry.filter == filter {
            return entry.result
        }
        let result = filter.evaluate(in: node)
        if entries.count >= Self.limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = (revision, filter, result)
        return result
    }

    public func invalidate() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
