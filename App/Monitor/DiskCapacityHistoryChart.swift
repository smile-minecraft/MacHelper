import Charts
import Storage
import SwiftUI

// MARK: - Display model

/// The seven-day free-space series for one volume, built only from the points the caller
/// already read. It never queries the store, the disk or the clock.
///
/// The series filters by the explicit volume identifier and by the trailing seven-day
/// window, so a caller that hands over a mixed or slightly stale array cannot merge two
/// volumes or draw an old reading. Missing hours stay missing: the points are split into
/// runs whenever the gap is longer than the hourly recording interval, and no zero point is
/// inserted. Swift Charts then draws each run as its own series and never joins a gap.
struct DiskCapacityHistorySeries: Equatable, Sendable {
    struct Segment: Identifiable, Equatable, Sendable {
        let id: Int
        let points: [VolumeCapacityPoint]
    }

    enum State: Equatable, Sendable {
        case empty
        case single(VolumeCapacityPoint)
        case series
    }

    /// The chart's horizon. Capacity is recorded once an hour, so the same value is also the
    /// largest gap that still counts as continuous data.
    static let sevenDays: TimeInterval = 7 * 86_400
    static let hourlyInterval: TimeInterval = 3_600

    let volumeID: String
    let windowStart: Date
    let windowEnd: Date
    /// Points for `volumeID` inside `windowStart...windowEnd`, oldest first.
    let points: [VolumeCapacityPoint]
    let segments: [Segment]

    init(points: [VolumeCapacityPoint],
         volumeID: String,
         now: Date,
         window: TimeInterval = DiskCapacityHistorySeries.sevenDays,
         maxGap: TimeInterval = DiskCapacityHistorySeries.hourlyInterval) {
        let start = now.addingTimeInterval(-window)
        let filtered = points
            .filter { $0.volume == volumeID && $0.time >= start && $0.time <= now }
            .sorted { $0.time < $1.time }
        self.volumeID = volumeID
        self.windowStart = start
        self.windowEnd = now
        self.points = filtered
        self.segments = HistorySegments.split(filtered, time: \.time, maxGap: maxGap)
            .enumerated()
            .map { Segment(id: $0.offset, points: $0.element) }
    }

    var latest: VolumeCapacityPoint? { points.last }
    var lowestFree: Double? { points.map(\.free).min() }
    var highestFree: Double? { points.map(\.free).max() }

    var state: State {
        if points.isEmpty { return .empty }
        if points.count == 1, let point = points.first { return .single(point) }
        return .series
    }

    /// The y range shown by the chart. A flat run still gets a visible band, and a single
    /// reading is centred instead of sitting on a zero-height domain.
    var freeDomain: ClosedRange<Double>? {
        guard let low = lowestFree, let high = highestFree else { return nil }
        let padding: Double
        if low == high {
            padding = max(abs(low) * 0.05, 1_000_000)
        } else {
            padding = max((high - low) * 0.1, 1_000_000)
        }
        return max(0, low - padding)...(high + padding)
    }

    /// A short summary for VoiceOver. It is built from the same filtered points as the chart,
    /// so the spoken latest, lowest and highest values cannot disagree with the drawing.
    func accessibilityValue(locale: Locale = .current, bundle: Bundle = .main) -> String {
        guard let latest, let lowest = lowestFree, let highest = highestFree else {
            return DiskCapacityHistoryText.accessibilityNoHistory.localized(in: bundle, locale: locale)
        }
        if case .single = state {
            let format = DiskCapacityHistoryText.accessibilityOneReading.localized(in: bundle, locale: locale)
            return String(format: format, locale: locale,
                          DiskCapacityHistoryFormat.bytes(latest.free, locale: locale))
        }
        let format = DiskCapacityHistoryText.accessibilityRange.localized(in: bundle, locale: locale)
        return String(format: format, locale: locale,
                      DiskCapacityHistoryFormat.bytes(latest.free, locale: locale),
                      DiskCapacityHistoryFormat.bytes(lowest, locale: locale),
                      DiskCapacityHistoryFormat.bytes(highest, locale: locale))
    }
}

// MARK: - Text

/// Every string the chart shows. Keeping the keys in one place lets the test check that the
/// dedicated `DiskCapacityHistory` catalog covers all of them.
enum DiskCapacityHistoryText: String, CaseIterable, Sendable {
    case title = "Free space, last 7 days"
    case latest = "Latest"
    case noHistory = "No capacity history yet"
    case noHistoryDetail = "Capacity is recorded once an hour. This chart fills in after MacHelper has been running for a while."
    case oneReading = "One reading so far"
    case oneReadingDetail = "The line appears after the next hourly reading."
    case accessibilityLabel = "Free space for the last seven days"
    case accessibilityNoHistory = "No capacity readings in the last seven days"
    case accessibilityOneReading = "One reading: %@"
    case accessibilityRange = "Latest %@, lowest %@, highest %@"

    func localized(in bundle: Bundle = .main, locale: Locale = .current) -> String {
        String(localized: String.LocalizationValue(rawValue),
               table: "DiskCapacityHistory",
               bundle: bundle,
               locale: locale)
    }
}

// MARK: - Formatting

enum DiskCapacityHistoryFormat {
    /// Decimal units, the same scale Finder uses for free space. The number is formatted with
    /// the caller's locale so the decimal separator and grouping follow the interface language.
    static func bytes(_ bytes: Double, locale: Locale = .current) -> String {
        let value = max(bytes, 0)
        let units: [(threshold: Double, divisor: Double, symbol: String)] = [
            (1_000_000_000_000, 1_000_000_000_000, "TB"),
            (1_000_000_000, 1_000_000_000, "GB"),
            (1_000_000, 1_000_000, "MB"),
            (1_000, 1_000, "KB"),
        ]
        for unit in units where value >= unit.threshold {
            let scaled = value / unit.divisor
            let digits = scaled >= 10 ? 1 : 2
            let number = scaled.formatted(.number
                .precision(.fractionLength(0...digits))
                .locale(locale))
            return "\(number) \(unit.symbol)"
        }
        let number = value.formatted(.number.precision(.fractionLength(0)).locale(locale))
        return "\(number) B"
    }
}

// MARK: - View

/// Free space for one volume over the last seven days, for the menu-bar SSD page.
///
/// The caller supplies the volume identifier, the points and the current date. The view only
/// presents them: it does not read the disk, open the history database, start a timer or touch
/// user preferences. The dedicated `DiskCapacityHistory` string table holds every label.
///
/// Integration: read `VolumeCapacityHistory.points(volume:since:until:)` for the selected
/// volume with `since: now.addingTimeInterval(-7 * 86_400)` and
/// `until: now.addingTimeInterval(1)` (the store's upper bound is exclusive), pass the same
/// `now`, and place the view inside the existing 460 pt panel's content width. XcodeGen picks
/// up `App/Monitor` sources and `App/Resources` catalogs automatically; run
/// `xcodegen generate` after adding the files.
struct DiskCapacityHistoryChart: View {
    let points: [VolumeCapacityPoint]
    let volumeID: String
    let now: Date
    var window: TimeInterval = DiskCapacityHistorySeries.sevenDays
    var maxGap: TimeInterval = DiskCapacityHistorySeries.hourlyInterval

    var body: some View {
        let series = DiskCapacityHistorySeries(points: points,
                                               volumeID: volumeID,
                                               now: now,
                                               window: window,
                                               maxGap: maxGap)
        VStack(alignment: .leading, spacing: 8) {
            header(series)
            switch series.state {
            case .empty:
                emptyState
            case .single:
                chart(series)
                singleReadingNote
            case .series:
                chart(series)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func header(_ series: DiskCapacityHistorySeries) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(DiskCapacityHistoryText.title.localized())
                .font(.mh(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let latest = series.latest {
                Text(DiskCapacityHistoryFormat.bytes(latest.free))
                    .font(Theme.smallNumeral)
                    .foregroundStyle(Theme.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(Text(verbatim: DiskCapacityHistoryText.latest.localized()))
            }
            Spacer(minLength: 0)
        }
    }

    private func chart(_ series: DiskCapacityHistorySeries) -> some View {
        Chart {
            ForEach(series.segments) { segment in
                if segment.points.count == 1, let point = segment.points.first {
                    // A single LineMark has no length and Swift Charts draws nothing. A point
                    // mark keeps a lone reading (and each isolated run) visible.
                    PointMark(x: .value("Time", point.time),
                              y: .value("Free space", point.free))
                        .symbolSize(36)
                        .foregroundStyle(Theme.cyan)
                } else {
                    ForEach(segment.points, id: \.time) { point in
                        LineMark(x: .value("Time", point.time),
                                 y: .value("Free space", point.free),
                                 series: .value("Segment", segment.id))
                            .foregroundStyle(Theme.cyan)
                            .interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                    ForEach(segment.points, id: \.time) { point in
                        AreaMark(x: .value("Time", point.time),
                                 y: .value("Free space", point.free),
                                 series: .value("Segment", segment.id))
                            .foregroundStyle(LinearGradient(
                                colors: [Theme.cyan.opacity(0.22), Theme.cyan.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.linear)
                    }
                }
            }
        }
        // Keep the first and last reading inside the plot instead of clipping a point that
        // lands exactly on the seven-day boundary. The padding is visual only; the data
        // window and the axis values stay unchanged.
        .chartXScale(domain: series.windowStart...series.windowEnd,
                     range: .plotDimension(padding: 10))
        .chartYScale(domain: series.freeDomain ?? 0...1)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(DiskCapacityHistoryFormat.bytes(bytes))
                            .font(.mh(size: 9.5))
                            .foregroundStyle(Palette.textMuted)
                    }
                }
            }
        }
        .frame(height: 140)
        .transaction { $0.animation = nil }
        .accessibilityLabel(Text(verbatim: DiskCapacityHistoryText.accessibilityLabel.localized()))
        .accessibilityValue(Text(verbatim: series.accessibilityValue()))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(DiskCapacityHistoryText.noHistory.localized())
                .font(.mh(size: 12, weight: .medium))
                .foregroundStyle(Palette.textMuted)
            Text(DiskCapacityHistoryText.noHistoryDetail.localized())
                .font(.mh(size: 10.5))
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(Palette.inset, in: SurfaceShape(cornerRadius: 8, style: .continuous))
    }

    private var singleReadingNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DiskCapacityHistoryText.oneReading.localized())
                .font(.mh(size: 11, weight: .medium))
                .foregroundStyle(Palette.textMuted)
            Text(DiskCapacityHistoryText.oneReadingDetail.localized())
                .font(.mh(size: 10.5))
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
