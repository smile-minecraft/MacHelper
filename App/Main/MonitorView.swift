import Charts
import Metrics
import Storage
import SwiftUI

struct MonitorView: View {
    let store: MonitorStore
    @AppStorage("monitor.range") private var range: Range = .live
    @State private var samples: [MetricSample] = []

    enum Range: String, CaseIterable, Identifiable {
        case live, hour, day, week
        var id: String { rawValue }
        var seconds: TimeInterval { switch self { case .live: 300; case .hour: 3600; case .day: 86_400; case .week: 7 * 86_400 } }
        var bucket: TimeInterval { switch self { case .live: 0; case .hour: 60; case .day: 300; case .week: 1800 } }
        var title: LocalizedStringKey { switch self { case .live: "Live"; case .hour: "1 hour"; case .day: "24 hours"; case .week: "7 days" } }
    }

    enum Format { case percent, celsius, rpm, watts, bytesPerSecond }

    private struct Metric: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let color: Color
        let format: Format
        let series: [(name: String, live: SeriesKey, stored: KeyPath<MetricSample, Double?>)]
    }

    private let metrics: [Metric] = [
        Metric(id: "cpu", title: "CPU", color: Theme.blue, format: .percent,
               series: [(String(localized: "Total"), .cpu, \.cpu)]),
        Metric(id: "gpu", title: "GPU", color: Theme.violet, format: .percent, series: [("GPU", .gpu, \.gpu)]),
        Metric(id: "memory", title: "Memory", color: Theme.cyan, format: .percent,
               series: [(String(localized: "In use"), .memory, \.memory)]),
        Metric(id: "temperature", title: "Temperature", color: Theme.orange, format: .celsius,
               series: [(String(localized: "Hottest CPU sensor"), .temperature, \.temperature)]),
        Metric(id: "fan", title: "Fans", color: Theme.mint, format: .rpm, series: [(String(localized: "Speed"), .fan, \.fan)]),
        Metric(id: "power", title: "Power", color: Theme.amber, format: .watts, series: [(String(localized: "System"), .power, \.power)]),
        Metric(id: "network", title: "Network", color: Theme.blue, format: .bytesPerSecond,
               series: [(String(localized: "Download"), .netIn, \.networkIn), (String(localized: "Upload"), .netOut, \.networkOut)]),
        Metric(id: "disk", title: "Disk", color: Theme.violet, format: .bytesPerSecond,
               series: [(String(localized: "Read"), .diskRead, \.diskRead), (String(localized: "Write"), .diskWrite, \.diskWrite)]),
        Metric(id: "battery", title: "Battery", color: Theme.mint, format: .percent,
               series: [(String(localized: "Charge"), .battery, \.battery)]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    ChipBar(items: Range.allCases.map { ($0, $0.title) }, selection: $range)
                    Spacer()
                    Text(range == .live ? String(localized: "Last 5 minutes, updated live")
                         : String(localized: "Averages per \(Duration.seconds(range.bucket).formatted(.units(allowed: [.minutes, .hours], width: .wide)))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                let shown = metrics.compactMap { m -> (Metric, [(String, [ChartPoint])])? in
                    let data = m.series.map { ($0.name, points($0.live, $0.stored)) }.filter { !$0.1.isEmpty }
                    return data.isEmpty ? nil : (m, data)
                }
                if shown.isEmpty {
                    PixelEmptyState(art: "px.mascot",
                                    title: hasEnabledModules ? "No data yet" : "No menu bar metrics selected",
                                    message: hasEnabledModules
                                        ? "MacHelper records one averaged sample per minute. Monitoring history is kept for 7 days by default; change the retention in Settings → General → Data management. Turn on Background recording in Settings to keep history after MacHelper quits."
                                        : "Turn on at least one metric in Settings → Menu Bar to record its history. Process usage history has its own switch in Settings → General → Data management.") { EmptyView() }
                        .frame(minHeight: 360)
                } else {
                    HairlinePanel(columns: 2) {
                        ForEach(shown, id: \.0.id) { m, data in chart(m, data) }
                    }
                }
                SeriesHistoryView(history: store.persistentHistory, range: range)
                ProcessHistoryView(history: store.persistentHistory, range: range)
                TopProcesses(store: store)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
        .task(id: range) {
            guard range != .live, let db = store.persistentHistory else { samples = []; return }
            let r = range
            samples = (try? await Task.detached { try db.samples(since: Date().addingTimeInterval(-r.seconds), bucket: r.bucket) }.value) ?? []
        }
        .onAppear { store.watchProcesses(true) }
        .onDisappear { store.watchProcesses(false) }
    }

    private var hasEnabledModules: Bool {
        MonitorModule.allCases.contains { store.isActive($0) }
    }

    private func points(_ live: SeriesKey, _ stored: KeyPath<MetricSample, Double?>) -> [ChartPoint] {
        if range == .live {
            let cutoff = Date().addingTimeInterval(-300)
            return (store.history[live] ?? []).filter { $0.date >= cutoff }
        }
        return samples.compactMap { s in s[keyPath: stored].map { ChartPoint(date: s.time, value: $0) } }
    }

    private func chart(_ m: Metric, _ data: [(String, [ChartPoint])]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(m.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                if let last = data.first?.1.last { Text(label(last.value, m.format)).font(Theme.smallNumeral).foregroundStyle(m.color) }
            }
            Chart {
                ForEach(data, id: \.0) { name, pts in
                    // Break the line where an expected bucket is missing so the chart never
                    // paints across sleep, shutdown, or a stalled recorder. Each segment gets
                    // its own series identity; the shared style value keeps one color and
                    // one legend entry per metric.
                    let segments = HistorySegments.split(pts, time: \.date, maxGap: segmentGap)
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        let seriesKey = "\(name) · segment \(index)"
                        ForEach(segment, id: \.date) { p in
                            LineMark(x: .value("Time", p.date), y: .value("Value", p.value), series: .value("Segment", seriesKey))
                                .foregroundStyle(by: .value("Series", name))
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 1.6))
                        }
                        if data.count == 1 {
                            ForEach(segment, id: \.date) { p in
                                AreaMark(x: .value("Time", p.date), y: .value("Value", p.value), series: .value("Segment", seriesKey))
                                    .foregroundStyle(LinearGradient(colors: [m.color.opacity(0.25), m.color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                    .interpolationMethod(.monotone)
                            }
                        }
                    }
                }
            }
            .chartForegroundStyleScale(range: [m.color, Theme.mint])
            .chartLegend(data.count > 1 ? .visible : .hidden)
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel { if let v = value.as(Double.self) { Text(label(v, m.format)) } }
                }
            }
            .chartXAxis {
                if range == .live {
                    AxisMarks(values: .stride(by: .minute)) { _ in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])); AxisValueLabel(format: xFormat) }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: xFormat) }
                }
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .frame(height: 140)
            .transaction { $0.animation = nil }
        }
        .padding(16)
    }

    /// Live samples are at most 30 s apart; history uses one point per bucket. A delta
    /// larger than this starts a new segment, so a single missing bucket breaks the line.
    private var segmentGap: TimeInterval {
        range == .live ? 45 : range.bucket
    }

    private var xFormat: Date.FormatStyle {
        range == .week ? .dateTime.weekday(.abbreviated).hour() : .dateTime.hour().minute()
    }

    private func label(_ v: Double, _ f: Format) -> String {
        switch f {
        case .percent: Fmt.percent(v)
        case .celsius: Fmt.celsius(v)
        case .rpm: Fmt.rpm(v)
        case .watts: Fmt.watts(v)
        case .bytesPerSecond: Fmt.rate(v)
        }
    }
}
