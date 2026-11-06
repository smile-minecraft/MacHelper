import DiskScan
import SwiftUI

/// One cohesive, desaturated palette (not a rainbow). Each top-level folder gets a hue; everything
/// below it inherits the hue and only varies in lightness, so the hierarchy stays readable. Tones are
/// dark enough for white labels.
enum DiskPalette {
    private static let hues: [(h: Double, s: Double, b: Double)] = [
        (0.59, 0.58, 0.74),   // blue
        (0.48, 0.60, 0.62),   // teal
        (0.38, 0.48, 0.60),   // green
        (0.08, 0.62, 0.74),   // amber
        (0.01, 0.55, 0.72),   // coral
        (0.67, 0.36, 0.66),   // slate indigo
        (0.94, 0.45, 0.70),   // rose
        (0.15, 0.48, 0.58),   // olive
        (0.54, 0.40, 0.56),   // steel
        (0.06, 0.42, 0.56),   // clay
    ]

    static func color(branch: Int, depth: Int, rank: Int = 0, isFile: Bool, highlighted: Bool, dimmed: Bool = false) -> Color {
        let base: Color
        if branch < 0 {
            base = Color(hue: 0.62, saturation: 0.06, brightness: highlighted ? 0.62 : 0.52)
        } else {
            let t = hues[branch % hues.count]
            let d = Double(max(depth - 1, 0))
            let shade = Double(rank % 3) * 0.035          // neighbours differ slightly
            let s = max(t.s - d * 0.07 - (isFile ? 0.16 : 0), 0.22)
            let b = min(t.b + d * 0.04 + shade + (highlighted ? 0.10 : 0), 0.86)
            base = Color(hue: t.h, saturation: s, brightness: b)
        }
        return dimmed ? base.opacity(0.35) : base
    }
}

/// White label with a soft shadow, truncated to fit `width`.
private func fittedLabel(_ ctx: GraphicsContext, _ text: String, font: Font, width: CGFloat,
                         color: Color = .white) -> GraphicsContext.ResolvedText? {
    var s = text
    for _ in 0..<12 {
        let r = ctx.resolve(Text(s).font(font).foregroundStyle(color))
        if r.measure(in: CGSize(width: 10_000, height: 100)).width <= width { return r }
        guard s.count > 3 else { return nil }
        s = String(s.prefix(max(Int(Double(s.count) * 0.75), 2))) + "…"
        if s.count <= 2 { return nil }
    }
    return nil
}

private func labelContext(_ ctx: GraphicsContext) -> GraphicsContext {
    var c = ctx
    c.addFilter(.shadow(color: .black.opacity(0.35), radius: 1.2, x: 0, y: 0.6))
    return c
}

/// Floating card next to the cursor.
struct ChartTooltip: View {
    let info: HoverInfo
    let share: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.title).font(.mh(size: 13, weight: .semibold)).lineLimit(1)
            HStack(spacing: 6) {
                Text(Fmt.bytes(Int64(clamping: info.size))).font(.display(12, weight: .semibold).monospacedDigit())
                if let share { Text(Fmt.percent(share)).font(.mh(size: 12).monospacedDigit()).foregroundStyle(Palette.textMuted) }
                Text("· \(info.detail)").font(.mh(size: 11.5)).foregroundStyle(Palette.textMuted)
            }
            if let path = info.path {
                Text(Fmt.shortPath(path)).font(.mh(size: 10.5)).foregroundStyle(Palette.textFaint).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.regularMaterial, in: SurfaceShape(cornerRadius: 9, style: .continuous))
        .overlay(SurfaceShape(cornerRadius: 9, style: .continuous).strokeBorder(Palette.stroke))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}

/// Places the tooltip near the pointer, flipped to stay inside the chart.
private struct TooltipLayer: View {
    let model: DiskAnalysisModel
    let point: CGPoint?
    let bounds: CGSize
    let total: UInt64

    var body: some View {
        if let info = model.hover, let p = point {
            let flipX = p.x > bounds.width - 300, flipY = p.y > bounds.height - 90
            ChartTooltip(info: info, share: total > 0 ? Double(info.size) / Double(total) : nil)
                .fixedSize()
                .alignmentGuide(.leading) { d in flipX ? d.width + 14 - p.x : -p.x - 14 }
                .alignmentGuide(.top) { d in flipY ? d.height + 14 - p.y : -p.y - 16 }
                .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
                .transition(.opacity)
        }
    }
}

// MARK: - Sunburst

struct SunburstChart: View {
    let model: DiskAnalysisModel
    let focus: DiskNode

    @State private var layout: SunburstLayout?
    @State private var hoveredArc: Int?
    @State private var pointer: CGPoint?
    /// Four rings: deeper sunbursts get unreadably thin outer rings.
    private let maxDepth = 4

    init(model: DiskAnalysisModel, focus: DiskNode, precomputed: SunburstLayout? = nil) {
        self.model = model
        self.focus = focus
        _layout = State(initialValue: precomputed)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let size = CGSize(width: side, height: side)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(&ctx, size: size) }
                    .frame(width: side, height: side)
                    .contentShape(Circle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let p): pointer = p; updateHover(at: p, size: size)
                        case .ended: pointer = nil; hoveredArc = nil; model.hover = nil
                        }
                    }
                    .onTapGesture(coordinateSpace: .local) { p in tap(at: p, size: size) }
                    .contextMenu { contextMenu }
                    .onDrag { dragProvider() }
                TooltipLayer(model: model, point: pointer, bounds: size, total: focus.size)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement()
            .accessibilityLabel("Sunburst: \(focus.name), \(Fmt.bytes(Int64(clamping: focus.size)))")
            .accessibilityChildren {
                ForEach(focus.children.prefix(20)) { c in Text("\(c.name) \(Fmt.bytes(Int64(clamping: c.size)))") }
            }
        }
        .task(id: TaskKey(focus: ObjectIdentifier(focus), revision: model.revision)) {
            let f = focus
            let depth = maxDepth
            layout = await Task.detached { SunburstLayout(center: f, maxDepth: depth) }.value
            hoveredArc = nil
        }
    }

    private struct TaskKey: Equatable { let focus: ObjectIdentifier; let revision: Int }

    private var hoveredNode: DiskNode? {
        guard let id = hoveredArc, let layout, id < layout.arcs.count else { return nil }
        return layout.arcs[id].node
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        guard let layout else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let ring = min(size.width, size.height) / 2 / CGFloat(maxDepth + 1)
        let separator = Color(nsColor: .windowBackgroundColor)

        // The hovered arc and its ancestors stay bright; everything else dims.
        let hovered = hoveredArc.flatMap { id in layout.arcs.first { $0.id == id } }
        let path: Set<ObjectIdentifier> = Set(hovered?.node?.lineage.map(ObjectIdentifier.init) ?? [])
        func onPath(_ a: SunburstArc) -> Bool {
            guard let hovered else { return true }
            if a.id == hovered.id { return true }
            return a.node.map { path.contains(ObjectIdentifier($0)) } ?? false
        }

        for arc in layout.arcs where arc.depth <= maxDepth {
            let inner = CGFloat(arc.depth) * ring
            let outer = inner + ring
            let a0 = Angle.degrees(-90 + arc.start * 360)
            let a1 = Angle.degrees(-90 + arc.end * 360)
            var p = Path()
            p.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
            p.addArc(center: center, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
            p.closeSubpath()
            let color = DiskPalette.color(branch: arc.branch, depth: arc.depth, isFile: !(arc.node?.isDirectory ?? true),
                                          highlighted: arc.id == hoveredArc, dimmed: !onPath(arc))
            ctx.fill(p, with: .color(color))
            ctx.stroke(p, with: .color(separator), lineWidth: 1.5)
        }

        // Labels along the arc, upright, only where they fit.
        let lctx = labelContext(ctx)
        for arc in layout.arcs where arc.depth <= 3 && onPath(arc) {
            let mid = (arc.start + arc.end) / 2
            let radius = (CGFloat(arc.depth) + 0.5) * ring
            let arcLength = CGFloat(arc.end - arc.start) * 2 * .pi * radius
            guard arcLength > 40, ring > 20 else { continue }
            let name = arc.node?.name ?? String(localized: "Other")
            let font = Font.mh(size: arc.depth == 1 ? 12.5 : 11, weight: .semibold)
            guard let label = fittedLabel(lctx, name, font: font, width: arcLength - 14) else { continue }
            let theta = Angle.degrees(-90 + mid * 360).radians
            let pos = CGPoint(x: center.x + cos(theta) * radius, y: center.y + sin(theta) * radius)
            var rotation = theta + .pi / 2
            if sin(theta) > 0 { rotation -= .pi }          // bottom half: flip so text stays upright
            var c = lctx
            c.translateBy(x: pos.x, y: pos.y)
            c.rotate(by: .radians(rotation))
            c.draw(label, at: .zero, anchor: .center)
        }

        // Center: the focused folder; click to go up.
        let r = ring - 4
        let disc = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(disc, with: .color(Palette.card))
        ctx.stroke(disc, with: .color(Palette.stroke), lineWidth: 1)
        if let title = fittedLabel(ctx, focus.name, font: .system(size: 13, weight: .bold), width: 2 * r - 14, color: Palette.text) {
            ctx.draw(title, at: CGPoint(x: center.x, y: center.y - 10), anchor: .center)
        }
        ctx.draw(Text(Fmt.bytes(Int64(clamping: focus.size))).font(.display(12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.textMuted),
                 at: CGPoint(x: center.x, y: center.y + 8), anchor: .center)
        if focus.parent != nil {
            ctx.draw(Text(verbatim: "↑").font(.mh(size: 11, weight: .bold)).foregroundStyle(Palette.textFaint),
                     at: CGPoint(x: center.x, y: center.y + 26), anchor: .center)
        }
    }

    private func updateHover(at p: CGPoint, size: CGSize) {
        guard let layout, let (f, depth) = SunburstLayout.polar(p, in: size, maxDepth: maxDepth) else {
            hoveredArc = nil
            model.hover = nil
            return
        }
        if depth == 0 {
            hoveredArc = nil
            model.hover = model.hoverInfo(for: focus)
            return
        }
        let arc = layout.arc(atFraction: f, depth: depth)
        hoveredArc = arc?.id
        model.hover = arc.flatMap { model.hoverInfo(for: $0.node, otherSize: $0.size, otherCount: $0.otherCount) }
    }

    private func tap(at p: CGPoint, size: CGSize) {
        guard let layout, let (f, depth) = SunburstLayout.polar(p, in: size, maxDepth: maxDepth) else { return }
        if depth == 0 { model.zoomOut(); return }
        guard let node = layout.arc(atFraction: f, depth: depth)?.node else { return }
        // Open one level: the ring-1 folder on the path to what was clicked (or the folder itself).
        let target = node.lineage.first { $0.parent === focus } ?? node
        if target.isDirectory { withAnimation(.easeInOut(duration: 0.2)) { model.zoom(to: target) } }
    }

    @ViewBuilder private var contextMenu: some View {
        if let node = hoveredNode { NodeMenu(model: model, node: node) }
    }

    private func dragProvider() -> NSItemProvider {
        guard let node = hoveredNode else { return NSItemProvider() }
        return NSItemProvider(object: node.url as NSURL)
    }
}

// MARK: - Treemap

struct TreemapChart: View {
    let model: DiskAnalysisModel
    let focus: DiskNode

    @State private var cells: [TreemapCell] = []
    @State private var hoveredCell: Int?
    @State private var pointer: CGPoint?

    init(model: DiskAnalysisModel, focus: DiskNode, precomputed: [TreemapCell] = []) {
        self.model = model
        self.focus = focus
        _cells = State(initialValue: precomputed)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(&ctx) }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let p): pointer = p; updateHover(at: p)
                        case .ended: pointer = nil; hoveredCell = nil; model.hover = nil
                        }
                    }
                    .onTapGesture(coordinateSpace: .local) { p in open(at: p) }
                    .contextMenu { if let node = hoveredNode { NodeMenu(model: model, node: node) } }
                    .onDrag { hoveredNode.map { NSItemProvider(object: $0.url as NSURL) } ?? NSItemProvider() }
                TooltipLayer(model: model, point: pointer, bounds: geo.size, total: focus.size)
            }
            .task(id: Key(focus: ObjectIdentifier(focus), revision: model.revision, w: Int(geo.size.width), h: Int(geo.size.height))) {
                let f = focus
                let bounds = CGRect(origin: .zero, size: geo.size)
                // Anything under 0.4 % of the area joins "Other" instead of becoming confetti.
                let minArea = max(bounds.width * bounds.height * 0.004, 48)
                cells = await Task.detached { TreemapLayout(center: f, bounds: bounds, minArea: minArea).cells }.value
                hoveredCell = nil
            }
            .accessibilityLabel("Treemap: \(focus.name), click a block to open it")
        }
    }

    private struct Key: Equatable { let focus: ObjectIdentifier; let revision: Int; let w: Int; let h: Int }

    private var hoveredNode: DiskNode? {
        guard let id = hoveredCell, id < cells.count else { return nil }
        return cells[id].node
    }

    /// The innermost cell under the point (nested cells come after their parent).
    private func cell(at p: CGPoint) -> TreemapCell? {
        cells.last { $0.rect.contains(p) }
    }

    private func updateHover(at p: CGPoint) {
        let c = cell(at: p)
        hoveredCell = c?.id
        model.hover = c.flatMap { model.hoverInfo(for: $0.node, otherSize: $0.size) }
    }

    /// One click opens one level: the top-level block that contains the point.
    private func open(at p: CGPoint) {
        guard let c = cell(at: p) else { return }
        let top = c.parent.map { cells[$0] } ?? c
        if let node = top.node, node.isDirectory {
            withAnimation(.easeInOut(duration: 0.2)) { model.zoom(to: node) }
        } else if let node = c.node {
            model.quickLook(node)
        }
    }

    private func draw(_ ctx: inout GraphicsContext) {
        let lctx = labelContext(ctx)
        let hoveredTop = hoveredCell.flatMap { id in cells[id].parent ?? id }
        for c in cells {
            let r = c.rect.insetBy(dx: 1, dy: 1)
            guard r.width > 1, r.height > 1 else { continue }
            let isHovered = c.id == hoveredCell
            let color = DiskPalette.color(branch: c.branch, depth: c.depth, rank: c.rank,
                                          isFile: !(c.node?.isDirectory ?? true), highlighted: isHovered)
            let shape = Path(roundedRect: r, cornerRadius: c.depth == 1 ? 6 : 4, style: .continuous)
            ctx.fill(shape, with: .color(color))
            if c.hasHeader {
                // Darker title bar for the top-level folder; its contents sit below.
                let header = Path(roundedRect: CGRect(x: r.minX, y: r.minY, width: r.width, height: 21), cornerRadius: 6, style: .continuous)
                ctx.fill(header, with: .color(.black.opacity(0.18)))
            }
            if c.id == hoveredTop && c.depth == 1 {
                ctx.stroke(shape, with: .color(.white.opacity(0.85)), lineWidth: 2)
            } else if isHovered {
                ctx.stroke(shape, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            }
            drawLabel(lctx, c, in: r)
        }
    }

    private func drawLabel(_ ctx: GraphicsContext, _ c: TreemapCell, in r: CGRect) {
        let name = c.node?.name ?? String(localized: "Other")
        let size = Fmt.bytes(Int64(clamping: c.size))
        if c.hasHeader {
            guard r.width > 60 else { return }
            let sizeText = ctx.resolve(Text(size).font(.display(11.5, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.85)))
            let sw = sizeText.measure(in: CGSize(width: 400, height: 30)).width
            if let title = fittedLabel(ctx, name, font: .system(size: 12.5, weight: .bold), width: r.width - sw - 24) {
                ctx.draw(title, at: CGPoint(x: r.minX + 8, y: r.minY + 10.5), anchor: .leading)
            }
            ctx.draw(sizeText, at: CGPoint(x: r.maxX - 8, y: r.minY + 10.5), anchor: .trailing)
            return
        }
        // Leaf blocks: name and size, stacked, only when there is room.
        let big = c.depth == 1
        guard r.width > 54, r.height > (big ? 36 : 30) else { return }
        let nameFont = Font.mh(size: big ? 13.5 : 12, weight: .semibold)
        guard let title = fittedLabel(ctx, name, font: nameFont, width: r.width - 14) else { return }
        ctx.draw(title, at: CGPoint(x: r.minX + 7, y: r.minY + 6), anchor: .topLeading)
        if r.height > (big ? 52 : 44) {
            ctx.draw(Text(size).font(.mh(size: big ? 12 : 11).monospacedDigit()).foregroundStyle(.white.opacity(0.82)),
                     at: CGPoint(x: r.minX + 7, y: r.minY + (big ? 25 : 22)), anchor: .topLeading)
        }
    }
}

/// Shared context menu for a node in either chart or list.
struct NodeMenu: View {
    let model: DiskAnalysisModel
    let node: DiskNode

    var body: some View {
        if node.isDirectory { Button("Open Folder") { model.zoom(to: node) } }
        Button("Add to Collector") { model.addToCollector(node) }
            .disabled(model.isShowingSavedScan)
        Button("Show in Finder") { model.revealInFinder(node) }
        Button("Quick Look") { model.quickLook(node) }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
    }
}
