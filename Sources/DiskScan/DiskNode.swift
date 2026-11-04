import Foundation

/// One node of a scanned tree: a directory, or a file large enough to keep individually.
///
/// Files smaller than `ScanOptions.keepFilesLargerThan` are not stored as nodes; their sizes are
/// folded into their directory's `smallFilesSize`, which keeps memory bounded for million-file trees.
/// Nodes are mutated only while scanning (each directory by exactly one worker) and are read-only after.
public final class DiskNode: @unchecked Sendable, Identifiable {
    public let name: String
    public let isDirectory: Bool
    public let modified: Date
    public internal(set) weak var parent: DiskNode?
    public internal(set) var children: [DiskNode] = []

    /// Allocated bytes on disk, recursive, with hard links and APFS clones counted once.
    public internal(set) var size: UInt64 = 0
    /// Number of files below this node (recursive).
    public internal(set) var fileCount: Int = 0
    /// Bytes of files that were too small to keep as nodes (this directory only).
    public internal(set) var smallFilesSize: UInt64 = 0
    public internal(set) var smallFilesCount: Int = 0
    /// errno if the directory could not be read (permission denied etc.).
    public internal(set) var readError: Int32 = 0

    /// Root nodes carry the absolute path they were scanned from.
    let rootPath: String?

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, isDirectory: Bool, modified: Date, parent: DiskNode?, rootPath: String? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.modified = modified
        self.parent = parent
        self.rootPath = rootPath
    }

    public var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        let p = parent.path
        return p.hasSuffix("/") ? p + name : p + "/" + name
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    /// Ancestors from the root down to (and including) self.
    public var lineage: [DiskNode] {
        var chain: [DiskNode] = []
        var n: DiskNode? = self
        while let cur = n { chain.append(cur); n = cur.parent }
        return chain.reversed()
    }

    /// Depth-first walk of every node below (and including) self.
    public func forEach(_ body: (DiskNode) -> Void) {
        var stack: [DiskNode] = [self]
        while let n = stack.popLast() {
            body(n)
            stack.append(contentsOf: n.children)
        }
    }

    /// Largest kept files below this node.
    public func largestFiles(limit: Int) -> [DiskNode] {
        var files: [DiskNode] = []
        forEach { if !$0.isDirectory { files.append($0) } }
        return Array(files.sorted { $0.size > $1.size }.prefix(limit))
    }

    /// Post-order: sums sizes/counts upward and sorts children largest first.
    func finalize() {
        // Iterative post-order to stay safe on very deep trees.
        var order: [DiskNode] = []
        var stack: [DiskNode] = [self]
        while let n = stack.popLast() {
            order.append(n)
            stack.append(contentsOf: n.children)
        }
        for n in order.reversed() where n.isDirectory {
            var size = n.smallFilesSize
            var count = n.smallFilesCount
            for c in n.children {
                size += c.size
                count += c.isDirectory ? c.fileCount : 1
            }
            n.size = size
            n.fileCount = count
            n.children.sort { $0.size > $1.size }
        }
    }
}
