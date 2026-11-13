import Charts
import Metrics
import Storage
import SwiftUI

struct MonitorView: View {
    let store: MonitorStore
    let app: AppModel
    @AppStorage("monitor.range") private var range: Range = .live
    @AppStorage("monitor.fill") private var fill = true
    @State private var samples: [MetricSample] = []
    /// The range whose data the charts show. It follows `range` only once that range's history has
    /// loaded, so switching ranges keeps the old charts up instead of flashing the empty state.
    @State private var shownRange: Range?

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
        let module: MonitorModule
        let title: LocalizedStringKey
        let color: Color
        let format: Format
        let series: [(name: String, live: SeriesKey, stored: KeyPath<MetricSample, Double?>)]
    }

    private let metrics: [Metric] = [
        Metric(id: "cpu", module: .cpu, title: "CPU", color: Theme.blue, format: .percent,
               series: [(String(localized: "Total"), .cpu, \.cpu)]),
        Metric(id: "gpu", module: .gpu, title: "GPU", color: Theme.violet, format: .percent, series: [("GPU", .gpu, \.gpu)]),
        Metric(id: "memory", module: .memory, title: "Memory", color: Theme.cyan, format: .percent,
               series: [(String(localized: "In use"), .memory, \.memory)]),
        Metric(id: "temperature", module: .temperature, title: "Temperature", color: Theme.orange, format: .celsius,
               series: [(String(localized: "Hottest CPU sensor"), .temperature, \.temperature)]),
        Metric(id: "fan", module: .fan, title: "Fans", color: Theme.mint, format: .rpm, series: [(String(localized: "Speed"), .fan, \.fan)]),
        Metric(id: "power", module: .power, title: "Power", color: Theme.amber, format: .watts, series: [(String(localized: "System"), .power, \.power)]),
        Metric(id: "network", module: .network, title: "Network", color: Theme.blue, format: .bytesPerSecond,
               series: [(String(localized: "Download"), .netIn, \.networkIn), (String(localized: "Upload"), .netOut, \.networkOut)]),
        Metric(id: "disk", module: .disk, title: "Disk", color: Theme.violet, format: .bytesPerSecond,
               series: [(String(localized: "Read"), .diskRead, \.diskRead), (String(localized: "Write"), .diskWrite, \.diskWrite)]),
        Metric(id: "battery", module: .battery, title: "Battery", color: Theme.mint, format: .percent,
               series: [(String(localized: "Charge"), .battery, \.battery)]),
    ]

    var body: some View {
        // Stop the live charts and process list while the main window is closed or minimized.
        // The menu bar and background recording read the store directly and are unaffected.
        if app.hasVisibleMainWindow {
            content
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var content: some View {
        let _ = MonitorProbe.logContent("range=\(range.rawValue) chart=\(chartRange.rawValue) samples=\(samples.count)")
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    ChipBar(items: Range.allCases.map { ($0, $0.title) },
                            selection: Binding(get: { range }, set: { newValue in
                                MonitorProbe.log("range-set", newValue.rawValue)
                                range = newValue
                            }))
                    Toggle("Fill under line", isOn: $fill)
                        .toggleStyle(.checkbox)
                        .font(.mhCaption)
                    Spacer()
                    Text(range == .live ? String(localized: "Last 5 minutes, updated live")
                         : String(localized: "Averages per \(Duration.seconds(range.bucket).formatted(.units(allowed: [.minutes, .hours], width: .wide)))"))
                        .font(.mhCaption).foregroundStyle(Palette.textMuted)
                }
                let shown = metrics.compactMap { m -> (Metric, [(String, [ChartPoint])])? in
                    let data = m.series.map { ($0.name, points($0.live, $0.stored)) }.filter { !$0.1.isEmpty }
                    return data.isEmpty ? nil : (m, data)
                }
                let loading = shownRange == nil
                if shown.isEmpty, loading {
                    Color.clear.frame(minHeight: 360)
                } else if shown.isEmpty {
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
            let r = range
            let started = CFAbsoluteTimeGetCurrent()
            MonitorProbe.log("history-load-start", r.rawValue)
            guard r != .live, let db = store.persistentHistory else {
                shownRange = r
                MonitorProbe.log("history-load-done", "\(r.rawValue) 0 points \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
                return
            }
            let loaded = (try? await Task.detached { try db.samples(since: Date().addingTimeInterval(-r.seconds), bucket: r.bucket) }.value) ?? []
            guard !Task.isCancelled else { return }
            samples = loaded
            shownRange = r
            MonitorProbe.log("history-load-done", "\(r.rawValue) \(loaded.count) points \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
        }
        .onAppear {
            MonitorProbe.start()
            store.watchProcesses(true)
        }
        .onDisappear { store.watchProcesses(false) }
    }

    private var hasEnabledModules: Bool {
        MonitorModule.allCases.contains { store.isActive($0) }
    }

    /// Live series hold up to one point a second. Nine charts of 300 points each made switching to
    /// Live stall while Swift Charts built every mark; averaging into at most 110 points looks the
    /// same at this width.
    static func thinned(_ points: [ChartPoint], limit: Int = 110) -> [ChartPoint] {
        guard points.count > limit else { return points }
        let size = Int((Double(points.count) / Double(limit)).rounded(.up))
        return stride(from: 0, to: points.count, by: size).map { start in
            let chunk = points[start..<min(start + size, points.count)]
            return ChartPoint(date: chunk[chunk.index(chunk.startIndex, offsetBy: chunk.count / 2)].date,
                              value: chunk.reduce(0) { $0 + $1.value } / Double(chunk.count))
        }
    }

    /// What the charts draw: the selected range once its data is on screen. Live data is
    /// already in memory, so it is drawn at once; a history range keeps the previous
    /// range's charts until its query finishes.
    private var chartRange: Range { range == .live ? .live : (shownRange ?? range) }

    private func points(_ live: SeriesKey, _ stored: KeyPath<MetricSample, Double?>) -> [ChartPoint] {
        if chartRange == .live {
            let cutoff = Date().addingTimeInterval(-300)
            return Self.thinned((store.history[live] ?? []).filter { $0.date >= cutoff })
        }
        return samples.compactMap { s in s[keyPath: stored].map { ChartPoint(date: s.time, value: $0) } }
    }

    private func chart(_ m: Metric, _ data: [(String, [ChartPoint])]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The current value sits next to the title, away from the trailing y-axis labels.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m.title).font(.mh(size: 12.5, weight: .semibold)).foregroundStyle(Palette.text)
                if let last = data.first?.1.last { Text(label(last.value, m.format)).font(Theme.smallNumeral).foregroundStyle(m.color) }
                Spacer()
            }
            Chart {
                seriesMarks(m, data)
                thresholdMarks(m)
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
                if chartRange == .live {
                    AxisMarks(values: .stride(by: .minute)) { _ in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])); AxisValueLabel(format: xFormat) }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: xFormat) }
                }
            }
            .modifier(ThresholdYScale(top: m.module.chartThresholds.map(\.value).max(),
                                      peak: data.flatMap(\.1).map(\.value).max()))
            .frame(height: 140)
            .transaction { $0.animation = nil }
        }
        .padding(16)
    }

    @ChartContentBuilder
    private func seriesMarks(_ m: Metric, _ data: [(String, [ChartPoint])]) -> some ChartContent {
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
                if fill && data.count == 1 {
                    ForEach(segment, id: \.date) { p in
                        AreaMark(x: .value("Time", p.date), y: .value("Value", p.value), series: .value("Segment", seriesKey))
                            .foregroundStyle(LinearGradient(colors: [m.color.opacity(0.25), m.color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                }
            }
        }
    }

    @ChartContentBuilder
    private func thresholdMarks(_ m: Metric) -> some ChartContent {
        ForEach(m.module.chartThresholds) { threshold in
            RuleMark(y: .value("Threshold", threshold.value))
                .foregroundStyle(threshold.level.color.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                // Tags sit at the trailing end, clear of the title and the line's start. The higher
                // (critical) tag goes above its line and the lower one below, so two close lines
                // never stack their tags on top of each other.
                .annotation(position: threshold.level == .critical ? .top : .bottom, alignment: .trailing, spacing: 2,
                            overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                    Text(threshold.label)
                        .font(.mhCaption2)
                        .foregroundStyle(threshold.level.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(SurfaceShape(capsule: true).fill(Palette.card.opacity(0.85)))
                        .overlay(SurfaceShape(capsule: true).strokeBorder(threshold.level.color.opacity(0.45), lineWidth: 0.5))
                }
        }
    }

    /// Live samples are at most 30 s apart; history uses one point per bucket. A delta
    /// larger than this starts a new segment, so a single missing bucket breaks the line.
    private var segmentGap: TimeInterval {
        chartRange == .live ? 45 : chartRange.bucket
    }

    private var xFormat: Date.FormatStyle {
        chartRange == .week ? .dateTime.weekday(.abbreviated).hour() : .dateTime.hour().minute()
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

/// Keeps the 0 baseline and extends the top of the y axis past the highest threshold
/// line when the data itself never reaches it, so the line always stays visible.
private struct ThresholdYScale: ViewModifier {
    let top: Double?
    let peak: Double?

    func body(content: Content) -> some View {
        if let top, let peak, peak < top {
            // Leave headroom above the highest line so its tag fits inside the plot; fractions stop at 100 %.
            content.chartYScale(domain: 0...(top <= 1 ? 1 : top * 1.1))
        } else {
            content.chartYScale(domain: .automatic(includesZero: true))
        }
    }
}

/// Debug aid for `--monitor-probe` (or `monitor.probe` in the defaults): logs the range
/// switch timeline and any main-thread stretch over 100 ms, so the native switch can be
/// measured without Instruments. Inert otherwise.
@MainActor
enum MonitorProbe {
    /// The launch argument is for a hand-run probe; the defaults key lets the native UI
    /// smoke enable the same log in an isolated temporary home without extra argv.
    static let active = CommandLine.arguments.contains("--monitor-probe")
        || UserDefaults.standard.bool(forKey: "monitor.probe")
    /// Test-only: the UI smoke can widen the window in which a replaced query is still
    /// running, so the cancellation path is reproducible instead of a race. Zero unless
    /// the probe is on.
    static var queryDelayMilliseconds: Int {
        guard active else { return 0 }
        return UserDefaults.standard.integer(forKey: "monitor.seriesQueryDelayMs")
    }
    private static var started = false
    private static var lastContentKey: String?
    nonisolated(unsafe) private static var busyStart: CFAbsoluteTime?

    static func log(_ event: String, _ detail: @autoclosure () -> String = "") {
        guard active else { return }
        NSLog("MHPROBE %.3f %@ %@", CFAbsoluteTimeGetCurrent(), event, detail())
    }

    /// The live page re-evaluates on every sample; log only when the drawn range or its
    /// sample count changes, so the probe log stays a switch timeline. The key is built
    /// lazily, so an inactive probe adds no string work to a sample.
    static func logContent(_ key: @autoclosure () -> String) {
        guard active else { return }
        let key = key()
        guard key != lastContentKey else { return }
        lastContentKey = key
        log("content", key)
    }

    static func start() {
        guard active, !started else { return }
        started = true
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, 0
        ) { _, activity in
            MainActor.assumeIsolated {
                if activity == .afterWaiting {
                    busyStart = CFAbsoluteTimeGetCurrent()
                } else if activity == .beforeWaiting, let start = busyStart {
                    busyStart = nil
                    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    if ms >= 100 { log("main-busy", String(format: "%.1f ms", ms)) }
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        log("probe-start")
    }
}
