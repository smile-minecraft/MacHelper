import AppKit
import SwiftUI

/// Top-level tabs: the selected one sits on a raised pill (magpie-style).
struct TabStrip<Value: Hashable>: View {
    let items: [(Value, LocalizedStringKey)]
    var icons: [Value: String] = [:]
    @Binding var selection: Value
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.0 == selection
                Button { selection = item.0 } label: {
                    HStack(spacing: 5) {
                        if let icon = icons[item.0] { PixelIcon(name: icon, size: 14) }
                        Text(item.1)
                            .font(.mh(size: 13, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Palette.text : Palette.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if selected {
                            SurfaceShape(cornerRadius: 7, style: .continuous).fill(Palette.raised)
                                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Palette.inset, in: SurfaceShape(cornerRadius: 9, style: .continuous))
        .animation(Motion.reduced ? nil : .snappy(duration: 0.2), value: selection)
    }
}

/// Small filter chips (time ranges and the like).
struct ChipBar<Value: Hashable>: View {
    let items: [(Value, LocalizedStringKey)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.0 == selection
                Button { selection = item.0 } label: {
                    Text(item.1)
                        .font(.mh(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Palette.text : Palette.textMuted)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(selected ? Palette.raised : .clear, in: SurfaceShape(cornerRadius: 6, style: .continuous))
                        .overlay(SurfaceShape(cornerRadius: 6, style: .continuous).strokeBorder(selected ? Palette.stroke : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Label, big monospaced value, a colored detail line and an optional sparkline.
struct StatCard: View {
    let title: LocalizedStringKey
    let value: String
    var detail: String?
    var detailColor: Color = Palette.textMuted
    var accent: Color = Theme.accent
    var symbol: String?
    var spark: [Double] = []
    var sparkMax: Double?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.mh(size: 10, weight: .semibold)).foregroundStyle(accent)
                }
                Text(title).font(Theme.label).foregroundStyle(Palette.textMuted).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(compact ? Theme.mediumNumeral : Theme.numeral)
                .foregroundStyle(Palette.text)
                .lineLimit(1).minimumScaleFactor(0.55)
            Text(detail ?? " ").font(.mh(size: 10.5)).foregroundStyle(detailColor).lineLimit(1)
            if !spark.isEmpty {
                AreaSparkline(values: spark, maxValue: sparkMax, color: accent)
                    .equatable()
                    .frame(height: compact ? 22 : 34)
                    .padding(.top, 2)
            }
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

/// A list row with a leading marker, title, trailing value, a progress bar and a caption (magpie-style).
struct MeterRow<Leading: View>: View {
    let title: String
    let value: String
    let fraction: Double
    var color: Color = Theme.accent
    var caption: String?
    var captionColor: Color = Palette.textFaint
    @ViewBuilder var leading: Leading

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                leading
                Text(title).font(.mh(size: 12.5, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(value).font(Theme.smallNumeral).foregroundStyle(Palette.text)
            }
            Meter(fraction: fraction, color: color)
            if let caption { Text(caption).font(.mh(size: 10.5)).foregroundStyle(captionColor).lineLimit(1) }
        }
        .padding(.vertical, 4)
    }
}

struct Meter: View {
    let fraction: Double
    var color: Color = Theme.accent

    var body: some View {
        if ThemeStore.shared.isPixel {
            PixelBlocks(fraction: fraction, color: color, track: Palette.inset).frame(height: 8)
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    SurfaceShape.capsule.fill(Palette.inset)
                    SurfaceShape.capsule.fill(color.gradient)
                        .frame(width: max(geo.size.width * min(max(fraction, 0), 1), fraction > 0 ? 3 : 0))
                }
            }
            .frame(height: 8)
            .animation(Motion.meter(0.35), value: fraction)
        }
    }
}

/// A row of square blocks lit up to `fraction`, like a game health bar.
struct PixelBlocks: View, Equatable {
    let fraction: Double
    let color: Color
    let track: Color
    var block: CGFloat = 6
    var gap: CGFloat = 2

    var body: some View {
        Canvas { ctx, size in
            let count = max(Int((size.width + gap) / (block + gap)), 1)
            let w = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let lit = Int((min(max(fraction, 0), 1) * Double(count)).rounded(.up))
            for i in 0..<count {
                let r = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                ctx.fill(Path(r), with: .color(i < lit && fraction > 0 ? color : track))
            }
        }
        .accessibilityHidden(true)
    }
}

struct IconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.mh(size: 12, weight: .medium))
                .foregroundStyle(hover ? Palette.text : Palette.textMuted)
                .frame(width: 26, height: 26)
                .background(hover ? Palette.inset : .clear, in: SurfaceShape(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hover = $0 }
    }
}

/// A settings caption or warning: wraps instead of truncating and keeps the shared muted color
/// unless a warning tone is passed in.
struct SettingsCaption: ViewModifier {
    var color: Color = Palette.textMuted

    func body(content: Content) -> some View {
        content
            .font(.mhCaption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    func settingsCaption(_ color: Color = Palette.textMuted) -> some View {
        modifier(SettingsCaption(color: color))
    }

    /// The surface under a settings form, matching the main window while keeping native controls.
    func settingsSurface() -> some View {
        scrollContentBackground(.hidden).background(Palette.base)
    }
}

/// Section caption inside a panel.
struct SectionLabel: View {
    let text: LocalizedStringKey
    var trailing: String?
    var body: some View {
        HStack {
            Text(text).font(.mh(size: 11, weight: .semibold)).foregroundStyle(Palette.textMuted)
            Spacer()
            if let trailing { Text(trailing).font(.mh(size: 10.5)).foregroundStyle(Palette.textFaint) }
        }
    }
}

// MARK: - Dense, card-less pieces (Stats-like)

/// Small centered section title between two hairlines.
struct HairlineHeader: View {
    let text: LocalizedStringKey
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Text(text).font(ThemeStore.shared.isPixel ? .display(11) : .mh(size: 11, weight: .semibold)).foregroundStyle(Palette.textMuted).fixedSize()
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A ring gauge with the value in the middle and a caption below. Thick, with a recessed track and a
/// lit stroke so it reads as an object rather than a line.
struct RingGauge: View {
    let fraction: Double
    let value: String
    let caption: LocalizedStringKey
    var color: Color = Theme.accent
    var size: CGFloat = 84
    var lineWidth: CGFloat = 10

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if ThemeStore.shared.isPixel {
                    PixelRing(fraction: fraction, color: color, track: Palette.inset, lineWidth: lineWidth)
                } else {
                    // Recessed track.
                    Circle().stroke(Palette.inset, lineWidth: lineWidth)
                    Circle().stroke(Color.black.opacity(0.10), lineWidth: 1)
                        .padding(lineWidth / 2).blendMode(.multiply)
                    // Lit progress stroke.
                    Circle()
                        .trim(from: 0, to: min(max(fraction, 0.001), 1))
                        .stroke(AngularGradient(colors: [color.opacity(0.78), color], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(360 * max(fraction, 0.01))),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: color.opacity(0.35), radius: 3, y: 1.5)
                        .animation(Motion.meter(0.5), value: fraction)
                }
                Text(value)
                    .font(.display(size * 0.22, weight: .bold).monospacedDigit())
                    .foregroundStyle(Palette.text)
                    .minimumScaleFactor(0.55).lineLimit(1)
                    .padding(.horizontal, lineWidth + 4)
            }
            .frame(width: size, height: size)
            Text(caption).font(.mh(size: 12, weight: .medium)).foregroundStyle(Palette.textMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Pixel-style ring: one continuous band with square ends and a flat track (no gaps, no glow).
struct PixelRing: View {
    let fraction: Double
    let color: Color
    let track: Color
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            // Whole steps of 1/24, drawn without easing: the ring jumps a block at a time like the bars.
            Circle()
                .trim(from: 0, to: (min(max(fraction, 0), 1) * 24).rounded() / 24)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

struct KeyValueRow: View {
    let label: String
    let value: String
    var dot: Color?
    var valueColor: Color = Palette.text

    var body: some View {
        HStack(spacing: 9) {
            if let dot { SurfaceShape(cornerRadius: 2.5).fill(dot).frame(width: 9, height: 9) }
            Text(label).font(.mh(size: 13)).foregroundStyle(Palette.textMuted).lineLimit(1)
            Spacer(minLength: 10)
            Text(value).font(.display(13).monospacedDigit()).foregroundStyle(valueColor).lineLimit(1)
        }
        .frame(height: 25)
    }
}

/// One bar per core, height = usage; performance and efficiency cores in their own colors.
struct CoreBars: View, Equatable {
    let values: [Double]
    var kinds: [Bool] = []          // true = performance core
    var performance: Color = Theme.blue
    var efficiency: Color = Theme.cyan

    var body: some View {
        Canvas { ctx, size in
            guard !values.isEmpty else { return }
            let gap: CGFloat = 6
            let w = (size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
            for (i, v) in values.enumerated() {
                let color = (i < kinds.count && kinds[i]) ? performance : efficiency
                let x = CGFloat(i) * (w + gap)
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: w, height: size.height), cornerRadius: ThemeStore.shared.isPixel ? 0 : 5),
                         with: .color(color.opacity(0.13)))
                let h = max(size.height * CGFloat(min(max(v, 0), 1)), 4)
                let bar = CGRect(x: x, y: size.height - h, width: w, height: h)
                // Lit top, deeper base: reads as a solid column.
                ctx.fill(Path(roundedRect: bar, cornerRadius: ThemeStore.shared.isPixel ? 0 : 5),
                         with: .linearGradient(Gradient(colors: [color, color.opacity(0.72)]),
                                               startPoint: CGPoint(x: 0, y: bar.minY), endPoint: CGPoint(x: 0, y: bar.maxY)))
                ctx.fill(Path(roundedRect: CGRect(x: bar.minX + 2, y: bar.minY + 1.5, width: bar.width - 4, height: 2), cornerRadius: 1),
                         with: .color(.white.opacity(0.28)))
            }
        }
        .accessibilityLabel("Per-core usage")
    }
}

/// Semicircle gauge in green / yellow / red with a needle (memory pressure).
struct PressureGauge: View {
    /// 0 = normal … 1 = critical.
    let level: Double
    let label: String
    var size: CGFloat = 76

    var body: some View {
        VStack(spacing: 2) {
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height - 4)
                let r = min(sz.width / 2, sz.height) - 6
                let segments: [(Double, Double, Color)] = [(180, 240, Theme.mint), (242, 298, Theme.amber), (300, 360, Theme.rose)]
                for (a0, a1, color) in segments {
                    var arc = Path()
                    arc.addArc(center: c, radius: r, startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
                    ctx.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                }
                let angle = Angle.degrees(180 + 180 * min(max(level, 0.04), 0.96)).radians
                var needle = Path()
                needle.move(to: c)
                needle.addLine(to: CGPoint(x: c.x + cos(angle) * (r - 14), y: c.y + sin(angle) * (r - 14)))
                ctx.stroke(needle, with: .color(Palette.text), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(Palette.text))
            }
            .frame(width: size, height: size * 0.6)
            Text(label).font(.mh(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}

/// A ring split into colored segments (memory: app / wired / compressed), value in the middle.
struct SegmentedRing: View {
    let segments: [(Double, Color)]   // fractions of the whole
    let value: String
    var size: CGFloat = 100
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().stroke(Palette.inset, style: ringStyle)
            ForEach(Array(starts.enumerated()), id: \.offset) { i, start in
                Circle()
                    .trim(from: start, to: min(start + segments[i].0, 1))
                    .stroke(segments[i].1, style: ringStyle)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: segments[i].1.opacity(ThemeStore.shared.isPixel ? 0 : 0.3), radius: 2, y: 1)
            }
            Text(value).font(.display(size * 0.22, weight: .bold).monospacedDigit()).foregroundStyle(Palette.text)
        }
        .frame(width: size, height: size)
        .animation(Motion.meter(0.4), value: segments.map(\.0))
    }

    private var ringStyle: StrokeStyle { StrokeStyle(lineWidth: lineWidth, lineCap: .butt) }

    private var starts: [Double] {
        var acc = 0.0
        return segments.map { s in defer { acc += s.0 }; return acc }
    }
}

/// Horizontal bar split into colored parts.
struct StackedBar: View {
    let parts: [(Double, Color)]
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Rectangle().fill(p.1).frame(width: geo.size.width * min(max(p.0, 0), 1))
                }
                Spacer(minLength: 0)
            }
            .background(Palette.inset)
            .clipShape(SurfaceShape(cornerRadius: height / 2, style: .continuous))
        }
        .frame(height: height)
    }
}

/// Two series mirrored around a center line (download above, upload below), like Stats' network chart.
struct MirroredHistory: View, Equatable {
    let up: [Double]
    let down: [Double]
    var upColor: Color = Theme.blue
    var downColor: Color = Theme.rose

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            let peak = max((up + down).max() ?? 1, 1)
            func draw(_ values: [Double], _ color: Color, above: Bool) {
                guard values.count > 1 else { return }
                let step = size.width / CGFloat(values.count - 1)
                var p = Path()
                p.move(to: CGPoint(x: 0, y: mid))
                for (i, v) in values.enumerated() {
                    let h = mid * CGFloat(v / peak) * 0.95
                    p.addLine(to: CGPoint(x: CGFloat(i) * step, y: above ? mid - h : mid + h))
                }
                p.addLine(to: CGPoint(x: size.width, y: mid))
                p.closeSubpath()
                ctx.fill(p, with: .color(color.opacity(0.55)))
            }
            draw(up, upColor, above: true)
            draw(down, downColor, above: false)
            ctx.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(Palette.textFaint.opacity(0.4)))
        }
        .background(Palette.inset.opacity(0.5))
        .clipShape(SurfaceShape(cornerRadius: 6, style: .continuous))
    }
}

/// Flat area history (no axes) for the popover.
struct HistoryArea: View, Equatable {
    let values: [Double]
    var maxValue: Double? = 1
    var color: Color = Theme.blue

    var body: some View {
        ZStack(alignment: .bottom) {
            // Quarter grid lines.
            VStack(spacing: 0) {
                ForEach(0..<4) { _ in
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                    Spacer(minLength: 0)
                }
            }
            AreaSparkline(values: values, maxValue: maxValue, color: color, lineWidth: 2)
        }
        .padding(.top, 1)
        .background(Palette.inset.opacity(0.5))
        .clipShape(SurfaceShape(cornerRadius: 6, style: .continuous))
    }
}

/// Placeholder rows shown while the first sample arrives (instead of a spinner).
struct SkeletonRows: View {
    var count = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        VStack(spacing: 9) {
            ForEach(0..<count, id: \.self) { i in
                HStack {
                    SurfaceShape(cornerRadius: 3).frame(width: 14, height: 14)
                    SurfaceShape(cornerRadius: 3).frame(width: CGFloat(90 + (i * 37) % 70), height: 9)
                    Spacer()
                    SurfaceShape(cornerRadius: 3).frame(width: 38, height: 9)
                }
            }
        }
        .foregroundStyle(Palette.inset)
        .opacity(dim ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityLabel("Loading")
    }
}

/// Press feedback for plain rows/tiles.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// One bordered surface split into a grid by hairlines (no gaps, no nested cards).
struct HairlinePanel<Content: View>: View {
    let columns: Int
    @ViewBuilder var content: Content

    var body: some View {
        _VariadicView.Tree(HairlineGridLayout(columns: columns)) { content }
            .clipShape(SurfaceShape(cornerRadius: Theme.cardRadius))
            .surface()
    }
}

private struct HairlineGridLayout: _VariadicView_MultiViewRoot {
    let columns: Int

    func body(children: _VariadicView.Children) -> some View {
        let rows = stride(from: 0, to: children.count, by: columns).map { Array(children[$0..<min($0 + columns, children.count)]) }
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { c, child in
                        child
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .overlay(alignment: .trailing) {
                                if c < columns - 1 { Rectangle().fill(Palette.hairline).frame(width: 1) }
                            }
                    }
                    if row.count < columns {
                        ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if r < rows.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
        }
    }
}

/// Motion rules shared by the gauges: they glide to a new value in the standard look, jump in the
/// pixel look (it is drawn in whole blocks), and stand still with Reduce Motion.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func meter(_ duration: Double) -> Animation? {
        reduced || ThemeStore.shared.isPixel ? nil : .easeOut(duration: duration)
    }
}
