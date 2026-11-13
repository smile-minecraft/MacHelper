// Stand-ins copied from Tests/UI/run-monitor-panel-integration-tests.sh (its TestSupport.swift
// heredoc), minus the Storage stand-ins: this package compiles the live Sources/Storage module,
// so `MetricsHistory`, `HistoryStore`, `HistoryRetention`, `HistoryDiskUsage`, `SeriesBucket`,
// `HistoryKind` and `HistorySetting` come from the production files. Keep this file in sync with
// the UI script's heredoc when the panel's design-system surface changes.
import AppKit
import Metrics
import Observation
import SMCKit
import Storage
import SwiftUI

// MARK: - Design system stand-ins

enum Theme {
    static let blue = Color(red: 0.05, green: 0.6, blue: 0.1)
    static let cyan = Color(red: 0.9, green: 0.05, blue: 0.05)
    static let mint = Color.green
    static let amber = Color.orange
    static let rose = Color(red: 0.1, green: 0.2, blue: 0.9)
    static let violet = Color.purple
    static let orange = Color.orange
    static let slate = Color.gray
    static let accent = Color(red: 0.5, green: 0.0, blue: 0.5)
    static var smallNumeral: Font { .display(13).monospacedDigit() }
    static var label: Font { .mh(size: 11, weight: .medium) }
    static var heading: Font { .display(15) }
    static var numeral: Font { .display(24).monospacedDigit() }
    static var mediumNumeral: Font { .display(19).monospacedDigit() }
}

enum Palette {
    static let base = Color.white
    static let card = Color.white
    static let inset = Color(white: 0.94)
    static let raised = Color(white: 0.98)
    static let stroke = Color(white: 0.8)
    static let hairline = Color(white: 0.85)
    static let text = Color.black
    static let textMuted = Color(white: 0.35)
    static let textFaint = Color(white: 0.55)
}

struct SurfaceShape: InsettableShape {
    var cornerRadius: CGFloat
    var capsule = false
    private var insetAmount: CGFloat = 0

    init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        self.cornerRadius = cornerRadius
    }

    init(capsule: Bool) {
        cornerRadius = 0
        self.capsule = capsule
    }

    static var capsule: SurfaceShape { SurfaceShape(capsule: true) }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        if capsule { return Capsule(style: .continuous).path(in: r) }
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> SurfaceShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

extension Font {
    static func mh(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static var mhCaption: Font { .system(size: 11) }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.mh(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: SurfaceShape.capsule)
            .foregroundStyle(color)
    }
}

struct HairlineHeader: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text).font(.mh(size: 11, weight: .semibold)).foregroundStyle(Palette.textMuted)
    }
}

struct IconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }.help(help)
    }
}

struct PixelIcon: View {
    let name: String
    var size: CGFloat = 16
    var label: LocalizedStringKey? = nil

    var body: some View {
        Color.clear.frame(width: size, height: size)
    }
}

struct TabStrip<Value: Hashable>: View {
    let items: [(Value, LocalizedStringKey)]
    var icons: [Value: String] = [:]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item.1).onTapGesture { selection = item.0 }
            }
        }
    }
}

enum AppSection: String, CaseIterable, Hashable {
    case optimize, fans, disk, uninstall, startup

    var icon: String { "px.\(rawValue)" }
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

final class ThemeStore: @unchecked Sendable {
    static let shared = ThemeStore()
    var logoImage = NSImage(size: NSSize(width: 22, height: 22))
    var isSimple = false
}

enum HelperStatus {
    case enabled
    case disabled
}

final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()
    var status: HelperStatus = .enabled
}

struct UpdateAvailableButton: View {
    var compact = false

    var body: some View { EmptyView() }
}

enum Host {}

enum StatusLevel {
    case good, attention, critical

    var color: Color {
        switch self {
        case .good: Palette.text
        case .attention: Theme.amber
        case .critical: Theme.rose
        }
    }
}

struct Reading {
    let level: StatusLevel
}

enum StatusRules {
    static func temperature(_ celsius: Double?) -> Reading? {
        celsius.map { _ in Reading(level: .good) }
    }
}

struct RingGauge: View {
    let fraction: Double
    let value: String
    let caption: LocalizedStringKey
    var color: Color = Theme.accent
    var size: CGFloat = 84
    var lineWidth: CGFloat = 10

    var body: some View {
        VStack {
            Text(value).font(.display(size * 0.22, weight: .bold))
            Text(caption)
        }
    }
}

struct KeyValueRow: View {
    let label: String
    let value: String
    var dot: Color?
    var valueColor: Color = Palette.text

    var body: some View {
        HStack {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(label)
            Spacer()
            Text(value).foregroundStyle(valueColor)
        }
    }
}

struct CoreBars: View, Equatable {
    let values: [Double]
    var kinds: [Bool] = []
    var performance: Color = Theme.blue
    var efficiency: Color = Theme.cyan

    var body: some View { Color.clear }
}

struct PressureGauge: View {
    let level: Double
    let label: String
    var size: CGFloat = 76

    var body: some View { Text(label) }
}

struct SegmentedRing: View {
    let segments: [(Double, Color)]
    let value: String
    var size: CGFloat = 100
    var lineWidth: CGFloat = 12

    var body: some View { Text(value) }
}

struct StackedBar: View {
    let parts: [(Double, Color)]
    var height: CGFloat = 14

    var body: some View { Color.clear.frame(height: height) }
}

struct MirroredHistory: View, Equatable {
    let up: [Double]
    let down: [Double]
    var upColor: Color = Theme.blue
    var downColor: Color = Theme.rose

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let peak = max((up + down).max() ?? 1, 1)
            func draw(_ values: [Double], _ color: Color, above: Bool) {
                guard values.count > 1 else { return }
                let step = size.width / CGFloat(values.count - 1)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: mid))
                for (i, value) in values.enumerated() {
                    let height = mid * CGFloat(value / peak) * 0.95
                    path.addLine(to: CGPoint(x: CGFloat(i) * step, y: above ? mid - height : mid + height))
                }
                path.addLine(to: CGPoint(x: size.width, y: mid))
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }
            draw(up, upColor, above: true)
            draw(down, downColor, above: false)
        }
    }
}

struct HistoryArea: View, Equatable {
    let values: [Double]
    var maxValue: Double? = 1
    var color: Color = Theme.blue

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let peak = max(maxValue ?? 1, values.max() ?? 1, 0.0001)
            let step = size.width / CGFloat(values.count - 1)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, value) in values.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(i) * step,
                                         y: size.height - size.height * CGFloat(min(max(value / peak, 0), 1))))
            }
            context.stroke(path, with: .color(color), lineWidth: 2)
        }
    }
}

struct SkeletonRows: View {
    var count = 5

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { _ in
                SurfaceShape(cornerRadius: 3).frame(height: 9).foregroundStyle(Palette.inset)
            }
        }
    }
}

extension View {
    func settingsCaption(_ color: Color = Palette.textMuted) -> some View {
        font(.mh(size: 11)).foregroundStyle(color)
    }
}

@MainActor
enum ProcessIcon {
    static func icon(for p: ProcessUsage) -> NSImage { blankIcon }
    static func icon(for p: GPUProcessUsage) -> NSImage { blankIcon }

    private static var blankIcon: NSImage { NSImage(size: NSSize(width: 18, height: 18)) }
}

// MARK: - Store stand-in

struct ChartPoint: Hashable, Sendable {
    let date: Date
    let value: Double
}

enum SeriesKey: String, CaseIterable, Sendable {
    case cpu, cpuP, cpuE, gpu, memory, diskRead, diskWrite, netIn, netOut, battery, temperature, fan, power
}

struct LiveHistory {
    var series: [SeriesKey: [ChartPoint]] = [:]

    subscript(key: SeriesKey) -> [ChartPoint]? {
        series[key]
    }
}

/// The real store owns the hardware samplers, the shared database and the background recording
/// loops. This stand-in exposes only the state the menu panel reads. The tests fill it with
/// synthetic readings and an in-memory history database.
@MainActor
@Observable
final class MonitorStore {
    var cpu: CPUReading?
    var gpu: GPUReading?
    var memory: MemoryReading?
    var disk: DiskReading?
    var network: NetworkReading?
    var temperatures: [TemperatureReading] = []
    var fans: [FanReading] = []
    var power: PowerReading?
    var processes: ProcessSnapshot?
    var gpuProcesses: [GPUProcessUsage]?
    var history = LiveHistory()
    var persistentHistory: MetricsHistory?

    private(set) var watchCalls: [Bool] = []

    init() {}

    var cpuCelsius: Double? {
        MonitorHistorySample.cpuCelsius(temperatures)
    }

    func watchProcesses(_ on: Bool) {
        watchCalls.append(on)
    }
}
