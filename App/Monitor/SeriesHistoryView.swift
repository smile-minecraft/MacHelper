import Charts
#if !MACHELPER_CHART_TEST
import Storage
#endif
import SwiftUI

/// The marks for one sensor group. This is the exact view the app draws; the chart
/// visibility test compiles this file with `-D MACHELPER_CHART_TEST` and renders this
/// type with SwiftUI's `ImageRenderer`, so the test never carries a copy of the chart.
struct SeriesHistoryChart: View {
    enum Format { case celsius, percent }
    enum Axis { case live, history, week }

    struct Plot: Identifiable {
        let id: String
        let name: String
        let color: Color
        let points: [SeriesBucket]
    }

    let title: LocalizedStringKey
    let plots: [Plot]
    let format: Format
    let axis: Axis
    let valueLabel: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Same header as the monitor charts: value beside the title, clear of the y-axis labels.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.mh(size: 12.5, weight: .semibold)).foregroundStyle(Palette.text)
                if let first = plots.first, let last = first.points.last {
                    Text(valueLabel(last.value)).font(Theme.smallNumeral).foregroundStyle(first.color)
                }
                Spacer()
            }
            Chart {
                ForEach(plots) { plot in
                    // A gap in the stored minutes leaves a gap: each run is its own series
                    // so Swift Charts never joins two buckets across it, even when both
                    // buckets still have data.
                    let segments = HistorySegments.split(plot.points)
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        let segmentKey = "\(plot.id) · \(index)"
                        ForEach(segment, id: \.time) { point in
                            LineMark(x: .value("Time", point.time),
                                     y: .value("Value", point.value),
                                     series: .value("Segment", segmentKey))
                                .foregroundStyle(by: .value("Series", plot.name))
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 1.6))
                        }
                        // A single bucket has no line and no area: without a symbol the
                        // whole 2–30 minute run is invisible. The point uses the same
                        // series style as the line, and stays separate from other gaps.
                        if segment.count == 1, let point = segment.first {
                            PointMark(x: .value("Time", point.time),
                                      y: .value("Value", point.value))
                                .foregroundStyle(by: .value("Series", plot.name))
                                .symbolSize(28)
                        }
                        if plots.count == 1 {
                            ForEach(segment, id: \.time) { point in
                                AreaMark(x: .value("Time", point.time),
                                         y: .value("Value", point.value),
                                         series: .value("Segment", segmentKey))
                                    .foregroundStyle(LinearGradient(colors: [plot.color.opacity(0.25), plot.color.opacity(0.02)],
                                                                    startPoint: .top, endPoint: .bottom))
                                    .interpolationMethod(.monotone)
                            }
                        }
                    }
                }
            }
            .chartForegroundStyleScale(domain: plots.map(\.name), range: plots.map(\.color))
            .chartLegend(plots.count > 1 ? .visible : .hidden)
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel { if let v = value.as(Double.self) { Text(valueLabel(v)) } }
                }
            }
            .chartXAxis {
                switch axis {
                case .live:
                    AxisMarks(values: .stride(by: .minute)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel(format: xFormat)
                    }
                case .history, .week:
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: xFormat) }
                }
            }
            .chartYScale(domain: .automatic(includesZero: format == .percent))
            .frame(height: 140)
            .transaction { $0.animation = nil }
        }
        .padding(16)
    }

    private var xFormat: Date.FormatStyle {
        axis == .week ? .dateTime.weekday(.abbreviated).hour() : .dateTime.hour().minute()
    }
}

#if !MACHELPER_CHART_TEST
/// The sensor list and its charts survive page switches in memory. Reusing a recent read makes
/// the previous charts appear at once; the selected range is still refreshed in the background.
@MainActor
private enum SeriesHistoryCache {
    struct Key: Hashable {
        let range: MonitorView.Range
        let selected: [String]
    }

    static var available: [AvailableSeries]?
    static var availableAt: Date?
    static var samples: [Key: [String: [SeriesBucket]]] = [:]
    static var samplesAt: [Key: Date] = [:]
    private static var sampleOrder: [Key] = []
    static let availableMaxAge: TimeInterval = 300
    static let samplesMaxAge: TimeInterval = 60
    /// A key is one range plus one sensor selection; toggling sensors can otherwise keep every
    /// combination alive for the whole session.
    private static let sampleLimit = 6

    static func store(_ value: [String: [SeriesBucket]], for key: Key) {
        if samples[key] == nil { sampleOrder.append(key) }
        samples[key] = value
        samplesAt[key] = Date()
        while sampleOrder.count > sampleLimit {
            let old = sampleOrder.removeFirst()
            samples.removeValue(forKey: old)
            samplesAt.removeValue(forKey: old)
        }
    }
}

/// Individual sensor temperatures and CPU core-cluster use for the selected range, read from
/// the shared minute history. The selector is built from the stored series, so a sensor that
/// stopped reporting stays visible and is marked instead of silently disappearing.
struct SeriesHistoryView: View {
    let history: MetricsHistory?
    let range: MonitorView.Range

    @State private var available: [AvailableSeries] = []
    @State private var selected: Set<String> = []
    @State private var samples: [String: [SeriesBucket]] = [:]
    /// The range the samples were read for. The chart keeps this range's axes and gaps
    /// until the next range's data arrives, so a switch never redraws a week of minutes
    /// with the live minute axis.
    @State private var shownRange: MonitorView.Range?
    @State private var loaded = false
    @State private var didChooseDefault = false
    @State private var refreshing = false

    /// A sensor that has not written a minute for this long is marked as gone. It stays
    /// selectable because its older history is still useful.
    private static let staleAfter: TimeInterval = 600
    private static let colors: [Color] = [Theme.orange, Theme.blue, Theme.cyan, Theme.violet,
                                          Theme.mint, Theme.rose, Theme.amber, Theme.slate]

    private struct LoadKey: Equatable {
        let range: MonitorView.Range
        let selected: Set<String>
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sensor and core history")
                    .font(.mh(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                if refreshing { ProgressView().controlSize(.small).help("Updating sensor history…") }
                Spacer()
                if !available.isEmpty { sensorMenu }
            }
            if loaded {
                if available.isEmpty {
                    PixelEmptyState(
                        art: "px.mascot",
                        title: "No sensor or core history yet",
                        message: "Individual sensor temperatures and CPU core use are recorded once a minute. Turn on Record sensor and core usage in Settings → General → Data management, then check back.") { EmptyView() }
                        .frame(minHeight: 260)
                } else if selected.isEmpty {
                    Text("Choose at least one sensor to show history.")
                        .font(.mhCaption)
                        .foregroundStyle(Palette.textMuted)
                } else if temperaturePlots.isEmpty, corePlots.isEmpty {
                    Text("No data in this range").font(.mhCaption).foregroundStyle(Palette.textMuted)
                } else if let shownRange {
                    HairlinePanel(columns: temperaturePlots.isEmpty || corePlots.isEmpty ? 1 : 2) {
                        if !temperaturePlots.isEmpty {
                            chart("Temperature sensors", plots: temperaturePlots, format: .celsius, range: shownRange)
                        }
                        if !corePlots.isEmpty {
                            chart("CPU core clusters", plots: corePlots, format: .percent, range: shownRange)
                        }
                    }
                }
            }
        }
        .task(id: LoadKey(range: range, selected: selected)) {
            var refreshList = true
            while !Task.isCancelled {
                // The sensor list changes rarely, so the periodic refresh re-reads only samples.
                guard await load(refreshList: refreshList) else { return }
                refreshList = false
                guard range == .live else { return }
                // A minute is only written when it closes; refresh the live window.
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var sensorMenu: some View {
        Menu {
            if !temperatureItems.isEmpty {
                Section("Temperature sensors") {
                    ForEach(temperatureItems, id: \.series) { item in
                        Button { toggle(item.series) } label: {
                            HStack {
                                if selected.contains(item.series) { Image(systemName: "checkmark") }
                                Text(menuLabel(item))
                            }
                        }
                    }
                }
            }
            if !coreItems.isEmpty {
                Section("CPU core clusters") {
                    ForEach(coreItems, id: \.series) { item in
                        Button { toggle(item.series) } label: {
                            HStack {
                                if selected.contains(item.series) { Image(systemName: "checkmark") }
                                Text(menuLabel(item))
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Choose sensors", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var temperatureItems: [AvailableSeries] {
        available.filter { $0.series.hasPrefix(SeriesPrefix.temperature) }
    }

    private var coreItems: [AvailableSeries] {
        available.filter { $0.series.hasPrefix(SeriesPrefix.cpu) }
    }

    private enum SeriesPrefix {
        static let temperature = "temperature."
        static let cpu = "cpu."
    }

    private func toggle(_ series: String) {
        if selected.contains(series) { selected.remove(series) } else { selected.insert(series) }
    }

    private func menuLabel(_ item: AvailableSeries) -> String {
        var parts = [displayName(item.series),
                     "\(String(localized: "Last seen")) \(item.lastSeen.formatted(.relative(presentation: .named)))"]
        if Date().timeIntervalSince(item.lastSeen) > Self.staleAfter {
            parts.append(String(localized: "No longer reporting"))
        }
        return parts.joined(separator: " · ")
    }

    private func displayName(_ series: String) -> String {
        switch series {
        case HistorySeries.cpuPerformance: return String(localized: "Performance cores")
        case HistorySeries.cpuEfficiency: return String(localized: "Efficiency cores")
        default:
            guard series.hasPrefix(SeriesPrefix.temperature) else { return series }
            return Fmt.sensorName(String(series.dropFirst(SeriesPrefix.temperature.count)))
        }
    }

    private var temperaturePlots: [SeriesHistoryChart.Plot] {
        plots(from: temperatureItems)
    }

    private var corePlots: [SeriesHistoryChart.Plot] {
        plots(from: coreItems)
    }

    private func plots(from items: [AvailableSeries]) -> [SeriesHistoryChart.Plot] {
        items.enumerated().compactMap { index, item in
            guard selected.contains(item.series), let points = samples[item.series], !points.isEmpty else { return nil }
            return SeriesHistoryChart.Plot(id: item.series, name: displayName(item.series),
                                           color: Self.colors[index % Self.colors.count], points: points)
        }
    }

    /// Returns false when choosing the default selection changed the task id: the task is
    /// restarted for the new selection, so this pass stops instead of loading twice.
    @MainActor
    private func load(refreshList: Bool) async -> Bool {
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            MonitorProbe.log("series-load-end", "range=\(range.rawValue) \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
        }
        guard let history else {
            available = []
            samples = [:]
            shownRange = range
            loaded = true
            PageLoadProbe.mark(.monitor, "series")
            return true
        }
        let now = Date()
        let since = now.addingTimeInterval(-range.seconds)
        let delayMs = MonitorProbe.queryDelayMilliseconds
        if refreshList || available.isEmpty {
            if let cached = SeriesHistoryCache.available, let at = SeriesHistoryCache.availableAt,
               Date().timeIntervalSince(at) < SeriesHistoryCache.availableMaxAge {
                available = cached
            } else {
                let list = await Task.detached(priority: .userInitiated) {
                    let list = (try? history.availableSeries()) ?? []
                    if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
                    return list
                }.value
                // A cancelled task must not publish a list or a default selection for the
                // range that replaced it.
                guard !Task.isCancelled else { return false }
                available = list
                SeriesHistoryCache.available = list
                SeriesHistoryCache.availableAt = Date()
            }
            if !didChooseDefault, !available.isEmpty {
                didChooseDefault = true
                let defaults = Self.defaultSelection(available)
                if defaults != selected {
                    selected = defaults
                    return false
                }
            }
        }
        let wanted = selected.sorted()
        let key = SeriesHistoryCache.Key(range: range, selected: wanted)
        if let cached = SeriesHistoryCache.samples[key] {
            guard !Task.isCancelled else { return false }
            samples = cached
            shownRange = range
            loaded = true
            MonitorProbe.log("series-commit-cache", Self.commitDetail(range: range, samples: cached))
            PageLoadProbe.mark(.monitor, "series")
            if range != .live, let at = SeriesHistoryCache.samplesAt[key],
               Date().timeIntervalSince(at) < SeriesHistoryCache.samplesMaxAge {
                refreshing = false
                return true
            }
        }
        refreshing = true
        // A cancelled task must not clear the spinner of the task that replaced it.
        defer { if !Task.isCancelled { refreshing = false } }
        let bucket = Self.bucket(for: range)
        let newSamples = await Task.detached(priority: .userInitiated) {
            let buckets = (try? history.seriesBuckets(wanted, since: since, until: now, bucket: bucket)) ?? [:]
            if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
            return buckets
        }.value
        guard !Task.isCancelled else { return false }
        samples = newSamples
        SeriesHistoryCache.store(newSamples, for: key)
        shownRange = range
        loaded = true
        MonitorProbe.log("series-commit", Self.commitDetail(range: range, samples: newSamples))
        PageLoadProbe.mark(.monitor, "series")
        PageLoadProbe.mark(.monitor, "series-refresh")
        return true
    }

    /// One log line with everything the switch test needs to prove which data reached the
    /// chart: the range, the point and segment counts, and the real stored span.
    private static func commitDetail(range: MonitorView.Range,
                                     samples: [String: [SeriesBucket]]) -> String {
        let buckets = samples.values.flatMap { $0 }
        let segments = samples.values.reduce(0) { $0 + HistorySegments.split($1).count }
        let first = buckets.map(\.time).min().map { Int($0.timeIntervalSince1970) } ?? 0
        let last = buckets.map(\.lastSampleTime).max().map { Int($0.timeIntervalSince1970) } ?? 0
        return "range=\(range.rawValue) series=\(samples.count) points=\(buckets.count) segments=\(segments) first=\(first) last=\(last)"
    }

    /// The simplest useful default: one CPU core group when the Mac reports one, otherwise
    /// the first three temperature sensors.
    private static func defaultSelection(_ list: [AvailableSeries]) -> Set<String> {
        if let core = list.first(where: { $0.series == HistorySeries.cpuPerformance })
            ?? list.first(where: { $0.series.hasPrefix(SeriesPrefix.cpu) }) {
            return [core.series]
        }
        return Set(list.filter { $0.series.hasPrefix(SeriesPrefix.temperature) }
            .prefix(3).map(\.series))
    }

    /// Per-minute points are only useful for live and one hour; a day or a week averages
    /// into fixed buckets, so the chart draws a few hundred marks instead of thousands.
    private static func bucket(for range: MonitorView.Range) -> TimeInterval {
        max(range.bucket, 60)
    }

    private func chart(_ title: LocalizedStringKey, plots: [SeriesHistoryChart.Plot],
                       format: SeriesHistoryChart.Format, range: MonitorView.Range) -> some View {
        SeriesHistoryChart(title: title, plots: plots, format: format,
                           axis: SeriesHistoryChart.Axis(range),
                           valueLabel: { label($0, format) })
    }

    private func label(_ value: Double, _ format: SeriesHistoryChart.Format) -> String {
        switch format {
        case .celsius: Fmt.celsius(value)
        case .percent: Fmt.percent(value)
        }
    }
}

extension SeriesHistoryChart.Axis {
    init(_ range: MonitorView.Range) {
        switch range {
        case .live: self = .live
        case .hour, .day: self = .history
        case .week: self = .week
        }
    }
}
#endif
