import Charts
import Storage
import SwiftUI

/// Individual sensor temperatures and CPU core-cluster use for the selected range, read from
/// the shared minute history. The selector is built from the stored series, so a sensor that
/// stopped reporting stays visible and is marked instead of silently disappearing.
struct SeriesHistoryView: View {
    let history: MetricsHistory?
    let range: MonitorView.Range

    @State private var available: [AvailableSeries] = []
    @State private var selected: Set<String> = []
    @State private var samples: [String: [SeriesSample]] = [:]
    @State private var loaded = false
    @State private var didChooseDefault = false

    /// A sensor that has not written a minute for this long is marked as gone. It stays
    /// selectable because its older history is still useful.
    private static let staleAfter: TimeInterval = 600
    private static let colors: [Color] = [Theme.orange, Theme.blue, Theme.cyan, Theme.violet,
                                          Theme.mint, Theme.rose, Theme.amber, Theme.slate]

    private enum Format { case celsius, percent }

    private struct Plot: Identifiable {
        let id: String
        let name: String
        let color: Color
        let points: [SeriesSample]
    }

    private struct LoadKey: Equatable {
        let range: MonitorView.Range
        let selected: Set<String>
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sensor and core history")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if temperaturePlots.isEmpty, corePlots.isEmpty {
                    Text("No data in this range").font(.caption).foregroundStyle(.secondary)
                } else {
                    HairlinePanel(columns: temperaturePlots.isEmpty || corePlots.isEmpty ? 1 : 2) {
                        if !temperaturePlots.isEmpty {
                            chart("Temperature sensors", plots: temperaturePlots, format: .celsius)
                        }
                        if !corePlots.isEmpty {
                            chart("CPU core clusters", plots: corePlots, format: .percent)
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

    private var temperaturePlots: [Plot] {
        plots(from: temperatureItems)
    }

    private var corePlots: [Plot] {
        plots(from: coreItems)
    }

    private func plots(from items: [AvailableSeries]) -> [Plot] {
        items.enumerated().compactMap { index, item in
            guard selected.contains(item.series), let points = samples[item.series], !points.isEmpty else { return nil }
            return Plot(id: item.series, name: displayName(item.series),
                        color: Self.colors[index % Self.colors.count], points: points)
        }
    }

    /// Returns false when choosing the default selection changed the task id: the task is
    /// restarted for the new selection, so this pass stops instead of loading twice.
    @MainActor
    private func load(refreshList: Bool) async -> Bool {
        guard let history else {
            available = []
            samples = [:]
            loaded = true
            return true
        }
        let now = Date()
        let since = now.addingTimeInterval(-range.seconds)
        if refreshList || available.isEmpty {
            let list = await Task.detached(priority: .userInitiated) {
                (try? history.availableSeries()) ?? []
            }.value
            available = list
            if !didChooseDefault, !list.isEmpty {
                didChooseDefault = true
                let defaults = Self.defaultSelection(list)
                if defaults != selected {
                    selected = defaults
                    return false
                }
            }
        }
        let wanted = selected.sorted()
        samples = await Task.detached(priority: .userInitiated) {
            (try? history.seriesSamples(wanted, since: since, until: now)) ?? [:]
        }.value
        loaded = true
        return true
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

    private func chart(_ title: LocalizedStringKey, plots: [Plot], format: Format) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                if let first = plots.first, let last = first.points.last {
                    Text(label(last.value, format)).font(Theme.smallNumeral).foregroundStyle(first.color)
                }
            }
            Chart {
                ForEach(plots) { plot in
                    // A missing minute leaves a gap: each run is its own series so Swift
                    // Charts never joins two points across the gap.
                    let segments = HistorySegments.split(plot.points, time: \.time, maxGap: 60)
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
                    AxisValueLabel { if let v = value.as(Double.self) { Text(label(v, format)) } }
                }
            }
            .chartXAxis {
                if range == .live {
                    AxisMarks(values: .stride(by: .minute)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel(format: xFormat)
                    }
                } else {
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
        range == .week ? .dateTime.weekday(.abbreviated).hour() : .dateTime.hour().minute()
    }

    private func label(_ value: Double, _ format: Format) -> String {
        switch format {
        case .celsius: Fmt.celsius(value)
        case .percent: Fmt.percent(value)
        }
    }
}
