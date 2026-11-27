import AppKit
import Charts
import Combine
import HelperProtocol
import Metrics
import SMCKit
import Storage
import SwiftUI
import Theming

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
    @AppStorage("panel.module", store: TestHost.defaults) private var tab: PanelPage = .cpu
    /// Kept above the tab switch so the selected disk survives moving between tabs while the
    /// panel is open.
    @State private var diskSelection = DiskCapacitySelectionModel()

    typealias Tab = PanelPage

    /// Pages to show, in the user's order, minus the hidden ones and the ones this Mac cannot show.
    @MainActor var tabs: [PanelPage] {
        store.settings.configuration.panelLayout.visiblePages {
            $0.isAvailable(in: store.availableModules, hasAccessories: !store.accessories.isEmpty)
        }
    }

    /// The stored page this Mac cannot show (or the user hid) falls back to the first visible page.
    @MainActor var shownTab: PanelPage? { tabs.contains(tab) ? tab : tabs.first }

    /// The strip and the content must highlight and show the same page, so the strip receives
    /// this resolved binding instead of the raw stored page. Reads fall back to the first
    /// visible page (`cpu` while nothing is visible, when the strip is hidden anyway); taps
    /// write through to the stored page. The stored value is kept, so a hidden page the user
    /// selected becomes selected again once it can show.
    @MainActor private var resolvedSelection: Binding<PanelPage> {
        Binding(get: { shownTab ?? .cpu },
                set: { tab = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            let isSoft = ThemeStore.shared.isSoft
            header
            if !tabs.isEmpty {
                TabStrip(items: tabs.map { ($0, LocalizedStringKey($0.title)) },
                         icons: Dictionary(uniqueKeysWithValues: PanelPage.allCases.map { ($0, $0.icon) }),
                         selection: resolvedSelection, stacked: tabs.count > 5)
                    .padding(.horizontal, 18)
                    .padding(.bottom, isSoft ? 2 : 12)
            }
            Group {
                if scrollable {
                    ScrollView {
                        content
                            .padding(.horizontal, 20)
                            .padding(.top, isSoft ? 12 : 0)
                            .padding(.bottom, 16)
                    }
                    .scrollIndicators(.never)
                    .frame(height: 600)
                } else {
                    content
                        .padding(.horizontal, 20)
                        .padding(.top, isSoft ? 12 : 0)
                        .padding(.bottom, 16)
                }
            }
            // Pages cross-fade as the pill slides, instead of the content cutting over.
            .animation(Motion.fade, value: shownTab)
            QuickBar(actions: actions)
            footer
        }
        .frame(width: 460)
        // Any text that doesn't pick a color takes the theme's ink: inside glass, `.primary`
        // would follow the wallpaper instead (black digits beside white names).
        .foregroundStyle(Palette.text)
        // The backdrop follows Settings → Appearance → Material: opaque, a frosted scrim, or a
        // stronger scrim under Liquid Glass cards and controls. Scrims are bright in light and
        // deep in dark, so the wallpaper never decides how text reads.
        .background(PanelBackdrop())
        .environment(\.frostedSurfaces, true)
        // Single-variant themes (Pixel Night) and the Light / Dark setting force their scheme,
        // so controls and materials agree with the theme's ink.
        .themeColorScheme()
        // Readings arrive every second here; gliding to each one kept the popover redrawing.
        .environment(\.animatesReadings, false)
        .onAppear { store.watchProcesses(true) }
        .onDisappear { store.watchProcesses(false) }
    }

    private var header: some View {
        let isSoft = ThemeStore.shared.isSoft
        return HStack(spacing: isSoft ? 10 : 8) {
            Button(action: actions.openMain) {
                HStack(spacing: 7) {
                    Image(nsImage: ThemeStore.shared.logoImage).interpolation(.none).resizable().frame(width: 22, height: 22)
                    Text("MacHelper").font(.display(16.5, weight: .bold)).foregroundStyle(Palette.text)
                }
            }
            .buttonStyle(.plain)
            .help("Open MacHelper")
            Spacer()
            Text(Host.uptimeShort).font(.mh(size: 10.5).monospacedDigit()).foregroundStyle(Palette.textMuted)
            IconButton(symbol: "macwindow", help: "Open MacHelper", action: actions.openMain)
            IconButton(symbol: "gearshape", help: "Settings", action: actions.openSettings)
        }
        .padding(.horizontal, isSoft ? 18 : 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        if let shownTab {
            Group {
                switch shownTab {
                case .cpu: CPUTab(store: store)
                case .gpu: GPUTab(store: store)
                case .memory: MemoryTab(store: store)
                case .disk: DiskTab(store: store, selection: diskSelection)
                case .network: PanelNetworkTab(store: store)
                case .battery: BatteryTab(store: store)
                case .power: PanelPowerTab(store: store, openFanControl: actions.openFanControl)
                }
            }
            .transition(.opacity)
        } else {
            VStack(spacing: 8) {
                PanelEmptyState(symbol: "rectangle.slash", title: "No panel pages",
                                detail: "Choose at least one page in Settings → Menu Bar.")
                Button("Open Settings", action: actions.openSettings)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(Palette.base)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            let enabled = HelperClient.shared.status == .enabled
            Circle().fill(enabled ? Theme.accent : Theme.amber).frame(width: 6, height: 6)
            Text(enabled ? "Helper running" : "Helper not enabled").font(.mh(size: 11)).foregroundStyle(Palette.textMuted)
            Spacer()
            UpdateAvailableButton(compact: true)
            Button(action: actions.quit) {
                Text("Quit")
                    .font(.mh(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.controlText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    // A tinted glass capsule, or the same capsule in the control fill: never a
                    // pale lens under pale text.
                    .glassSurface(in: Capsule(style: .continuous), interactive: true) { label in
                        if ThemeStore.shared.isSoft {
                            label
                        } else {
                            label
                                .background(Palette.controlFill, in: SurfaceShape.capsule)
                                .overlay(SurfaceShape.capsule.strokeBorder(Palette.controlBorder, lineWidth: 1))
                        }
                    }
            }
            .buttonStyle(SoftCapsuleButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

/// Always-visible shortcuts to the tools: one strip along the bottom of the panel.
private struct QuickBar: View {
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 0) {
            if AppSection.optimize.isVisible { item(.optimize, actions.openOptimize) }
            if AppSection.fans.isVisible { item(.fans, actions.openFanControl) }
            if AppSection.disk.isVisible { item(.disk, actions.openDiskAnalysis) }
            if AppSection.uninstall.isVisible { item(.uninstall, actions.openUninstall) }
            if AppSection.startup.isVisible { item(.startup, actions.openStartup) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Solid: its own strip in the page color. Translucent: it shares the panel's scrim, so the
        // labels sit on the same tested backdrop as the header and footer.
        .background(ThemeStore.shared.material == .solid ? Palette.base : Color.clear)
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
        let soft = ThemeStore.shared.isSoft
        let shape = SurfaceShape(cornerRadius: soft ? 10 : 8, style: .continuous)
        configuration.label
            .background {
                if soft {
                    if configuration.isPressed {
                        SoftSurface.recessed(shape, depth: .pressed)
                    } else if hover {
                        SoftSurface.raised(shape, fill: Palette.base, elevation: .control)
                    }
                } else if hover {
                    shape.fill(Palette.controlFill)
                }
            }
            .scaleEffect(configuration.isPressed ? (soft ? 0.97 : 0.95) : 1)
            .animation(Motion.hover, value: hover)
            .animation(Motion.press, value: configuration.isPressed)
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
            .panelCard()

            PanelSection(title: "Usage history") {
                HistoryArea(values: Series.values(store, .cpu), maxValue: 1, color: Theme.blue).equatable().frame(height: 84)
            }

            PanelSection(title: "Cores") {
                if let c = store.cpu, !c.perCore.isEmpty {
                    CoreBars(values: c.perCore, kinds: c.coreKinds.map { $0 == .performance }).equatable().frame(height: 96)
                    HStack(spacing: 12) {
                        legend(Theme.blue, String(localized: "Performance cores"), c.performance)
                        legend(Theme.cyan, String(localized: "Efficiency cores"), c.efficiency)
                        Spacer()
                    }
                }
            }

            PanelSection(title: "Details") {
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
            }

            PanelSection(title: "Top processes") {
                ProcessTable(items: Array((store.processes?.byCPU ?? []).prefix(6)), sort: .cpu, showHeader: false)
            }
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
            .panelCard()
            PanelSection(title: "Usage history") {
                HistoryArea(values: Series.values(store, .gpu), maxValue: 1, color: Theme.violet).equatable().frame(height: 96)
            }
            PanelSection(title: "Details") {
                VStack(spacing: 0) {
                    KeyValueRow(label: String(localized: "Model"), value: store.gpu?.name ?? "–")
                    KeyValueRow(label: String(localized: "Utilization"), value: Fmt.percent(store.gpu?.utilization), dot: Theme.violet)
                    if let w = store.power?.gpuWatts { KeyValueRow(label: String(localized: "GPU power"), value: Fmt.watts(w), dot: Theme.amber) }
                    KeyValueRow(label: String(localized: "Hottest GPU sensor"), value: Fmt.celsius(gpuTemp), dot: Series.tempColor(gpuTemp))
                }
            }
            PanelSection(title: "Top processes") {
                GPUProcessTable(items: store.gpuProcesses.map { Array($0.prefix(6)) })
            }
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
                .panelCard()

                PanelSection(title: "Usage history") {
                    HistoryArea(values: Series.values(store, .memory), maxValue: 1, color: Theme.blue).equatable().frame(height: 84)
                }

                PanelSection(title: "Details") {
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
                }
            } else {
                SkeletonRows(count: 6).padding(.top, 12)
            }
            PanelSection(title: "Top processes") {
                ProcessTable(items: Array((store.processes?.byMemory ?? []).prefix(6)), sort: .memory, showHeader: false, valueIsMemory: true)
            }
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
    let selection: DiskCapacitySelectionModel

    var body: some View {
        // The content is a view of its own so the page can be drawn without running the
        // lifecycle below (offscreen snapshots and the unit tests render just the content).
        DiskTabContent(store: store, selection: selection)
            .task {
                // Every appearance refreshes immediately, so points written while another tab was
                // visible are picked up when this page returns.
                selection.connect(reader: DiskCapacitySelectionModel.historyReader(for: store.persistentHistory))
                // Disk Arbitration has no timeout and capacity points arrive hourly, so refresh on
                // a slow cadence while visible instead of every second. The model also refreshes
                // the history window on this tick, which notices clears from other processes.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    if Task.isCancelled { break }
                    selection.refreshAll(forceHistory: false)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .monitoringHistoryCleared)) { _ in
                // Settings posts this only after the delete succeeds. A failed clear keeps the
                // old points on screen and shows its error instead.
                selection.historyDidClear()
            }
    }
}

struct DiskTabContent: View {
    let store: MonitorStore
    let selection: DiskCapacitySelectionModel
    /// The history chart's mark color; the rendering tests pass one no other part of the page
    /// uses, so they can tell whether the chart was drawn.
    var chartTint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                volumeSection
                if selection.isMountedSelection {
                    capacitySection
                }
                historySection
            }
            .panelCard()
            activitySection.panelCard()
            // DiskIOSection owns its sampler and `.task`; it stops sampling when the page goes
            // away.
            DiskIOSection()
        }
    }

    // MARK: Volume picker and state

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: DiskVolumeSelectionText.disk.localized())
                    .font(.mh(size: 12))
                    .foregroundStyle(Palette.textMuted)
                // A `Picker(.menu)` draws its label with the system menu colour, which is nearly
                // invisible on the dark popover. A `Menu` with a custom label keeps the palette's
                // text and capsule while the menu itself stays a standard SwiftUI menu.
                Menu {
                    // The label keeps the last known name visible when the selected disk
                    // disappears; the warning below explains why it is no longer in the list.
                    ForEach(selection.volumes) { option in
                        Button {
                            selection.select(option.key)
                        } label: {
                            HStack {
                                if option.key == selection.selectedKey {
                                    Image(systemName: "checkmark")
                                }
                                Text(verbatim: option.pickerTitle())
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(verbatim: selectedPickerTitle)
                            .font(.mh(size: 12, weight: .medium))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.mh(size: 8, weight: .bold))
                            .foregroundStyle(Palette.textMuted)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Palette.inset, in: SurfaceShape(capsule: true))
                    .overlay(SurfaceShape(capsule: true).strokeBorder(Palette.stroke, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .disabled(selection.volumes.isEmpty)
                .accessibilityLabel(Text(verbatim: DiskVolumeSelectionText.accessibilityVolumePicker.localized()))
                .accessibilityValue(Text(verbatim: selectedPickerTitle))
                Spacer(minLength: 0)
                Button {
                    selection.refreshAll(forceHistory: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.mh(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textMuted)
                .help(DiskVolumeSelectionText.refreshDisks.localized())
                .accessibilityLabel(Text(verbatim: DiskVolumeSelectionText.refreshDisks.localized()))
            }

            switch selection.volumesState {
            case .idle, .loaded:
                EmptyView()
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: DiskVolumeSelectionText.checkingDisks.localized())
                        .font(.mh(size: 11))
                        .foregroundStyle(Palette.textMuted)
                }
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: String(format: DiskVolumeSelectionText.volumeListError.localized(), message))
                        .font(.mh(size: 11))
                        .foregroundStyle(Theme.rose)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        selection.refreshAll(forceHistory: true)
                    } label: {
                        Text(verbatim: DiskVolumeSelectionText.tryAgain.localized())
                            .font(.mh(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }

            selectionWarning
        }
    }

    @ViewBuilder private var selectionWarning: some View {
        switch selection.selectionState {
        case .unmounted(let volume):
            warning(title: .volumeUnmounted,
                    detail: String(format: DiskVolumeSelectionText.volumeUnmountedDetail.localized(),
                                   displayName(volume)),
                    accessibility: .selectedDiskUnavailable)
        case .unidentifiable:
            warning(title: .volumeUnidentified,
                    detail: DiskVolumeSelectionText.volumeUnidentifiedDetail.localized(),
                    accessibility: .selectedDiskUnavailable)
        case .available, .none:
            EmptyView()
        }
    }

    private func warning(title: DiskVolumeSelectionText,
                         detail: String,
                         accessibility: DiskVolumeSelectionText) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title.localized())
                .font(.mh(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.amber)
            Text(verbatim: detail)
                .font(.mh(size: 10.5))
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.inset, in: SurfaceShape(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(verbatim: accessibility.localized()))
    }

    // MARK: Capacity

    @ViewBuilder private var capacitySection: some View {
        if let capacity = selection.capacity {
            let used = capacity.usedFraction
            HStack(alignment: .top) {
                RingGauge(fraction: used, value: Fmt.percent(used), caption: "Used",
                          color: used > 0.9 ? Theme.rose : Theme.violet, size: 112, lineWidth: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: selectedDisplayName)
                        .font(.mh(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .padding(.bottom, 4)
                        .accessibilityLabel(Text(verbatim: String(format: DiskVolumeSelectionText.selectedDisk.localized(),
                                                                  selectedDisplayName)))
                    KeyValueRow(label: String(localized: "Free"), value: Fmt.bytes(capacity.availableBytes), dot: Palette.inset)
                    KeyValueRow(label: String(localized: "Used"),
                                value: Fmt.bytes(max(capacity.totalBytes - capacity.availableBytes, 0)),
                                dot: Theme.violet)
                    KeyValueRow(label: String(localized: "Capacity"), value: Fmt.bytes(capacity.totalBytes))
                }
                .padding(.leading, 14)
            }
            .padding(.top, 6)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: selectedDisplayName)
                    .font(.mh(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(verbatim: DiskVolumeSelectionText.capacityUnavailable.localized())
                    .font(.mh(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                Text(verbatim: DiskVolumeSelectionText.capacityUnavailableDetail.localized())
                    .font(.mh(size: 10.5))
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Seven-day capacity history

    @ViewBuilder private var historySection: some View {
        switch selection.historyState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(verbatim: DiskVolumeSelectionText.historyLoading.localized())
                    .font(.mh(size: 11))
                    .foregroundStyle(Palette.textMuted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: DiskVolumeSelectionText.historyLoading.localized()))
        case .loaded:
            if let volumeID = selection.historyVolumeID {
                DiskCapacityHistoryChart(points: selection.historyPoints,
                                         volumeID: volumeID,
                                         now: selection.historyNow,
                                         tint: chartTint)
            }
        case .failed(_, let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: String(format: DiskVolumeSelectionText.historyError.localized(), message))
                    .font(.mh(size: 11))
                    .foregroundStyle(Theme.rose)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    selection.retryHistory()
                } label: {
                    Text(verbatim: DiskVolumeSelectionText.tryAgain.localized())
                        .font(.mh(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            .accessibilityElement(children: .contain)
            .accessibilityHint(Text(verbatim: DiskVolumeSelectionText.historyUnavailable.localized()))
        case .unavailable(_, let reason):
            Text(verbatim: reason.text.localized())
                .font(.mh(size: 10.5))
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHint(Text(verbatim: DiskVolumeSelectionText.historyUnavailable.localized()))
        }
    }

    // MARK: Whole-machine throughput

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DiskSectionHeader(text: .activityAllDisks)
            if let disk = store.disk {
                MirroredHistory(up: Series.values(store, .diskRead), down: Series.values(store, .diskWrite),
                                upColor: Theme.blue, downColor: Theme.rose).equatable().frame(height: 104)
                VStack(spacing: 0) {
                    KeyValueRow(label: String(localized: "Read"),
                                value: "\(Fmt.rate(disk.readBytesPerSecond))/s", dot: Theme.blue)
                    KeyValueRow(label: String(localized: "Write"),
                                value: "\(Fmt.rate(disk.writeBytesPerSecond))/s", dot: Theme.rose)
                }
            } else {
                SkeletonRows(count: 5).padding(.top, 12)
            }
        }
    }

    // MARK: Names

    private var selectedPickerTitle: String {
        guard let option = selection.volumes.first(where: { $0.key == selection.selectedKey }) else {
            return selection.selectedVolume.map(displayName) ?? "–"
        }
        return option.pickerTitle()
    }

    private var selectedDisplayName: String {
        selection.selectedVolume.map(displayName) ?? "–"
    }

    private func displayName(_ volume: DiskVolume) -> String {
        if let name = volume.name, !name.isEmpty { return name }
        return volume.role.titleText.localized()
    }
}

/// A section title whose text lives in the dedicated `DiskVolumeSelection` catalog. The shared
/// `HairlineHeader` only takes a `LocalizedStringKey`, which would look in `Localizable`.
struct DiskSectionHeader: View {
    let text: DiskVolumeSelectionText
    @Environment(\.insideGlassCard) private var insideGlassCard

    var body: some View {
        if insideGlassCard {
            Text(verbatim: text.localized())
                .font(.mh(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        } else {
            hairlines
        }
    }

    private var hairlines: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Text(verbatim: text.localized())
                .font(.mh(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
                .fixedSize()
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Battery

/// Internal battery and connected accessories share one page. Macs with neither don't show this tab.
///
/// The internal battery leads with a drawn battery and its charge, then the four numbers people
/// check (health, cycles, temperature, power) as tiles, then the charge history. Accessories
/// follow as rows with their own small battery bars, least charged first.
struct BatteryTab: View {
    let store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.availableModules.contains(.battery) {
                internalBatterySection
            }
            accessorySection
        }
    }

    @ViewBuilder private var internalBatterySection: some View {
        if !store.isActive(.battery) {
            PanelEmptyState(symbol: "battery.0", title: "Battery readings are off",
                            detail: "Turn on Battery in the menu bar settings to see the charge.")
        } else if let b = store.battery {
            hero(b).panelCard()
            PanelSection {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    BatteryStatTile(title: "Battery health", value: Fmt.percent(b.health),
                                    fraction: b.health, color: healthColor(b.health))
                    BatteryStatTile(title: "Cycle count", value: "\(b.cycleCount)")
                    BatteryStatTile(title: "Temperature", value: Fmt.celsius(b.celsius),
                                    valueColor: Series.tempColor(b.celsius))
                    BatteryStatTile(title: "Power", value: Fmt.watts(abs(b.watts)),
                                    symbol: b.watts > 0.05 ? "arrow.down.circle.fill" : "arrow.up.circle.fill",
                                    symbolColor: b.watts > 0.05 ? Theme.mint : Palette.textMuted)
                }
            }
            PanelSection(title: "Charge history") {
                HistoryArea(values: Series.values(store, .battery), maxValue: 1,
                            color: batteryColor(b.charge)).equatable().frame(height: 84)
            }
        } else {
            SkeletonRows(count: 5)
        }
    }

    /// The drawn battery, the charge in large type and what the power source is doing.
    private func hero(_ b: BatteryReading) -> some View {
        HStack(spacing: 18) {
            BatteryGlyph(charge: b.charge, charging: b.isCharging, color: batteryColor(b.charge))
                .frame(width: 104, height: 50)
            VStack(alignment: .leading, spacing: 5) {
                Text(Fmt.percent(b.charge))
                    .font(.display(34, weight: .bold).monospacedDigit())
                    .foregroundStyle(Palette.text)
                HStack(spacing: 5) {
                    Image(systemName: statusSymbol(b))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(b.isCharging ? Theme.amber : Palette.textMuted)
                    Text(batteryStatus(b))
                        .font(.mh(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var accessorySection: some View {
        if store.availableModules.contains(.accessories) {
            PanelSection(title: "Accessories") {
                if !store.isActive(.accessories) {
                    PanelEmptyState(symbol: "keyboard", title: "Accessory readings are off",
                                    detail: "Turn on Accessories in the menu bar settings to see their charge.")
                } else if store.accessories.isEmpty {
                    PanelEmptyState(symbol: "keyboard", title: "No accessories connected",
                                    detail: "Connect a Magic Keyboard, Mouse, Trackpad, or AirPods to see their charge.")
                } else {
                    let readings = store.accessories.sorted {
                        $0.charge == $1.charge
                            ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                            : $0.charge < $1.charge
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(readings.enumerated()), id: \.element.id) { i, reading in
                            accessoryRow(reading)
                                .overlay(alignment: .bottom) {
                                    if i < readings.count - 1 {
                                        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 42)
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    private func accessoryRow(_ reading: AccessoryBatteryReading) -> some View {
        HStack(spacing: 12) {
            Image(systemName: accessorySymbol(reading.kind))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 30, height: 30)
                .background(Palette.inset.opacity(0.8), in: SurfaceShape(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(reading.name)
                        .font(.mh(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    if reading.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.amber)
                    }
                    Spacer(minLength: 8)
                    Text(Fmt.percent(reading.charge))
                        .font(.display(13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(batteryColor(reading.charge))
                }
                Meter(fraction: reading.charge, color: batteryColor(reading.charge))
                if !reading.components.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(reading.components) { component in
                            Text(componentText(component))
                                .font(.mh(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(Palette.textMuted)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Palette.inset.opacity(0.8), in: SurfaceShape.capsule)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// Neutral at a healthy charge; battery rules supply amber / rose only when it needs attention.
    private func batteryColor(_ charge: Double) -> Color {
        StatusRules.battery(charge)?.color ?? Palette.text
    }

    /// Health below 80 % is worth a look (Apple's own service threshold).
    private func healthColor(_ health: Double?) -> Color {
        guard let health else { return Palette.textMuted }
        return health < 0.8 ? Theme.amber : Palette.textMuted
    }

    private func batteryStatus(_ b: BatteryReading) -> String {
        if b.isCharging { return String(localized: "Charging") }
        if b.externalPower && b.charge >= 0.995 { return String(localized: "Fully charged") }
        if b.externalPower { return String(localized: "Plugged in") }
        return String(localized: "On battery")
    }

    private func statusSymbol(_ b: BatteryReading) -> String {
        if b.isCharging { return "bolt.fill" }
        if b.externalPower { return "powerplug.fill" }
        return "battery.75percent"
    }

    private func accessorySymbol(_ kind: AccessoryBatteryReading.Kind) -> String {
        switch kind {
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .headphones: "airpods"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    private func componentText(_ component: AccessoryBatteryReading.Component) -> String {
        let label: String
        switch component.id {
        case .left: label = String(localized: "Left")
        case .right: label = String(localized: "Right")
        case .chargingCase: label = String(localized: "Case")
        }
        return "\(label) \(Fmt.percent(component.charge))"
    }
}

/// A battery drawn as an object: outline, terminal nub, a fill to the charge that glides to new
/// values, and a bolt while charging. Blocky in the pixel style through `SurfaceShape`.
private struct BatteryGlyph: View {
    let charge: Double
    let charging: Bool
    let color: Color
    @Environment(\.animatesReadings) private var animatesReadings

    var body: some View {
        GeometryReader { geo in
            let nub = max(geo.size.width * 0.06, 4)
            let body = CGSize(width: geo.size.width - nub - 2, height: geo.size.height)
            let radius = body.height * 0.24
            let inset: CGFloat = 4
            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    SurfaceShape(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Palette.textMuted.opacity(0.7), lineWidth: 2.5)
                    SurfaceShape(cornerRadius: radius - inset / 2, style: .continuous)
                        .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: max((body.width - inset * 2) * min(max(charge, 0), 1), 4))
                        .padding(inset)
                        .animation(animatesReadings ? Motion.meter(0.6) : nil, value: charge)
                    if charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: body.height * 0.42, weight: .bold))
                            .foregroundStyle(Palette.text)
                            .shadow(color: .black.opacity(0.35), radius: 2)
                            .frame(width: body.width)
                    }
                }
                .frame(width: body.width, height: body.height)
                SurfaceShape(cornerRadius: 2, style: .continuous)
                    .fill(Palette.textMuted.opacity(0.7))
                    .frame(width: nub, height: body.height * 0.36)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One number on the battery page: a label, the value, and an optional bar or symbol.
private struct BatteryStatTile: View {
    let title: LocalizedStringKey
    let value: String
    var fraction: Double? = nil
    var color: Color = Palette.textMuted
    var valueColor: Color = Palette.text
    var symbol: String? = nil
    var symbolColor: Color = Palette.textMuted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.mh(size: 11.5, weight: .medium)).foregroundStyle(Palette.textMuted).lineLimit(1)
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(symbolColor)
                }
                Text(value).font(.display(19, weight: .semibold).monospacedDigit()).foregroundStyle(valueColor)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            if let fraction {
                Meter(fraction: fraction, color: color)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(Palette.inset.opacity(0.55), in: SurfaceShape(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
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

extension View {
    /// One section of a panel page on its own card (the panel's "tables") with the frosted,
    /// Liquid Glass or soft (neumorphic) look. With solid smooth/pixel the section stays flat.
    @ViewBuilder func panelCard() -> some View {
        if ThemeStore.shared.material.isTranslucent || ThemeStore.shared.isSoft {
            padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.insideGlassCard, true)
                .surface(Palette.base)
        } else {
            self
        }
    }
}

/// A titled section of a panel page: a card with the title inside, or the flat hairline
/// header and content without cards.
struct PanelSection<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: (ThemeStore.shared.material.isTranslucent || ThemeStore.shared.isSoft) ? 10 : 12) {
            if let title { HairlineHeader(text: title) }
            content
        }
        .panelCard()
    }
}
