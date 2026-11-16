import Metrics
import SwiftUI

/// Menu bar power page: total power and its measured split, the power trend, then the fans
/// (speed, temperatures and mode) on the same page.
struct PanelPowerTab: View {
    let store: MonitorStore
    var openFanControl: () -> Void = {}
    @State private var history = PanelHistory()
    @AppStorage("panel.power.range") private var range: PanelRange = .live

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.availableModules.contains(.power) {
                if !store.isActive(.power) {
                    PanelEmptyState(symbol: "bolt.slash", title: "Power readings are off",
                                    detail: "Turn on Power in the menu bar settings to see where the power goes.")
                } else if let reading = store.power, let b = PowerBreakdown(reading) {
                    PowerSplitCard(breakdown: b)
                    trendCard(reading)
                } else {
                    SkeletonRows(count: 6).padding(.top, 8)
                }
            }
            if store.availableModules.contains(.fan) {
                PanelFanSection(store: store, openFanControl: openFanControl)
            }
        }
        .task(id: range) { await history.run(range, history: store.persistentHistory) }
    }

    private func trendCard(_ reading: PowerReading) -> some View {
        let series = trendSeries(systemRail: reading.hasSystemRail == true)
        return VStack(alignment: .leading, spacing: 10) {
            PanelCardHeader(title: "Power history") {
                ChipBar(items: PanelRange.chips, selection: $range)
            }
            HStack(spacing: 10) {
                ForEach(series) { LegendDot(color: $0.color, title: $0.name) }
            }
            PanelTrendChart(series: series, range: range, format: { Fmt.wattsLong($0) }, minimumMax: 5)
        }
        .padding(12)
        .surface(Palette.base)
    }

    private func trendSeries(systemRail: Bool) -> [TrendSeries] {
        // The stored column is system watts on a Mac with the system rail, GPU watts otherwise.
        let mainName = systemRail ? String(localized: "System") : String(localized: "GPU")
        guard range == .live else {
            return [TrendSeries(id: "power", name: mainName, color: Theme.violet, points: PanelSeries.history(history.samples, \.power))]
        }
        var out = [TrendSeries(id: "power", name: mainName, color: Theme.violet, points: PanelSeries.live(store, .power))]
        let cpu = PanelSeries.live(store, .cpuPower)
        if !cpu.isEmpty { out.append(TrendSeries(id: "cpu", name: String(localized: "CPU"), color: Theme.blue, points: cpu, filled: false)) }
        if systemRail {
            let gpu = PanelSeries.live(store, .gpuPower)
            if !gpu.isEmpty { out.append(TrendSeries(id: "gpu", name: String(localized: "GPU"), color: Theme.amber, points: gpu, filled: false)) }
        }
        return out
    }
}

extension PowerBreakdown.Part {
    var title: LocalizedStringKey {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .neuralEngine: "NPU"
        case .memory: "Memory"
        }
    }

    var color: Color {
        switch self {
        case .cpu: Theme.blue
        case .gpu: Theme.amber
        case .neuralEngine: Theme.mint
        case .memory: Theme.cyan
        }
    }
}

/// Total power, one bar split by the measured parts, and a row per part, largest first.
private struct PowerSplitCard: View {
    let breakdown: PowerBreakdown

    private struct Slice: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let watts: Double
        let color: Color
    }

    private var slices: [Slice] {
        var out = breakdown.components.map { Slice(id: $0.part.rawValue, title: $0.part.title, watts: $0.watts, color: $0.part.color) }
        if let rest = breakdown.rest, rest > 0 {
            out.append(Slice(id: "rest", title: "Rest of system", watts: rest, color: Theme.slate))
        }
        return out.sorted { $0.watts > $1.watts }
    }

    var body: some View {
        let slices = slices
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(breakdown.hasSystemRail ? "System total" : "Measured")
                    .font(.mh(size: 13.5, weight: .bold)).foregroundStyle(Palette.text)
                Spacer()
                Text(verbatim: Fmt.wattsLong(breakdown.total))
                    .font(.display(26, weight: .bold).monospacedDigit())
                    .foregroundStyle(Palette.text)
                    .contentTransition(.numericText())
            }
            splitBar(slices).frame(height: 14)
            VStack(spacing: 0) {
                ForEach(Array(slices.enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 8) {
                        SurfaceShape(cornerRadius: 2.5).fill(s.color).frame(width: 9, height: 9)
                        Text(s.title).font(.mh(size: 12.5)).foregroundStyle(Palette.text).lineLimit(1)
                        Spacer(minLength: 8)
                        Meter(fraction: breakdown.share(s.watts), color: s.color).frame(width: 90)
                        Text(verbatim: Fmt.share(breakdown.share(s.watts)))
                            .font(.mh(size: 11).monospacedDigit()).foregroundStyle(Palette.textFaint)
                            .frame(width: 46, alignment: .trailing)
                        Text(verbatim: Fmt.wattsLong(s.watts))
                            .font(.display(12.5, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.text)
                            .frame(width: 58, alignment: .trailing)
                    }
                    .frame(height: 28)
                    .overlay(alignment: .bottom) {
                        if i < slices.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(12)
        .surface(Palette.base)
    }

    /// Segments in the rows' order; a tiny part keeps a sliver so it stays visible.
    private func splitBar(_ slices: [Slice]) -> some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let usable = max(geo.size.width - gap * CGFloat(max(slices.count - 1, 0)), 0)
            let minWidth: CGFloat = 4
            let small = slices.filter { usable * CGFloat(breakdown.share($0.watts)) < minWidth }.count
            let spare = max(usable - CGFloat(small) * minWidth, 0)
            let bigTotal = slices.filter { usable * CGFloat(breakdown.share($0.watts)) >= minWidth }.reduce(0) { $0 + $1.watts }
            HStack(spacing: gap) {
                ForEach(slices) { s in
                    let natural = usable * CGFloat(breakdown.share(s.watts))
                    let width = natural < minWidth ? minWidth : spare * CGFloat(bigTotal > 0 ? s.watts / bigTotal : 0)
                    Rectangle().fill(s.color.gradient).frame(width: width)
                }
            }
            .clipShape(SurfaceShape(cornerRadius: 5, style: .continuous))
        }
    }
}

/// Shown in place of a page whose module is switched off or missing on this Mac.
struct PanelEmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.mh(size: 26, weight: .semibold)).foregroundStyle(Palette.textFaint)
            Text(title).font(.mh(size: 13.5, weight: .semibold)).foregroundStyle(Palette.text)
            Text(detail).font(.mh(size: 11.5)).foregroundStyle(Palette.textMuted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
