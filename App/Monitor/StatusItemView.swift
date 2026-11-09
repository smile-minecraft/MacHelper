import Diagnostics
import SwiftUI
import Theming

/// What the menu bar shows for one module: display text, an optional 0...1 fraction
/// for bar/ring styles, and the series used by the sparkline.
struct MenuBarItemModel: Identifiable, Equatable {
    let module: MonitorModule
    let text: String
    /// Optional second line (network up/down, disk read/write).
    let secondary: String?
    let fraction: Double?
    let series: [ChartPoint]
    /// Second series for dual styles (network upload, paired with `series` download).
    var secondarySeries: [ChartPoint]? = nil
    /// Warning / critical level for coloring; nil = no level for this metric.
    var level: StatusLevel? = nil
    var id: MonitorModule { module }
}

@MainActor
extension MonitorStore {
    func menuBarItems() -> [MenuBarItemModel] {
        MonitorModule.allCases.compactMap { m in
            guard isActive(m), settings[m].inMenuBar else { return nil }
            switch m {
            case .cpu:
                return .init(module: m, text: Fmt.percent(cpu?.total), secondary: nil, fraction: cpu?.total, series: history[.cpu] ?? [],
                             level: StatusRules.fraction(cpu?.total))
            case .gpu:
                return .init(module: m, text: Fmt.percent(gpu?.utilization), secondary: nil, fraction: gpu?.utilization, series: history[.gpu] ?? [],
                             level: StatusRules.fraction(gpu?.utilization))
            case .memory:
                let f = memory.map { Double($0.usedBytes) / Double(max($0.totalBytes, 1)) }
                return .init(module: m, text: Fmt.percent(f), secondary: nil, fraction: f, series: history[.memory] ?? [],
                             level: StatusRules.memory(memory)?.level)
            case .disk:
                let used = disk.map { 1 - Double($0.availableBytes) / Double(max($0.totalBytes, 1)) }
                return .init(module: m, text: disk.map { Fmt.compactBytes(Double($0.availableBytes)) } ?? "–",
                             secondary: nil, fraction: used, series: [], level: StatusRules.disk(freeBytes: diskFreeBytes)?.level)
            case .network:
                return .init(module: m, text: "↑" + Fmt.rate(network?.outBytesPerSecond),
                             secondary: "↓" + Fmt.rate(network?.inBytesPerSecond), fraction: nil, series: history[.netIn] ?? [],
                             secondarySeries: history[.netOut])
            case .battery:
                return .init(module: m, text: Fmt.percent(battery?.charge), secondary: nil, fraction: battery?.charge, series: history[.battery] ?? [])
            case .temperature:
                return .init(module: m, text: Fmt.celsius(cpuCelsius), secondary: nil, fraction: nil, series: history[.temperature] ?? [],
                             level: StatusRules.temperature(cpuCelsius)?.level)
            case .fan:
                return .init(module: m, text: Fmt.rpm(fans.first?.actualRPM), secondary: nil, fraction: nil, series: history[.fan] ?? [])
            case .power:
                return .init(module: m, text: Fmt.watts(power?.systemWatts ?? power?.gpuWatts), secondary: nil, fraction: nil, series: history[.power] ?? [])
            }
        }
    }
}

/// The view hosted inside the NSStatusItem button.
struct StatusItemView: View {
    let store: MonitorStore
    var health: HealthModel? = nil
    @AppStorage(HealthScoreMenuBar.key) private var showHealthScore = false

    var body: some View {
        let compact = store.settings.configuration.compact
        let items = store.menuBarItemsCache
        let score = showHealthScore ? health?.score(store: store) : nil
        HStack(spacing: 8) {
            if let score {
                HealthScoreMenuBarItem(score: score, compact: compact)
            }
            if items.isEmpty, score == nil {
                PixelIcon(name: "px.monitor", size: 16, label: "MacHelper")
            }
            ForEach(items) { item in
                MenuBarItemView(item: item, style: store.settings[item.module].style, compact: compact)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .fixedSize()
    }
}

private struct MenuBarItemView: View {
    let item: MenuBarItemModel
    let style: MenuBarStyle
    let compact: Bool
    private var look: AppearanceSettings { ThemeStore.shared.settings }

    var body: some View {
        HStack(spacing: 3) {
            if compact && look.menuBarLabel == .text {
                VStack(alignment: .leading, spacing: -1) {
                    Text(item.module.shortLabel).font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                    valueText
                }
            } else {
                label
                valueText
            }
            graphic
        }
        .fixedSize()
    }

    @ViewBuilder private var label: some View {
        switch look.menuBarLabel {
        case .icon: PixelIcon(name: Self.icon(item.module), size: 14, label: LocalizedStringKey(item.module.title))
        case .text: Text(item.module.shortLabel).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        case .none: EmptyView()
        }
    }

    static func icon(_ m: MonitorModule) -> String {
        switch m {
        case .cpu: "px.cpu"
        case .gpu: "px.gpu"
        case .memory: "px.memory"
        case .disk: "px.ssd"
        case .network: "px.network"
        case .battery: "px.battery"
        case .temperature: "px.temperature"
        case .fan: "px.fans"
        case .power: "px.power"
        }
    }

    /// Only values past a threshold are colored; normal ones keep the menu bar's own text color.
    private var valueStyle: AnyShapeStyle {
        if look.menuBarColored, let level = item.level, level != .good { return AnyShapeStyle(ThemeStore.menuBarTint(level)) }
        return AnyShapeStyle(.primary)
    }

    /// Faint pill fill for heat: status tint when past a threshold, neutral otherwise.
    private var heatBackground: Color {
        if look.menuBarColored, let level = item.level, level != .good { return ThemeStore.menuBarTint(level).opacity(0.22) }
        return Color.secondary.opacity(0.12)
    }

    /// The widest text this module can show: values are laid out in this fixed width, so the item never
    /// changes size (or shifts its neighbours) as numbers change.
    private var template: String {
        switch item.module {
        case .cpu, .gpu, .memory, .battery: "100%"
        case .disk: "888G"
        case .network: "↑888K"
        case .temperature: "100°"
        case .fan: "8888"
        case .power: "88.8W"
        }
    }

    private func fixed(_ text: String) -> some View {
        ZStack(alignment: .trailing) {
            Text(template).hidden()
            Text(text)
        }
    }

    @ViewBuilder private var valueText: some View {
        if style == .heat {
            plainValueText
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(heatBackground))
        } else {
            plainValueText
        }
    }

    @ViewBuilder private var plainValueText: some View {
        if let secondary = item.secondary {
            // Two lines need the small system face; the pixel font has no size that fits twice in 22 pt.
            VStack(alignment: .trailing, spacing: -2) {
                fixed(item.text)
                fixed(secondary)
            }
            .font(.system(size: 8, weight: .medium).monospacedDigit())
            .foregroundStyle(valueStyle)
        } else {
            fixed(item.text)
                .font(ThemeStore.shared.menuBarFont(size: compact && look.menuBarLabel == .text ? 10.5 : 12))
                .foregroundStyle(valueStyle)
        }
    }

    @ViewBuilder private var graphic: some View {
        switch style {
        case .text:
            EmptyView()
        case .heat:
            EmptyView()
        case .dual:
            MenuBarDualLines(primary: Array(item.series.suffix(40)), secondary: Array((item.secondarySeries ?? []).suffix(40)),
                             fixedMax: item.fraction != nil ? 1 : nil)
                .frame(width: 30, height: 14)
        case .sparkline:
            Sparkline(points: item.series.suffix(40), fixedMax: item.fraction != nil ? 1 : nil)
                .frame(width: 30, height: 14)
        case .bar:
            if let f = item.fraction {
                ZStack(alignment: .bottom) {
                    SurfaceShape(cornerRadius: 1).fill(.secondary.opacity(0.3))
                    SurfaceShape(cornerRadius: 1).fill(.primary).frame(height: 14 * min(max(f, 0), 1))
                }
                .frame(width: 4, height: 14)
            }
        case .ring:
            if let f = item.fraction {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.3), lineWidth: 2)
                    Circle().trim(from: 0, to: min(max(f, 0), 1)).stroke(.primary, style: .init(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
            }
        case .blocks:
            if let f = item.fraction {
                MenuBarBlocks(fraction: f, tint: item.level.flatMap { look.menuBarColored && $0 != .good ? ThemeStore.menuBarTint($0) : nil })
                    .frame(width: 5, height: 15)
            }
        case .columns:
            MenuBarColumns(values: item.series.suffix(12).map(\.value), fixedMax: item.fraction != nil ? 1 : nil)
                .frame(width: 26, height: 14)
        }
    }
}

/// A vertical meter of five blocks (pixel style).
private struct MenuBarBlocks: View {
    let fraction: Double
    var tint: Color?

    var body: some View {
        Canvas { ctx, size in
            let n = 5, gap: CGFloat = 1
            let h = (size.height - gap * CGFloat(n - 1)) / CGFloat(n)
            let lit = Int((min(max(fraction, 0), 1) * Double(n)).rounded(.up))
            for i in 0..<n {
                let r = CGRect(x: 0, y: size.height - CGFloat(i + 1) * h - CGFloat(i) * gap, width: size.width, height: h)
                let on = i < lit && fraction > 0
                ctx.fill(Path(r), with: on ? (tint.map { .color($0) } ?? .foreground) : .color(.secondary.opacity(0.3)))
            }
        }
    }
}

/// Recent values as block columns, snapped to a 2 pt grid so they stay crisp.
private struct MenuBarColumns: View {
    let values: [Double]
    var fixedMax: Double?

    var body: some View {
        Canvas { ctx, size in
            guard !values.isEmpty else { return }
            let top = fixedMax ?? max(values.max() ?? 1, .ulpOfOne)
            let w: CGFloat = 2
            let step = size.width / CGFloat(max(values.count, 1))
            for (i, v) in values.enumerated() {
                let h = max(2, (size.height * CGFloat(min(v / top, 1)) / 2).rounded() * 2)
                ctx.fill(Path(CGRect(x: CGFloat(i) * step, y: size.height - h, width: w, height: h)), with: .foreground)
            }
        }
    }
}

/// Lightweight line drawn with a Path (Swift Charts is too heavy for the menu bar).
struct Sparkline<C: Collection>: View where C.Element == ChartPoint {
    let points: C
    /// Fixed scale top (1 for fractions); nil → scale to the data.
    var fixedMax: Double?

    var body: some View {
        Canvas { ctx, size in
            let values = points.map(\.value)
            guard values.count > 1 else { return }
            let top = fixedMax ?? max(values.max() ?? 1, .ulpOfOne)
            let bottom = fixedMax != nil ? 0 : min(values.min() ?? 0, top * 0.8)
            let span = max(top - bottom, .ulpOfOne)
            let step = size.width / CGFloat(values.count - 1)
            var path = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat((v - bottom) / span)))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }
}

/// Two lines sharing one scale (network download above upload), both anchored to the bottom.
private struct MenuBarDualLines: View {
    let primary: [ChartPoint]
    let secondary: [ChartPoint]
    /// Fixed scale top (1 for fractions); nil → scale to the data.
    var fixedMax: Double?

    var body: some View {
        Canvas { ctx, size in
            let a = primary.map(\.value)
            let b = secondary.map(\.value)
            guard a.count > 1 || b.count > 1 else { return }
            let all = a + b
            let top = fixedMax ?? max(all.max() ?? 1, .ulpOfOne)
            let bottom = fixedMax != nil ? 0 : min(all.min() ?? 0, top * 0.8)
            let span = max(top - bottom, .ulpOfOne)
            func path(for values: [Double]) -> Path? {
                guard values.count > 1 else { return nil }
                let step = size.width / CGFloat(values.count - 1)
                var p = Path()
                for (i, v) in values.enumerated() {
                    let y = size.height * (1 - CGFloat((v - bottom) / span))
                    let pt = CGPoint(x: CGFloat(i) * step, y: y)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            if let p = path(for: b) {
                ctx.stroke(p, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
            if let p = path(for: a) {
                ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
        }
    }
}

/// The health score in the menu bar: a label (icon, "HP" or nothing, like the other items) and the
/// number, colored only when it isn't good.
enum HealthScoreMenuBar {
    static let key = "menuBar.healthScore"
}

private struct HealthScoreMenuBarItem: View {
    let score: HealthScore
    let compact: Bool
    private var look: AppearanceSettings { ThemeStore.shared.settings }

    private var level: StatusLevel {
        switch score.level {
        case .good: .good
        case .attention: .attention
        case .critical: .critical
        }
    }

    var body: some View {
        let value = ZStack(alignment: .trailing) {
            Text(verbatim: "100").hidden()
            Text(verbatim: "\(score.value)")
                .foregroundStyle(look.menuBarColored && level != .good ? AnyShapeStyle(ThemeStore.menuBarTint(level)) : AnyShapeStyle(.primary))
        }
        .font(ThemeStore.shared.menuBarFont(size: compact && look.menuBarLabel == .text ? 10.5 : 12))
        .monospacedDigit()
        HStack(spacing: 3) {
            if compact && look.menuBarLabel == .text {
                VStack(alignment: .leading, spacing: -1) {
                    Text(verbatim: "HP").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
                    value
                }
            } else {
                switch look.menuBarLabel {
                case .icon: PixelIcon(name: "px.health", size: 14, label: "Health score")
                case .text: Text(verbatim: "HP").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                case .none: EmptyView()
                }
                value
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Health score"))
        .accessibilityValue(Text(verbatim: "\(score.value)"))
    }
}
