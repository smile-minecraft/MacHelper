import SwiftUI

/// What the menu bar shows for one module: display text, an optional 0...1 fraction
/// for bar/ring styles, and the series used by the sparkline.
struct MenuBarItemModel: Identifiable {
    let module: MonitorModule
    let text: String
    /// Optional second line (network up/down, disk read/write).
    let secondary: String?
    let fraction: Double?
    let series: [ChartPoint]
    var id: MonitorModule { module }
}

@MainActor
extension MonitorStore {
    func menuBarItems() -> [MenuBarItemModel] {
        MonitorModule.allCases.compactMap { m in
            guard isActive(m), settings[m].inMenuBar else { return nil }
            switch m {
            case .cpu:
                return .init(module: m, text: Fmt.percent(cpu?.total), secondary: nil, fraction: cpu?.total, series: history[.cpu] ?? [])
            case .gpu:
                return .init(module: m, text: Fmt.percent(gpu?.utilization), secondary: nil, fraction: gpu?.utilization, series: history[.gpu] ?? [])
            case .memory:
                let f = memory.map { Double($0.usedBytes) / Double(max($0.totalBytes, 1)) }
                return .init(module: m, text: Fmt.percent(f), secondary: nil, fraction: f, series: history[.memory] ?? [])
            case .disk:
                let used = disk.map { 1 - Double($0.availableBytes) / Double(max($0.totalBytes, 1)) }
                return .init(module: m, text: disk.map { Fmt.compactBytes(Double($0.availableBytes)) } ?? "–",
                             secondary: nil, fraction: used, series: [])
            case .network:
                return .init(module: m, text: "↑" + Fmt.rate(network?.outBytesPerSecond),
                             secondary: "↓" + Fmt.rate(network?.inBytesPerSecond), fraction: nil, series: history[.netIn] ?? [])
            case .battery:
                return .init(module: m, text: Fmt.percent(battery?.charge), secondary: nil, fraction: battery?.charge, series: history[.battery] ?? [])
            case .temperature:
                return .init(module: m, text: Fmt.celsius(cpuCelsius), secondary: nil, fraction: nil, series: history[.temperature] ?? [])
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
    /// Reports the natural width so the status item can resize itself.
    var onWidthChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        let compact = store.settings.configuration.compact
        let items = store.menuBarItems()
        HStack(spacing: 8) {
            if items.isEmpty {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
            ForEach(items) { item in
                MenuBarItemView(item: item, style: store.settings[item.module].style, compact: compact)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .fixedSize()
        .background(GeometryReader { geo in
            Color.clear.preference(key: WidthKey.self, value: geo.size.width)
        })
        .onPreferenceChange(WidthKey.self) { onWidthChange($0) }
    }

    private struct WidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }
}

private struct MenuBarItemView: View {
    let item: MenuBarItemModel
    let style: MenuBarStyle
    let compact: Bool

    var body: some View {
        HStack(spacing: 3) {
            if compact {
                VStack(alignment: .leading, spacing: -1) {
                    Text(item.module.shortLabel).font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                    valueText
                }
            } else {
                Text(item.module.shortLabel).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                valueText
            }
            graphic
        }
        .fixedSize()
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
        if let secondary = item.secondary {
            VStack(alignment: .trailing, spacing: -2) {
                fixed(item.text)
                fixed(secondary)
            }
            .font(.system(size: 8, weight: .medium).monospacedDigit())
        } else {
            fixed(item.text).font(.system(size: compact ? 10 : 11, weight: .medium).monospacedDigit())
        }
    }

    @ViewBuilder private var graphic: some View {
        switch style {
        case .text:
            EmptyView()
        case .sparkline:
            Sparkline(points: item.series.suffix(40), fixedMax: item.fraction != nil ? 1 : nil)
                .frame(width: 30, height: 14)
        case .bar:
            if let f = item.fraction {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.3))
                    RoundedRectangle(cornerRadius: 1).fill(.primary).frame(height: 14 * min(max(f, 0), 1))
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
