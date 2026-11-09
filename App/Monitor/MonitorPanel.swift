import AppKit
import Charts
import HelperProtocol
import Metrics
import SMCKit
import SwiftUI

enum HistoryRange: Int, CaseIterable, Identifiable {
    case fiveMinutes = 300, fifteenMinutes = 900, hour = 3600
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .fiveMinutes: String(localized: "5 min")
        case .fifteenMinutes: String(localized: "15 min")
        case .hour: String(localized: "1 hour")
        }
    }
}

struct PanelActions {
    var openSettings: () -> Void
    var openDiagnostics: () -> Void
    var openFanControl: () -> Void
    var openDiskAnalysis: () -> Void
    var openOptimize: () -> Void
    var openUninstall: () -> Void
    var openStartup: () -> Void
    var openHistory: () -> Void
    var openMain: () -> Void = {}
    var quit: () -> Void
}

/// The menu bar popover: header, one tab per module (Stats-style), quick actions, footer.
struct MonitorPanel: View {
    let store: MonitorStore
    let actions: PanelActions
    /// false only for offscreen snapshots (ImageRenderer cannot draw ScrollView content).
    var scrollable = true
    @AppStorage("panel.module") private var tab: Tab = .cpu

    enum Tab: String, CaseIterable {
        case cpu, gpu, memory, disk, network

        var icon: String {
            switch self {
            case .cpu: "px.cpu"
            case .gpu: "px.gpu"
            case .memory: "px.memory"
            case .disk: "px.ssd"
            case .network: "px.network"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TabStrip(items: [(.cpu, "CPU"), (.gpu, "GPU"), (.memory, "Memory"), (.disk, "SSD"), (.network, "Network")],
                     icons: Dictionary(uniqueKeysWithValues: Tab.allCases.map { ($0, $0.icon) }),
                     selection: $tab)
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            Group {
                if scrollable {
                    ScrollView { content.padding(.horizontal, 20).padding(.bottom, 16) }
                        .scrollIndicators(.never)
                        .frame(height: 600)
                } else {
                    content.padding(.horizontal, 20).padding(.bottom, 16)
                }
            }
            QuickBar(actions: actions)
            footer
        }
        .frame(width: 460)
        .background(Palette.card)
        .onAppear { store.watchProcesses(true) }
        .onDisappear { store.watchProcesses(false) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: actions.openMain) {
                HStack(spacing: 7) {
                    Image(nsImage: ThemeStore.shared.logoImage).interpolation(.none).resizable().frame(width: 22, height: 22)
                    Text("MacHelper").font(.display(16.5, weight: .bold)).foregroundStyle(Palette.text)
                }
            }
            .buttonStyle(.plain)
            .help("Open MacHelper")
            Spacer()
            Text(Host.uptimeShort).font(.mh(size: 10.5)).foregroundStyle(Palette.textFaint)
            IconButton(symbol: "macwindow", help: "Open MacHelper", action: actions.openMain)
            IconButton(symbol: "gearshape", help: "Settings", action: actions.openSettings)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .cpu: CPUTab(store: store)
        case .gpu: GPUTab(store: store)
        case .memory: MemoryTab(store: store)
        case .disk: DiskTab(store: store)
        case .network: NetworkTab(store: store)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            let enabled = HelperClient.shared.status == .enabled
            Circle().fill(enabled ? Theme.accent : Theme.amber).frame(width: 6, height: 6)
            Text(enabled ? "Helper running" : "Helper not enabled").font(.mh(size: 11)).foregroundStyle(Palette.textMuted)
            Spacer()
            UpdateAvailableButton(compact: true)
            Button("Quit", action: actions.quit)
                .buttonStyle(.plain)
                .font(.mh(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

/// Always-visible shortcuts to the tools.
private struct QuickBar: View {
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 0) {
            item(.optimize, actions.openOptimize)
            if !ThemeStore.shared.isSimple { item(.fans, actions.openFanControl) }
            item(.disk, actions.openDiskAnalysis)
            item(.uninstall, actions.openUninstall)
            if !ThemeStore.shared.isSimple { item(.startup, actions.openStartup) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.base)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func item(_ s: AppSection, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                PixelIcon(name: s.icon, size: 30)
                Text(s.title).font(.mh(size: 11.5, weight: .medium)).foregroundStyle(Palette.textMuted).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickItemStyle())
        .help(s.title)
    }
}

private struct QuickItemStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hover ? Palette.inset : .clear, in: SurfaceShape(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

/// Shared helpers for module tabs.
@MainActor
private enum Series {
    static func values(_ store: MonitorStore, _ key: SeriesKey, seconds: Double = 300, points: Int = 90) -> [Double] {
        let cutoff = Date().addingTimeInterval(-seconds)
        let pts = (store.history[key] ?? []).filter { $0.date >= cutoff }.map(\.value)
        guard pts.count > points else { return pts }
        let step = Double(pts.count) / Double(points)
        return (0..<points).map { pts[Int(Double($0) * step)] }
    }

    /// Same rule as everywhere: neutral when normal, amber / red only when it needs attention.
    static func tempColor(_ t: Double?) -> Color {
        StatusRules.temperature(t)?.level.color ?? Palette.textMuted
    }
}

// MARK: - CPU

private struct CPUTab: View {
    let store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                RingGauge(fraction: (store.cpuCelsius.map { ($0 - 20) / 90 }) ?? 0, value: Fmt.celsius(store.cpuCelsius),
                          caption: "Temperature", color: Series.tempColor(store.cpuCelsius), size: 88, lineWidth: 11)
                Spacer()
                RingGauge(fraction: store.cpu?.total ?? 0, value: Fmt.percent(store.cpu?.total), caption: "Usage",
                          color: Theme.blue, size: 118, lineWidth: 14)
                Spacer()
                RingGauge(fraction: min(Host.loadAverages.0 / Double(ProcessInfo.processInfo.activeProcessorCount), 1),
                          value: String(format: "%.2f", Host.loadAverages.0), caption: "Load", color: Theme.cyan, size: 88, lineWidth: 11)
            }
            .padding(.horizontal, 8).padding(.top, 6)

            HairlineHeader(text: "Usage history")
            HistoryArea(values: Series.values(store, .cpu), maxValue: 1, color: Theme.blue).equatable().frame(height: 84)

            HStack {
                HairlineHeader(text: "Cores")
            }
            if let c = store.cpu, !c.perCore.isEmpty {
                CoreBars(values: c.perCore, kinds: c.coreKinds.map { $0 == .performance }).equatable().frame(height: 96)
                HStack(spacing: 12) {
                    legend(Theme.blue, String(localized: "Performance cores"), c.performance)
                    legend(Theme.cyan, String(localized: "Efficiency cores"), c.efficiency)
                    Spacer()
                }
            }

            HairlineHeader(text: "Details")
            VStack(spacing: 0) {
                if let c = store.cpu {
                    KeyValueRow(label: String(localized: "System (kernel)"), value: Fmt.percent(c.system), dot: Theme.slate)
                    KeyValueRow(label: String(localized: "User"), value: Fmt.percent(c.user), dot: Theme.blue)
                    KeyValueRow(label: String(localized: "Idle"), value: Fmt.percent(max(1 - c.total, 0)), dot: Palette.textFaint)
                }
                let l = Host.loadAverages
                KeyValueRow(label: String(localized: "Load average (1 · 5 · 15 min)"), value: String(format: "%.2f / %.2f / %.2f", l.0, l.1, l.2))
                if let f = store.fans.first {
                    KeyValueRow(label: String(localized: "Fans"), value: "\(Fmt.rpm(f.actualRPM)) rpm", dot: Theme.mint)
                }
                if let w = store.power?.systemWatts {
                    KeyValueRow(label: String(localized: "Power"), value: Fmt.watts(w), dot: Theme.slate)
                }
                KeyValueRow(label: String(localized: "CPU power"), value: Fmt.watts(store.power?.cpuWatts), dot: Theme.blue)
            }

            HairlineHeader(text: "Top processes")
            ProcessTable(items: Array((store.processes?.byCPU ?? []).prefix(6)), sort: .cpu, showHeader: false)
        }
    }

    private func legend(_ color: Color, _ title: String, _ value: Double?) -> some View {
        HStack(spacing: 5) {
            SurfaceShape(cornerRadius: 2.5).fill(color).frame(width: 10, height: 10)
            Text(title).font(.mh(size: 12)).foregroundStyle(Palette.textMuted)
            Text(Fmt.percent(value)).font(.display(12, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.text)
        }
    }
}

// MARK: - GPU

private struct GPUTab: View {
    let store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let gpuTemp = store.temperatures.filter { $0.category == .gpu }.map(\.celsius).max()
            HStack(alignment: .top) {
                RingGauge(fraction: (gpuTemp.map { ($0 - 20) / 90 }) ?? 0, value: Fmt.celsius(gpuTemp),
                          caption: "Temperature", color: Series.tempColor(gpuTemp), size: 88, lineWidth: 11)
                Spacer()
                RingGauge(fraction: store.gpu?.utilization ?? 0, value: Fmt.percent(store.gpu?.utilization), caption: "Usage",
                          color: Theme.violet, size: 118, lineWidth: 14)
                Spacer()
                RingGauge(fraction: min((store.power?.gpuWatts ?? 0) / 30, 1), value: Fmt.watts(store.power?.gpuWatts),
                          caption: "Power", color: Theme.amber, size: 88, lineWidth: 11)
            }
            .padding(.horizontal, 8).padding(.top, 6)
            HairlineHeader(text: "Usage history")
            HistoryArea(values: Series.values(store, .gpu), maxValue: 1, color: Theme.violet).equatable().frame(height: 96)
            HairlineHeader(text: "Details")
            VStack(spacing: 0) {
                KeyValueRow(label: String(localized: "Model"), value: store.gpu?.name ?? "–")
                KeyValueRow(label: String(localized: "Utilization"), value: Fmt.percent(store.gpu?.utilization), dot: Theme.violet)
                if let w = store.power?.gpuWatts { KeyValueRow(label: String(localized: "GPU power"), value: Fmt.watts(w), dot: Theme.amber) }
                KeyValueRow(label: String(localized: "Hottest GPU sensor"), value: Fmt.celsius(gpuTemp), dot: Series.tempColor(gpuTemp))
            }
            HairlineHeader(text: "Top processes")
            GPUProcessTable(items: store.gpuProcesses.map { Array($0.prefix(6)) })
        }
    }
}

/// Busiest GPU users. `nil` while the first two samples are pending; empty when nothing used the
/// GPU in the last interval (or this GPU publishes no per-process time).
private struct GPUProcessTable: View {
    let items: [GPUProcessUsage]?

    var body: some View {
        VStack(spacing: 0) {
            if let items {
                if items.isEmpty {
                    Text("No process used the GPU in the last few seconds")
                        .font(.mh(size: 12)).foregroundStyle(Palette.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, p in
                    HStack(spacing: 8) {
                        Image(nsImage: ProcessIcon.icon(for: p)).resizable().frame(width: 18, height: 18)
                        Text(p.name).font(.mh(size: 13)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Fmt.percent(p.gpu)).frame(width: 58, alignment: .trailing).foregroundStyle(Palette.text)
                    }
                    .font(.display(13).monospacedDigit())
                    .frame(height: 28)
                    .overlay(alignment: .bottom) {
                        if i < items.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                    }
                    .contentShape(Rectangle())
                    .help(p.path ?? p.name)
                    .contextMenu {
                        if let app = NSRunningApplication(processIdentifier: p.pid) {
                            Button("Quit \(app.localizedName ?? p.name)") { app.terminate() }
                        }
                        if let path = p.appPath ?? p.path {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        }
                    }
                }
            } else {
                SkeletonRows(count: 4).padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Memory

private struct MemoryTab: View {
    let store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let m = store.memory, m.totalBytes > 0 {
                let total = Double(m.totalBytes)
                let app = Double(m.appBytes) / total, wired = Double(m.wiredBytes) / total, comp = Double(m.compressedBytes) / total
                HStack(alignment: .center) {
                    Spacer()
                    PressureGauge(level: pressureLevel(m), label: pressureText(m.pressure), size: 132)
                    Spacer()
                    SegmentedRing(segments: [(app, Theme.blue), (wired, Theme.amber), (comp, Theme.rose)],
                                  value: Fmt.percent(Double(m.usedBytes) / total), size: 112, lineWidth: 14)
                    Spacer()
                }
                .padding(.top, 6)

                HairlineHeader(text: "Usage history")
                HistoryArea(values: Series.values(store, .memory), maxValue: 1, color: Theme.blue).equatable().frame(height: 84)

                HairlineHeader(text: "Details")
                HStack {
                    Text("Used").font(.mh(size: 13)).foregroundStyle(Palette.textMuted)
                    Spacer()
                    Text("\(Fmt.memory(m.usedBytes)) / \(Fmt.memory(m.totalBytes))")
                        .font(.display(13).monospacedDigit()).foregroundStyle(Palette.text)
                }
                StackedBar(parts: [(app, Theme.blue), (wired, Theme.amber), (comp, Theme.rose)]).padding(.bottom, 2)
                VStack(spacing: 0) {
                    KeyValueRow(label: String(localized: "App"), value: Fmt.memory(m.appBytes), dot: Theme.blue)
                    KeyValueRow(label: String(localized: "Wired"), value: Fmt.memory(m.wiredBytes), dot: Theme.amber)
                    KeyValueRow(label: String(localized: "Compressed"), value: Fmt.memory(m.compressedBytes), dot: Theme.rose)
                    KeyValueRow(label: String(localized: "Free"), value: Fmt.memory(m.totalBytes - min(m.usedBytes, m.totalBytes)), dot: Palette.inset)
                    KeyValueRow(label: String(localized: "Swap"), value: Fmt.memory(m.swapUsedBytes),
                                valueColor: m.swapUsedBytes > 0 ? Theme.amber : Palette.text)
                }
            } else {
                SkeletonRows(count: 6).padding(.top, 12)
            }
            HairlineHeader(text: "Top processes")
            ProcessTable(items: Array((store.processes?.byMemory ?? []).prefix(6)), sort: .memory, showHeader: false, valueIsMemory: true)
        }
    }

    private func pressureLevel(_ m: MemoryReading) -> Double {
        switch m.pressure {
        case .normal: 0.18 + 0.15 * Double(m.usedBytes) / Double(max(m.totalBytes, 1))
        case .warning: 0.5
        case .critical: 0.85
        }
    }

    private func pressureText(_ p: MemoryReading.Pressure) -> String {
        switch p {
        case .normal: String(localized: "Normal")
        case .warning: String(localized: "Warning")
        case .critical: String(localized: "Critical")
        }
    }
}

// MARK: - SSD

private struct DiskTab: View {
    let store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = store.disk {
                let used = d.totalBytes > 0 ? 1 - Double(d.availableBytes) / Double(d.totalBytes) : 0
                HStack(alignment: .top) {
                    RingGauge(fraction: used, value: Fmt.percent(used), caption: "Used", color: used > 0.9 ? Theme.rose : Theme.violet,
                              size: 112, lineWidth: 14)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Host.volumeName).font(.mh(size: 15, weight: .semibold)).foregroundStyle(Palette.text).padding(.bottom, 4)
                        KeyValueRow(label: String(localized: "Free"), value: Fmt.bytes(d.availableBytes), dot: Palette.inset)
                        KeyValueRow(label: String(localized: "Used"), value: Fmt.bytes(d.totalBytes - d.availableBytes), dot: Theme.violet)
                        KeyValueRow(label: String(localized: "Capacity"), value: Fmt.bytes(d.totalBytes))
                    }
                    .padding(.leading, 14)
                }
                .padding(.top, 6)
                HairlineHeader(text: "Activity")
                MirroredHistory(up: Series.values(store, .diskRead), down: Series.values(store, .diskWrite),
                                upColor: Theme.blue, downColor: Theme.rose).equatable().frame(height: 104)
                VStack(spacing: 0) {
                    KeyValueRow(label: String(localized: "Read"), value: "\(Fmt.rate(d.readBytesPerSecond))/s", dot: Theme.blue)
                    KeyValueRow(label: String(localized: "Write"), value: "\(Fmt.rate(d.writeBytesPerSecond))/s", dot: Theme.rose)
                }
            } else {
                SkeletonRows(count: 5).padding(.top, 12)
            }
        }
    }
}

// MARK: - Network

private struct NetworkTab: View {
    let store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let n = store.network {
                HStack {
                    big(Fmt.rate(n.inBytesPerSecond), String(localized: "Download"), Theme.blue)
                    Spacer()
                    big(Fmt.rate(n.outBytesPerSecond), String(localized: "Upload"), Theme.rose)
                }
                .padding(.horizontal, 28).padding(.top, 8)
                HairlineHeader(text: "Usage history")
                MirroredHistory(up: Series.values(store, .netIn), down: Series.values(store, .netOut)).equatable().frame(height: 112)
                HairlineHeader(text: "Interface")
                VStack(spacing: 0) {
                    let iface = Host.primaryInterface
                    KeyValueRow(label: String(localized: "Interface"), value: iface?.name ?? "–")
                    KeyValueRow(label: String(localized: "Local IP"), value: iface?.address ?? "–")
                    KeyValueRow(label: String(localized: "Status"), value: iface != nil ? String(localized: "Connected") : String(localized: "Offline"),
                                dot: iface != nil ? Theme.accent : Theme.rose)
                }
            } else {
                SkeletonRows(count: 5).padding(.top, 12)
            }
        }
    }

    private func big(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text("\(value)/s").font(.display(30, weight: .bold).monospacedDigit()).foregroundStyle(Palette.text)
            HStack(spacing: 5) {
                SurfaceShape(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                Text(label).font(.mh(size: 11)).foregroundStyle(Palette.textMuted)
            }
        }
    }
}

// MARK: - Process table

enum ProcessSort: String { case cpu, memory }

/// Dense process table: icon, name, CPU, memory; rows divided by hairlines.
struct ProcessTable: View {
    let items: [ProcessUsage]
    var sort: ProcessSort
    var showHeader = true
    /// Without the header the table has one value column: CPU, or memory when this is set.
    var valueIsMemory = false
    var onSort: ((ProcessSort) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                HStack(spacing: 8) {
                    Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                    header("CPU", .cpu).frame(width: 52, alignment: .trailing)
                    header("Memory", .memory).frame(width: 66, alignment: .trailing)
                }
                .font(.mh(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textFaint)
                .padding(.bottom, 6)
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            if items.isEmpty {
                SkeletonRows(count: 5).padding(.vertical, 8)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, p in
                HStack(spacing: 8) {
                    Image(nsImage: ProcessIcon.icon(for: p)).resizable().frame(width: 18, height: 18)
                    Text(p.name).font(.mh(size: 13)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if showHeader || !valueIsMemory {
                        Text(Fmt.percent(p.cpu)).frame(width: 58, alignment: .trailing)
                            .foregroundStyle(sort == .cpu ? Palette.text : Palette.textMuted)
                    }
                    if !showHeader && valueIsMemory {
                        Text(Fmt.memory(p.memoryBytes)).frame(width: 70, alignment: .trailing).foregroundStyle(Palette.text)
                    }
                    if showHeader {
                        Text(Fmt.memory(p.memoryBytes)).frame(width: 66, alignment: .trailing)
                            .foregroundStyle(sort == .memory ? Palette.text : Palette.textMuted)
                    }
                }
                .font(.display(13).monospacedDigit())
                .frame(height: 28)
                .overlay(alignment: .bottom) {
                    if i < items.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                }
                .contentShape(Rectangle())
                .help(p.path ?? p.name)
                .contextMenu {
                    if let app = NSRunningApplication(processIdentifier: p.pid) {
                        Button("Quit \(app.localizedName ?? p.name)") { app.terminate() }
                    }
                    if let path = p.appPath ?? p.path {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                }
            }
        }
    }

    private func header(_ title: LocalizedStringKey, _ s: ProcessSort) -> some View {
        Button { onSort?(s) } label: {
            HStack(spacing: 2) {
                Text(title)
                if sort == s { Image(systemName: "chevron.down").font(.mh(size: 7, weight: .bold)) }
            }
            .foregroundStyle(sort == s ? Palette.text : Palette.textFaint)
        }
        .buttonStyle(.plain)
    }
}

extension Host {
    static var loadAverages: (Double, Double, Double) {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? (l[0], l[1], l[2]) : (0, 0, 0)
    }

    static let volumeName: String = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"

    /// First active IPv4 interface (en*), for the network tab.
    /// Cached for 30 s: the network tab re-renders every second and getifaddrs walks every interface.
    @MainActor static var primaryInterface: (name: String, address: String)? {
        if let cached = interfaceCache, Date().timeIntervalSince(cached.at) < 30 { return cached.value }
        let value = readPrimaryInterface()
        interfaceCache = (Date(), value)
        return value
    }
    @MainActor private static var interfaceCache: (at: Date, value: (name: String, address: String)?)?

    private static func readPrimaryInterface() -> (name: String, address: String)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            p = ifa.ifa_next
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en"), (Int32(ifa.ifa_flags) & IFF_UP) != 0, let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return (name, String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return nil
    }

    /// Share of logical CPUs that are performance cores (hw.perflevel0 is the fastest level).
    static let performanceCoreShare: Double = {
        var p: Int32 = 0, all: Int32 = 0, size = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.logicalcpu", &p, &size, nil, 0)
        size = MemoryLayout<Int32>.size
        sysctlbyname("hw.logicalcpu", &all, &size, nil, 0)
        return all > 0 && p > 0 ? Double(p) / Double(all) : 0.5
    }()

    static var uptimeShort: String {
        String(localized: "Up \(Duration.seconds(ProcessInfo.processInfo.systemUptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)))")
    }
}
