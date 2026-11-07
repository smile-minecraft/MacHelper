import AppKit
import Diagnostics
import HelperProtocol
import Metrics
import Storage
import SwiftUI

struct OverviewView: View {
    let app: AppModel
    private var store: MonitorStore { app.store }
    @State private var diskPoints: [DiskSpacePoint] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Headline(store: store, app: app, diskPoints: diskPoints)
                Readouts(store: store, advanced: !ThemeStore.shared.isSimple)
                Rectangle().fill(Palette.hairline).frame(height: 1)
                HStack(alignment: .top, spacing: 40) {
                    if ThemeStore.shared.isSimple {
                        CommonTools(app: app).frame(maxWidth: .infinity, alignment: .topLeading)
                    } else {
                        BusiestApps(store: store).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    ToDoList(app: app).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                MachineLine()
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { store.watchProcesses(true) }
        .onDisappear { store.watchProcesses(false) }
        .task {
            let history = store.persistentHistory
            diskPoints = await Task.detached(priority: .utility) {
                (try? history?.diskSpace(since: Date().addingTimeInterval(-8 * 86_400))) ?? []
            }.value
            if !ThemeStore.shared.isSimple, app.startupModel.items.isEmpty { await app.startupModel.load() }
        }
    }
}

// MARK: - Headline

/// The one bold element: a sentence that answers "is my Mac OK?", with the number that matters in it.
private struct Headline: View {
    let store: MonitorStore
    let app: AppModel
    let diskPoints: [DiskSpacePoint]

    private struct Verdict {
        let sentence: String
        /// The part of the sentence drawn in the level color.
        let value: String?
        let level: StatusLevel
        var action: (LocalizedStringKey, AppSection)?
    }

    private var verdict: Verdict {
        let free = store.disk.map { Fmt.bytes($0.availableBytes) }
        if let t = store.cpuCelsius, t >= 95 {
            let v = Fmt.celsius(t)
            return Verdict(sentence: String(localized: "Your Mac is running hot at \(v)"), value: v, level: .critical,
                           action: ThemeStore.shared.isSimple ? ("Check Health", .health) : ("Open Monitor", .monitor))
        }
        if store.memory?.pressure == .critical {
            return Verdict(sentence: String(localized: "Memory is running out"), value: nil, level: .critical, action: ("Check Health", .health))
        }
        let diskLevel = store.diskFreeBytes.map { DiskSpaceLevels.level(freeBytes: Double($0)) }
        if diskLevel == .critical, let free {
            return Verdict(sentence: String(localized: "The disk is almost full, \(free) left"), value: free, level: .critical,
                           action: ("Free Up Space", .optimize))
        }
        if diskLevel == .low, let free {
            return Verdict(sentence: String(localized: "Your Mac runs smoothly, \(free) of space left"), value: free, level: .attention,
                           action: ("Free Up Space", .optimize))
        }
        if store.memory?.pressure == .warning {
            return Verdict(sentence: String(localized: "Memory is getting tight"), value: nil, level: .attention, action: ("Check Health", .health))
        }
        return Verdict(sentence: String(localized: "Your Mac runs smoothly"), value: nil, level: .good)
    }

    /// The trend under the sentence: how fast free space shrinks, else how long the Mac has been up.
    private var detail: String {
        if let f = DiskSpaceForecast.compute(diskPoints) {
            let perDay = Fmt.bytes(Int64(abs(f.bytesPerDay)))
            if f.bytesPerDay < 0, let days = f.daysUntilFull, days < 365 {
                return String(localized: "Free space shrinks by about \(perDay) a day; at this pace the disk is full in about \(Int(days.rounded())) days.")
            }
            if f.bytesPerDay < 0 { return String(localized: "Free space shrinks slowly, about \(perDay) a day.") }
            return String(localized: "Free space hasn’t been shrinking lately.")
        }
        return String(localized: "Up for \(Host.uptime) without a restart.")
    }

    /// The mascot's color is the worst of temperature, memory and free space (CPU spikes are too
    /// brief to recolor it); it holds up a sign toward the suggested action.
    private var mood: SlimeMascot.Mood {
        let levels = [StatusRules.temperature(store.cpuCelsius)?.level, StatusRules.memory(store.memory)?.level,
                      StatusRules.disk(freeBytes: store.diskFreeBytes)?.level, verdict.level].compactMap { $0 }
        var m = SlimeMascot.Mood(level: levels.max() ?? .good, holdsSign: verdict.action != nil)
        m.sleepy = m.level == .good && !m.holdsSign && (store.cpu?.total ?? 1) < 0.05
        return m
    }

    var body: some View {
        let v = verdict
        HStack(alignment: .center, spacing: 24) {
            SlimeMascot(mood: mood, cell: 4)
            VStack(alignment: .leading, spacing: 10) {
                Text(styled(v)).font(.display(34, weight: .semibold)).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.mh(size: 14)).foregroundStyle(Palette.textMuted)
            }
            Spacer(minLength: 16)
            if let score = app.healthModel.score(store: store) {
                HealthScoreBadge(score: score) { app.show(.health) }
            }
            if let (title, section) = v.action {
                Button { app.show(section) } label: { Text(title) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func styled(_ v: Verdict) -> AttributedString {
        var a = AttributedString(v.sentence)
        if let value = v.value, let r = a.range(of: value) { a[r].foregroundColor = v.level.color }
        return a
    }
}

// MARK: - Readouts

/// A row of instrument readouts: label, big number in the state color, and a quiet trend line.
private struct Readouts: View {
    let store: MonitorStore
    let advanced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 32) {
                Readout(title: "CPU", value: Fmt.percent(store.cpu?.total), reading: StatusRules.cpu(store.cpu?.total),
                        series: store.history[.cpu], maxValue: 1)
                Readout(title: "Memory", value: Fmt.percent(store.memoryFraction), reading: StatusRules.memory(store.memory),
                        series: store.history[.memory], maxValue: 1)
                Readout(title: "Temperature", value: Fmt.celsius(store.cpuCelsius), reading: StatusRules.temperature(store.cpuCelsius),
                        series: store.history[.temperature], maxValue: nil)
                Readout(title: "Free space", value: store.disk.map { Fmt.bytes($0.availableBytes) } ?? "–",
                        reading: StatusRules.disk(freeBytes: store.diskFreeBytes), series: nil, maxValue: nil,
                        bar: store.diskFreeFraction.map { 1 - $0 })
            }
            if advanced {
                HStack(alignment: .top, spacing: 32) {
                    Readout(title: "GPU", value: Fmt.percent(store.gpu?.utilization),
                            reading: StatusRules.fraction(store.gpu?.utilization).map { Reading(level: $0, word: "") },
                            series: store.history[.gpu], maxValue: 1)
                    Readout(title: "Network", value: store.network.map { "\(Fmt.rate($0.inBytesPerSecond))/s" } ?? "–",
                            reading: nil, series: store.history[.netIn], maxValue: nil, note: store.network.map { String(localized: "Upload \(Fmt.rate($0.outBytesPerSecond))/s") })
                    Readout(title: "Power", value: Fmt.watts(store.power?.systemWatts ?? store.power?.gpuWatts), reading: nil,
                            series: store.history[.power], maxValue: nil)
                    Readout(title: "Fans", value: store.fans.first.map { "\(Fmt.rpm($0.actualRPM)) rpm" } ?? "–", reading: nil,
                            series: store.history[.fan], maxValue: store.fans.first?.maxRPM)
                }
            }
        }
    }
}

private struct Readout: View {
    let title: LocalizedStringKey
    let value: String
    let reading: Reading?
    let series: [ChartPoint]?
    let maxValue: Double?
    var bar: Double? = nil
    var note: String? = nil

    var body: some View {
        let level = reading?.level ?? .good
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.mh(size: 12.5, weight: .medium)).foregroundStyle(Palette.textMuted)
                if let word = reading?.word, !word.isEmpty {
                    Text(word).font(.mh(size: 12.5)).foregroundStyle(level == .good ? Palette.textFaint : level.color)
                }
            }
            // No rolling digits here: these change every second, and SwiftUI draws the numeric text
            // transition (with its blur) on the CPU, which cost about 30 % CPU for the nine readouts.
            Text(value).font(.display(30, weight: .medium).monospacedDigit()).foregroundStyle(level.color)
                .lineLimit(1).minimumScaleFactor(0.6)
            Group {
                if let bar {
                    Meter(fraction: bar, color: level == .good ? Palette.textMuted : level.color)
                } else {
                    AreaSparkline(values: recent, maxValue: maxValue, color: level == .good ? Palette.textFaint : level.color, lineWidth: 1.2)
                        .equatable()
                }
            }
            .frame(height: bar == nil ? 24 : 8)
            .padding(.top, bar == nil ? 0 : 8)
            if let note { Text(note).font(.mh(size: 11.5)).foregroundStyle(Palette.textFaint) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The last five minutes, thinned to at most 60 points.
    private var recent: [Double] {
        guard let series else { return [] }
        let cutoff = Date().addingTimeInterval(-300)
        let points = series.filter { $0.date >= cutoff }.map(\.value)
        guard points.count > 60 else { return points }
        let stride = Double(points.count) / 60
        return (0..<60).map { points[Int(Double($0) * stride)] }
    }
}

// MARK: - Lower columns

private struct BusiestApps: View {
    let store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Busiest apps").font(Theme.heading).foregroundStyle(Palette.text)
            ProcessTable(items: Array((store.processes?.byCPU ?? []).prefix(6)), sort: .cpu)
        }
    }
}

private struct CommonTools: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tools").font(Theme.heading).foregroundStyle(Palette.text).padding(.bottom, 8)
            tool(.optimize, "Free up space safely. You see everything before it’s cleaned.")
            tool(.health, "Find out what’s slowing your Mac down.")
            tool(.disk, "See what takes up the most space.")
            tool(.uninstall, "Remove apps completely, leftovers included.")
        }
    }

    private func tool(_ s: AppSection, _ text: LocalizedStringKey) -> some View {
        Button { app.show(s) } label: {
            HStack(spacing: 12) {
                PixelIcon(name: s.icon, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.mh(size: 13.5, weight: .semibold)).foregroundStyle(Palette.text)
                    Text(text).font(.mh(size: 12)).foregroundStyle(Palette.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHoverStyle())
    }
}

/// What needs the person's attention, each with the action that fixes it. Empty is good news.
private struct ToDoList: View {
    let app: AppModel
    private var store: MonitorStore { app.store }

    private struct Item: Identifiable {
        let id: String
        let text: String
        let level: StatusLevel
        let action: LocalizedStringKey
        let section: AppSection
    }

    private var items: [Item] {
        var out: [Item] = []
        if let d = store.disk, let level = store.diskFreeBytes.map({ DiskSpaceLevels.level(freeBytes: Double($0)) }), level != .healthy {
            out.append(Item(id: "disk", text: String(localized: "Only \(Fmt.bytes(d.availableBytes)) of space is left."),
                            level: level == .critical ? .critical : .attention, action: "Free Up Space", section: .optimize))
        }
        if let p = store.memory?.pressure, p != .normal {
            out.append(Item(id: "memory", text: String(localized: "Memory is tight; quitting unused apps helps."),
                            level: p == .critical ? .critical : .attention, action: "Check Health", section: .health))
        }
        if let t = store.cpuCelsius, t >= 85 {
            out.append(Item(id: "temp", text: String(localized: "The CPU is at \(Fmt.celsius(t))."),
                            level: t >= 95 ? .critical : .attention, action: "Check Health", section: .health))
        }
        let broken = app.startupModel.items.filter(\.programMissing).count
        if broken > 0, !ThemeStore.shared.isSimple {
            out.append(Item(id: "startup", text: String(localized: "\(broken) startup items point to programs that no longer exist."),
                            level: .attention, action: "Review Startup Items", section: .startup))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Needs your attention").font(Theme.heading).foregroundStyle(Palette.text)
            if items.isEmpty {
                Text("Nothing right now.").font(.mh(size: 13)).foregroundStyle(Palette.textMuted)
            }
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(item.level.color).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(item.text).font(.mh(size: 13)).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { app.show(item.section) } label: {
                        Text(item.action).font(.mh(size: 13, weight: .medium)).underline().foregroundStyle(Palette.text)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// The machine, quietly, at the bottom.
private struct MachineLine: View {
    var body: some View {
        HStack(spacing: 18) {
            Text(Host.modelName)
            Text(Host.osVersion)
            Text("Up \(Host.uptime)")
        }
        .font(.mh(size: 11.5)).foregroundStyle(Palette.textFaint)
    }
}

/// The one filled button: ink on light, light on dark (the instrument's only "accent").
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let fill = Theme.accent
        configuration.label
            .font(.mh(size: 13, weight: .semibold))
            .foregroundStyle(fill.isDarkForeground ? Color.white : Color.black)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1), in: SurfaceShape(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct PixelButtonStyle: ButtonStyle {
    var color: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        let shape = SurfaceShape(cornerRadius: 6)
        configuration.label
            .foregroundStyle(color.isDarkForeground ? Color.white : Color.black)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(shape.fill(color))
            .background(shape.fill(Color.black.opacity(0.35)).offset(y: configuration.isPressed ? 0 : 3))
            .offset(y: configuration.isPressed ? 3 : 0)
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
    }
}

extension Color {
    /// Whether white text reads better than black on this color.
    var isDarkForeground: Bool {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let l = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return l < 0.55
    }
}

enum Host {
    static let modelName: String = {
        let model = sysctl("hw.model"), chip = sysctl("machdep.cpu.brand_string")
        return chip.isEmpty ? model : "\(chip) (\(model))"
    }()

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }()

    static var uptime: String {
        Duration.seconds(ProcessInfo.processInfo.systemUptime)
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}

/// Row highlight on hover, slight shrink on press.
struct RowHoverStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hover ? Palette.inset.opacity(0.6) : .clear)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: hover)
            .onHover { hover = $0 }
    }
}

/// Lifts a card slightly on hover and press.
struct HoverCardButtonStyle: ButtonStyle {
    var accent: Color
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(SurfaceShape(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(accent.opacity(hovering ? 0.55 : 0), lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

// MARK: - Processes

struct TopProcesses: View {
    let store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Processes").font(Theme.heading).foregroundStyle(Palette.text)
            HairlinePanel(columns: 2) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Top processes by CPU").font(Theme.label).foregroundStyle(Palette.textMuted)
                    ProcessTable(items: Array((store.processes?.byCPU ?? []).prefix(8)), sort: .cpu)
                }
                .padding(16)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Top processes by memory").font(Theme.label).foregroundStyle(Palette.textMuted)
                    ProcessTable(items: Array((store.processes?.byMemory ?? []).prefix(8)), sort: .memory)
                }
                .padding(16)
            }
        }
    }
}

/// App icons for processes, cached (NSWorkspace icon lookups are not free).
@MainActor
enum ProcessIcon {
    private static var cache: [String: NSImage] = [:]
    static func icon(for p: ProcessUsage) -> NSImage { icon(appPath: p.appPath) }
    static func icon(for p: GPUProcessUsage) -> NSImage { icon(appPath: p.appPath) }

    static func icon(appPath: String?) -> NSImage {
        let key = appPath ?? "exec"
        if let i = cache[key] { return i }
        let i = appPath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .unixExecutable)
        cache[key] = i
        return i
    }
}

// MARK: - Health score

extension HealthScore.Level {
    var status: StatusLevel {
        switch self {
        case .good: .good
        case .attention: .attention
        case .critical: .critical
        }
    }
}

/// The health score inside a ring filled to the score, green when good, yellow or red when not.
struct HealthScoreRing: View {
    let score: HealthScore
    var size: CGFloat = 92
    var lineWidth: CGFloat = 8

    var color: Color {
        switch score.level {
        case .good: Theme.mint
        case .attention: Theme.amber
        case .critical: Theme.rose
        }
    }

    var body: some View {
        let fraction = Double(score.value) / 100
        ZStack {
            if ThemeStore.shared.isPixel {
                PixelRing(fraction: fraction, color: color, track: Palette.inset, lineWidth: lineWidth)
            } else {
                Circle().stroke(Palette.inset, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: max(fraction, 0.001))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.meter(0.6), value: fraction)
            }
            Text(verbatim: "\(score.value)")
                .font(.display(size * 0.36, weight: .bold).monospacedDigit())
                .foregroundStyle(Palette.text)
                .contentTransition(Motion.meter(0.3) == nil ? .identity : .numericText(value: Double(score.value)))
                .animation(Motion.meter(0.3), value: score.value)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Health score"))
        .accessibilityValue(Text(verbatim: "\(score.value)"))
    }
}

/// The health score next to the headline; opens Health Check, which lists what lowers it.
struct HealthScoreBadge: View {
    let score: HealthScore
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                HealthScoreRing(score: score)
                Text("Health score").font(.mhCaption).foregroundStyle(hovering ? Palette.text : Palette.textMuted)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(score.deductions.isEmpty ? String(localized: "Nothing lowers the score.")
              : score.deductions.map { "−\($0.points)  \($0.title)" }.joined(separator: "\n"))
    }
}
