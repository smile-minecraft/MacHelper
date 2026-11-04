import HelperProtocol
import Metrics
import SwiftUI

struct OverviewView: View {
    let app: AppModel
    private var store: MonitorStore { app.store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Hero(store: store)
                HairlinePanel(columns: 4) {
                    MetricTile(title: "CPU", symbol: "cpu", color: Theme.blue,
                               value: Fmt.percent(store.cpu?.total), detail: cpuDetail,
                               series: store.history[.cpu], maxValue: 1)
                    MetricTile(title: "GPU", symbol: "square.stack.3d.up", color: Theme.violet,
                               value: Fmt.percent(store.gpu?.utilization), detail: store.gpu?.name,
                               series: store.history[.gpu], maxValue: 1)
                    MetricTile(title: "Memory", symbol: "memorychip", color: Theme.cyan,
                               value: memoryValue, detail: memoryDetail, series: store.history[.memory], maxValue: 1)
                    MetricTile(title: "Temperature", symbol: "thermometer.medium", color: Theme.orange,
                               value: Fmt.celsius(store.cpuCelsius), detail: String(localized: "Hottest CPU sensor"),
                               series: store.history[.temperature], maxValue: nil)
                    MetricTile(title: "Fans", symbol: "fanblades", color: Theme.mint,
                               value: store.fans.first.map { "\(Fmt.rpm($0.actualRPM)) rpm" } ?? "–",
                               detail: fanDetail, series: store.history[.fan], maxValue: store.fans.first?.maxRPM)
                    MetricTile(title: "Power", symbol: "bolt", color: Theme.amber,
                               value: Fmt.watts(store.power?.systemWatts ?? store.power?.gpuWatts),
                               detail: store.power.map { String(localized: "GPU \(Fmt.watts($0.gpuWatts))") },
                               series: store.history[.power], maxValue: nil)
                    MetricTile(title: "Network", symbol: "network", color: Theme.blue,
                               value: store.network.map { "↓ \(Fmt.rate($0.inBytesPerSecond))/s" } ?? "–",
                               detail: store.network.map { "↑ \(Fmt.rate($0.outBytesPerSecond))/s" },
                               series: store.history[.netIn], maxValue: nil)
                    MetricTile(title: "Disk", symbol: "internaldrive", color: Theme.violet,
                               value: store.disk.map { Fmt.bytes($0.availableBytes) } ?? "–",
                               detail: store.disk.map { String(localized: "free of \(Fmt.bytes($0.totalBytes))") },
                               series: store.history[.diskRead], maxValue: nil)
                }
                QuickActions(app: app)
                TopProcesses(store: store)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .onAppear { store.watchProcesses(true) }
        .onDisappear { store.watchProcesses(false) }
    }

    private var cpuDetail: String? {
        guard let c = store.cpu, let p = c.performance, let e = c.efficiency else { return nil }
        return String(localized: "P-cores \(Fmt.percent(p)) · E-cores \(Fmt.percent(e))")
    }

    private var memoryValue: String {
        guard let m = store.memory, m.totalBytes > 0 else { return "–" }
        return Fmt.percent(Double(m.usedBytes) / Double(m.totalBytes))
    }

    private var memoryDetail: String? {
        store.memory.map { "\(Fmt.memory($0.usedBytes)) / \(Fmt.memory($0.totalBytes))" }
    }

    private var fanDetail: String? {
        guard let f = store.fans.first else { return nil }
        return f.mode == .automatic ? String(localized: "System control") : String(localized: "Manual")
    }
}

// MARK: - Hero

private struct Hero: View {
    let store: MonitorStore

    private struct Health {
        let title: LocalizedStringKey
        let detail: String
        let color: Color
    }

    private var health: Health {
        if let t = store.cpuCelsius, t >= 95 {
            return Health(title: "Your Mac is running hot", detail: String(localized: "CPU at \(Fmt.celsius(t)). Check the top processes below."), color: Theme.rose)
        }
        if store.memory?.pressure == .critical {
            return Health(title: "Memory is under pressure", detail: String(localized: "Quit apps you don’t need to free memory."), color: Theme.rose)
        }
        if let d = store.disk, d.totalBytes > 0, Double(d.availableBytes) / Double(d.totalBytes) < 0.08 {
            return Health(title: "Startup disk is almost full", detail: String(localized: "Only \(Fmt.bytes(d.availableBytes)) free. Optimize can free up space."), color: Theme.amber)
        }
        if store.memory?.pressure == .warning {
            return Health(title: "Memory is getting tight", detail: String(localized: "Things still run fine, but swapping may start soon."), color: Theme.amber)
        }
        return Health(title: "Everything looks good", detail: String(localized: "Temperatures, memory and disk space are all in a healthy range."), color: Theme.mint)
    }

    var body: some View {
        let h = health
        HStack(alignment: .center, spacing: 16) {
            PixelIcon(name: "px.mascot", size: 64)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(h.color).frame(width: 8, height: 8)
                    Text(h.title).font(.system(size: 18, weight: .semibold))
                }
                Text(h.detail).font(.system(size: 12.5)).foregroundStyle(Palette.textMuted)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Host.modelName).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.text)
                Text("\(Host.osVersion) · \(String(localized: "Up \(Host.uptime)"))")
                    .font(.system(size: 11)).foregroundStyle(Palette.textFaint)
            }
        }
    }
}

enum Host {
    static let modelName: String = {
        let model = sysctl("hw.model"), chip = sysctl("machdep.cpu.brand_string")
        return chip.isEmpty ? model : "\(chip) · \(model)"
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

// MARK: - Tiles

private struct MetricTile: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color
    let value: String
    let detail: String?
    let series: [ChartPoint]?
    let maxValue: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
                Text(title).font(Theme.label).foregroundStyle(Palette.textMuted)
            }
            Text(value).font(Theme.numeral).foregroundStyle(Palette.text).lineLimit(1).minimumScaleFactor(0.6)
            Text(detail ?? " ").font(.system(size: 11)).foregroundStyle(Palette.textFaint).lineLimit(1)
            AreaSparkline(values: recent, maxValue: maxValue, color: color).equatable().frame(height: 30).padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The last five minutes, thinned to at most 90 points.
    private var recent: [Double] {
        guard let series else { return [] }
        let cutoff = Date().addingTimeInterval(-300)
        let points = series.filter { $0.date >= cutoff }.map(\.value)
        guard points.count > 90 else { return points }
        let stride = Double(points.count) / 90
        return (0..<90).map { points[Int(Double($0) * stride)] }
    }
}

// MARK: - Quick actions

private struct QuickActions: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
            HairlinePanel(columns: 2) {
                action(.optimize, "Scan caches, logs and leftovers, then clean what you pick.")
                action(.disk, "See where the space goes, find duplicates and what grew.")
                action(.uninstall, "Remove apps together with everything they left behind.")
                action(.startup, "Review what starts on its own at login.")
            }
        }
    }

    private func action(_ s: AppSection, _ text: LocalizedStringKey) -> some View {
        Button { app.show(s) } label: {
            HStack(spacing: 12) {
                PixelIcon(name: s.icon, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                    Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHoverStyle())
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
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
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
            Text("Processes").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
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
    static func icon(for p: ProcessUsage) -> NSImage {
        let key = p.appPath ?? "exec"
        if let i = cache[key] { return i }
        let i = p.appPath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .unixExecutable)
        cache[key] = i
        return i
    }
}
