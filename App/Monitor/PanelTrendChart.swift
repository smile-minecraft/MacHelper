import Charts
import Storage
import SwiftUI

/// Time range of the trend charts on the network, power and fan pages. Five minutes comes from
/// the live series in memory; the longer ranges come from the shared minute history.
enum PanelRange: String, CaseIterable, Identifiable {
    case live, hour, day
    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .live: 300
        case .hour: 3600
        case .day: 86_400
        }
    }

    /// Bucket for the history query and the downsampling of live points.
    var bucket: TimeInterval {
        switch self {
        case .live: 2
        case .hour: 60
        case .day: 600
        }
    }

    /// Two points further apart than this are drawn as separate runs, never joined across a gap.
    var gap: TimeInterval { self == .live ? 15 : bucket * 2.5 }

    var title: LocalizedStringKey {
        switch self {
        case .live: "5 min"
        case .hour: "1 hour"
        case .day: "24 hours"
        }
    }

    static var chips: [(PanelRange, LocalizedStringKey)] { allCases.map { ($0, $0.title) } }
}

/// One line of a trend chart. Secondary series are scaled onto the trailing axis.
struct TrendSeries: Identifiable {
    let id: String
    let name: String
    let color: Color
    let points: [ChartPoint]
    var secondary = false
    var filled = true
}

/// The trailing axis of a two-axis chart: its fixed domain and label format.
struct SecondaryAxis {
    let domain: ClosedRange<Double>
    let format: (Double) -> String
}

/// Area/line chart with axis labels and a hover readout (time plus every series' value at the
/// pointer), shared by the panel pages so they read the same way.
struct PanelTrendChart: View {
    let series: [TrendSeries]
    let range: PanelRange
    let format: (Double) -> String
    var secondary: SecondaryAxis?
    /// Fixed primary domain (fan rpm). nil scales to the data, never below `minimumMax`.
    var primaryDomain: ClosedRange<Double>?
    var minimumMax: Double = 1
    var height: CGFloat = 150

    @State private var hover: Date?

    private var domain: ClosedRange<Double> {
        if let primaryDomain { return primaryDomain }
        let peak = series.filter { !$0.secondary }.flatMap(\.points).map(\.value).max() ?? 0
        return 0...max(peak * 1.18, minimumMax)
    }

    private var xDomain: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-range.seconds)...now
    }

    /// Maps a secondary value onto the primary scale.
    private func scaled(_ v: Double) -> Double {
        guard let s = secondary else { return v }
        let d = domain
        let f = (v - s.domain.lowerBound) / max(s.domain.upperBound - s.domain.lowerBound, .ulpOfOne)
        return d.lowerBound + min(max(f, 0), 1) * (d.upperBound - d.lowerBound)
    }

    private func unscaled(_ v: Double) -> Double {
        guard let s = secondary else { return v }
        let d = domain
        let f = (v - d.lowerBound) / max(d.upperBound - d.lowerBound, .ulpOfOne)
        return s.domain.lowerBound + f * (s.domain.upperBound - s.domain.lowerBound)
    }

    private var ticks: [Double] {
        let d = domain
        return (0...4).map { d.lowerBound + Double($0) / 4 * (d.upperBound - d.lowerBound) }
    }

    var body: some View {
        let d = domain
        Chart {
            ForEach(series) { s in
                ForEach(Array(segments(s.points).enumerated()), id: \.offset) { index, run in
                    let key = "\(s.id)·\(index)"
                    ForEach(run, id: \.date) { p in
                        let y = s.secondary ? scaled(p.value) : p.value
                        if s.filled {
                            AreaMark(x: .value("Time", p.date), yStart: .value("Base", d.lowerBound), yEnd: .value("Value", y),
                                     series: .value("Run", key))
                                .foregroundStyle(LinearGradient(colors: [s.color.opacity(0.42), s.color.opacity(0.03)],
                                                                startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                        }
                        LineMark(x: .value("Time", p.date), y: .value("Value", y), series: .value("Run", key))
                            .foregroundStyle(s.color)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                }
            }
            if let hover {
                RuleMark(x: .value("Time", hover))
                    .foregroundStyle(Palette.textMuted.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(at: hover)
                    }
                ForEach(series) { s in
                    if let p = nearest(s.points, to: hover) {
                        PointMark(x: .value("Time", p.date), y: .value("Value", s.secondary ? scaled(p.value) : p.value))
                            .foregroundStyle(s.color)
                            .symbolSize(36)
                    }
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: d)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Palette.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(format(v)).font(.mh(size: 9.5).monospacedDigit()).foregroundStyle(Palette.textFaint)
                    }
                }
            }
            if let secondary {
                AxisMarks(position: .trailing, values: ticks) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(secondary.format(unscaled(v))).font(.mh(size: 9.5).monospacedDigit()).foregroundStyle(Palette.textFaint)
                        }
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Palette.hairline)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.mh(size: 9.5))
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let frame = proxy.plotFrame else { hover = nil; return }
                            let x = location.x - geo[frame].origin.x
                            guard x >= 0, x <= geo[frame].width, let date: Date = proxy.value(atX: x) else { hover = nil; return }
                            hover = date
                        case .ended:
                            hover = nil
                        }
                    }
            }
        }
        .frame(height: height)
        .transaction { $0.animation = nil }
    }

    private func tooltip(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date, format: range == .live ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
                .font(.mh(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.text)
            ForEach(series) { s in
                HStack(spacing: 5) {
                    Circle().fill(s.color).frame(width: 6, height: 6)
                    Text(s.name).font(.mh(size: 10.5)).foregroundStyle(Palette.textMuted)
                    Spacer(minLength: 8)
                    Text(nearest(s.points, to: date).map { s.secondary ? secondary?.format($0.value) ?? format($0.value) : format($0.value) } ?? "–")
                        .font(.display(10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Palette.text)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(minWidth: 120)
        .background(Palette.raised, in: SurfaceShape(cornerRadius: 7, style: .continuous))
        .overlay(SurfaceShape(cornerRadius: 7, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    /// The point closest to `date`, if it lies within one gap of it (no readout across a gap).
    private func nearest(_ points: [ChartPoint], to date: Date) -> ChartPoint? {
        guard !points.isEmpty else { return nil }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].date < date { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [points[lo], points[max(lo - 1, 0)]]
        guard let best = candidates.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
              abs(best.date.timeIntervalSince(date)) <= range.gap else { return nil }
        return best
    }

    private func segments(_ points: [ChartPoint]) -> [[ChartPoint]] {
        var runs: [[ChartPoint]] = []
        for p in points {
            if let last = runs.last?.last, p.date.timeIntervalSince(last.date) <= range.gap {
                runs[runs.count - 1].append(p)
            } else {
                runs.append([p])
            }
        }
        return runs
    }
}

/// Title row of a panel card: title, optional subtitle, then trailing content (legend, chips).
struct PanelCardHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(.mh(size: 13.5, weight: .bold)).foregroundStyle(Palette.text).fixedSize()
            if let subtitle {
                Text(subtitle).font(.mh(size: 10.5)).foregroundStyle(Palette.textFaint).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .accessibilityAddTraits(.isHeader)
    }
}

extension PanelCardHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Colored dot plus name, for chart legends.
struct LegendDot: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            SurfaceShape(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title).font(.mh(size: 10.5)).foregroundStyle(Palette.textMuted).lineLimit(1)
        }
    }
}

/// Live points of the last five minutes, averaged into buckets so the chart stays light.
@MainActor
enum PanelSeries {
    static func live(_ store: MonitorStore, _ key: SeriesKey, bucket: TimeInterval = PanelRange.live.bucket) -> [ChartPoint] {
        let cutoff = Date().addingTimeInterval(-PanelRange.live.seconds)
        let points = (store.history[key] ?? []).filter { $0.date >= cutoff }
        return average(points, bucket: bucket)
    }

    static func average(_ points: [ChartPoint], bucket: TimeInterval) -> [ChartPoint] {
        guard bucket > 0, points.count > 1 else { return points }
        var out: [ChartPoint] = []
        var start = points[0].date, sum = 0.0, count = 0
        for p in points {
            if p.date.timeIntervalSince(start) >= bucket, count > 0 {
                out.append(ChartPoint(date: start, value: sum / Double(count)))
                start = p.date; sum = 0; count = 0
            }
            sum += p.value
            count += 1
        }
        if count > 0 { out.append(ChartPoint(date: start, value: sum / Double(count))) }
        return out
    }

    /// One stored column as chart points; minutes without a value are left out (shown as gaps).
    static func history(_ samples: [MetricSample], _ column: KeyPath<MetricSample, Double?>) -> [ChartPoint] {
        samples.compactMap { s in s[keyPath: column].map { ChartPoint(date: s.time, value: $0) } }
    }
}

/// Reads the shared minute history for the 1 hour and 24 hour ranges, off the main actor, and
/// refreshes once a minute while the range stays selected.
@MainActor
@Observable
final class PanelHistory {
    private(set) var samples: [MetricSample] = []
    private(set) var loadedRange: PanelRange?

    func run(_ range: PanelRange, history: MetricsHistory?) async {
        guard range != .live else { samples = []; loadedRange = .live; return }
        if loadedRange != range { samples = [] }
        while !Task.isCancelled {
            let since = Date().addingTimeInterval(-range.seconds)
            let bucket = range.bucket
            let rows = await Task.detached(priority: .utility) {
                (try? history?.samples(since: since, bucket: bucket)) ?? []
            }.value
            guard !Task.isCancelled else { return }
            samples = rows
            loadedRange = range
            try? await Task.sleep(for: .seconds(60))
        }
    }
}
