import CoreGraphics
import Foundation

/// One ring segment of a sunburst. Angles are fractions of the full circle (0...1, clockwise from 12 o'clock).
public struct SunburstArc: Sendable, Identifiable {
    public let id: Int
    /// nil for an aggregated "other / small items" segment.
    public let node: DiskNode?
    /// Ring index, 1 = innermost ring around the center.
    public let depth: Int
    public let start: Double
    public let end: Double
    public let size: UInt64
    /// Number of items folded into an "other" segment.
    public let otherCount: Int
    /// Index of the top-level branch, used for colouring.
    public let branch: Int

    public var isOther: Bool { node == nil }
}

/// Sunburst geometry for a subtree. Items under `minFraction` of the circle are merged into one
/// "other" segment per parent, so the chart stays fast with hundreds of thousands of nodes.
public struct SunburstLayout: Sendable {
    public let center: DiskNode
    public let arcs: [SunburstArc]
    public let maxDepth: Int
    private let byDepth: [[SunburstArc]]

    public init(center: DiskNode, maxDepth: Int = 6, minFraction: Double = 0.004, maxChildren: Int = 150) {
        self.center = center
        self.maxDepth = maxDepth
        var arcs: [SunburstArc] = []

        func place(_ node: DiskNode, start: Double, end: Double, depth: Int, branch: Int?) {
            guard node.size > 0, depth <= maxDepth else { return }
            let total = Double(node.size)
            let span = end - start
            var cursor = start
            var otherSize = node.smallFilesSize
            var otherCount = node.smallFilesCount
            for (i, child) in node.children.enumerated() {
                let width = Double(child.size) / total * span
                if width < minFraction || i >= maxChildren {
                    otherSize += child.size
                    otherCount += child.isDirectory ? max(child.fileCount, 1) : 1
                    continue
                }
                let b = branch ?? i
                arcs.append(SunburstArc(id: arcs.count, node: child, depth: depth, start: cursor, end: cursor + width,
                                        size: child.size, otherCount: 0, branch: b))
                if child.isDirectory { place(child, start: cursor, end: cursor + width, depth: depth + 1, branch: b) }
                cursor += width
            }
            let rest = Double(otherSize) / total * span
            if otherSize > 0, rest > 0.0005 {
                arcs.append(SunburstArc(id: arcs.count, node: nil, depth: depth, start: cursor, end: min(cursor + rest, end),
                                        size: otherSize, otherCount: otherCount, branch: branch ?? -1))
            }
        }
        place(center, start: 0, end: 1, depth: 1, branch: nil)
        self.arcs = arcs

        var grouped = Array(repeating: [SunburstArc](), count: maxDepth + 1)
        for a in arcs { grouped[a.depth].append(a) }
        byDepth = grouped.map { $0.sorted { $0.start < $1.start } }
    }

    /// The arc at an angle fraction on a given ring, if any.
    public func arc(atFraction f: Double, depth: Int) -> SunburstArc? {
        guard depth >= 1, depth < byDepth.count else { return nil }
        let ring = byDepth[depth]
        var lo = 0, hi = ring.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let a = ring[mid]
            if f < a.start { hi = mid - 1 } else if f >= a.end { lo = mid + 1 } else { return a }
        }
        return nil
    }

    /// Converts a point to (angle fraction, ring depth) for a chart centered in `size`.
    /// Ring 0 is the center disc.
    public static func polar(_ p: CGPoint, in size: CGSize, maxDepth: Int) -> (fraction: Double, depth: Int)? {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = p.x - c.x, dy = p.y - c.y
        let r = hypot(dx, dy)
        let radius = min(size.width, size.height) / 2
        let ring = radius / CGFloat(maxDepth + 1)
        guard r <= radius else { return nil }
        // atan2 measured from 12 o'clock, clockwise (screen y grows downward).
        var angle = atan2(dx, -dy) / (2 * .pi)
        if angle < 0 { angle += 1 }
        return (Double(angle), Int(r / ring))
    }
}

/// One rectangle of a squarified treemap.
public struct TreemapCell: Sendable, Identifiable {
    public let id: Int
    public let node: DiskNode?
    public let rect: CGRect
    public let depth: Int
    public let size: UInt64
    public let branch: Int
    /// For nested cells: the id of the top-level block they sit in (clicking opens that block).
    public let parent: Int?
    /// Index among its siblings (largest first), used to vary shades.
    public let rank: Int
    /// A top-level folder drawn with a title bar and its contents inside.
    public let hasHeader: Bool
    public var isOther: Bool { node == nil }
}

/// Squarified treemap (Bruls et al.) for a subtree, two levels deep. Top-level folders that are big
/// enough get a title bar (`headerHeight`) with their contents nested below it, inset by `padding`.
public struct TreemapLayout: Sendable {
    public let cells: [TreemapCell]

    public init(center: DiskNode, bounds: CGRect, levels: Int = 2, minArea: CGFloat = 48,
                headerHeight: CGFloat = 22, padding: CGFloat = 3) {
        var cells: [TreemapCell] = []

        func layout(_ node: DiskNode, in rect: CGRect, depth: Int, branch: Int?, parent: Int?) {
            guard node.size > 0, depth <= levels, rect.width > 2, rect.height > 2 else { return }
            let total = Double(node.size)
            let area = Double(rect.width * rect.height)
            var items: [(DiskNode?, Double, Int)] = []   // node, area, branch
            var other: UInt64 = node.smallFilesSize
            for (i, c) in node.children.enumerated() {
                let a = Double(c.size) / total * area
                if a < Double(minArea) { other += c.size } else { items.append((c, a, branch ?? i)) }
            }
            if other > 0 { items.append((nil, Double(other) / total * area, branch ?? -1)) }

            for (rank, (n, r, b)) in Self.squarify(items, in: rect).enumerated() {
                let size = n?.size ?? other
                let nest = n.map { $0.isDirectory && !$0.children.isEmpty } ?? false
                    && depth < levels && r.width > 80 && r.height > headerHeight + 36
                let id = cells.count
                cells.append(TreemapCell(id: id, node: n, rect: r, depth: depth, size: size, branch: b,
                                         parent: parent, rank: rank, hasHeader: nest))
                if nest, let n {
                    let inner = CGRect(x: r.minX + padding, y: r.minY + headerHeight,
                                       width: r.width - 2 * padding, height: r.height - headerHeight - padding)
                    layout(n, in: inner, depth: depth + 1, branch: b, parent: id)
                }
            }
        }
        layout(center, in: bounds, depth: 1, branch: nil, parent: nil)
        self.cells = cells
    }

    private static func worst(_ row: [Double], side: Double) -> Double {
        let s = row.reduce(0, +)
        guard let mx = row.max(), let mn = row.min(), s > 0, mn > 0 else { return .infinity }
        return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
    }

    private static func squarify(_ items: [(DiskNode?, Double, Int)], in rect: CGRect) -> [(DiskNode?, CGRect, Int)] {
        var out: [(DiskNode?, CGRect, Int)] = []
        var remaining = rect
        var queue = items[...]
        while !queue.isEmpty {
            let side = Double(min(remaining.width, remaining.height))
            var row: [(DiskNode?, Double, Int)] = []
            while let next = queue.first {
                let current = row.map(\.1)
                if row.isEmpty || Self.worst(current + [next.1], side: side) <= Self.worst(current, side: side) {
                    row.append(next)
                    queue = queue.dropFirst()
                } else { break }
            }
            let rowArea = row.reduce(0) { $0 + $1.1 }
            let horizontal = remaining.width >= remaining.height   // lay the row along the short side
            let thickness = CGFloat(rowArea / side)
            var offset: CGFloat = 0
            for (n, a, b) in row {
                let length = CGFloat(a) / max(thickness, 0.0001)
                let r = horizontal
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                out.append((n, r, b))
                offset += length
            }
            remaining = horizontal
                ? CGRect(x: remaining.minX + thickness, y: remaining.minY, width: remaining.width - thickness, height: remaining.height)
                : CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: remaining.height - thickness)
        }
        return out
    }
}

extension DiskNode {
    /// Removes this node from the tree after it was deleted on disk, updating ancestors' totals.
    public func detachFromTree() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        let removedFiles = isDirectory ? fileCount : 1
        var n: DiskNode? = parent
        while let cur = n {
            cur.size = cur.size >= size ? cur.size - size : 0
            cur.fileCount = max(cur.fileCount - removedFiles, 0)
            n = cur.parent
        }
        self.parent = nil
    }

    /// Finds a descendant by absolute path.
    public func descendant(atPath path: String) -> DiskNode? {
        let base = self.path
        guard path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
        var node: DiskNode = self
        for comp in path.dropFirst(base.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == comp }) else { return nil }
            node = next
        }
        return node
    }
}
