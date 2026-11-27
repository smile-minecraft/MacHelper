import Foundation
import Observation

enum MonitorModule: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, disk, network, battery, accessories, temperature, fan, power
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: String(localized: "Memory")
        case .disk: String(localized: "Disk")
        case .network: String(localized: "Network")
        case .battery: String(localized: "Battery")
        case .accessories: String(localized: "Accessories")
        case .temperature: String(localized: "Temperature")
        case .fan: String(localized: "Fans")
        case .power: String(localized: "Power")
        }
    }

    /// Short label drawn in the menu bar.
    var shortLabel: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "MEM"
        case .disk: "SSD"
        case .network: "NET"
        case .battery: "BAT"
        case .accessories: "ACC"
        case .temperature: "TMP"
        case .fan: "FAN"
        case .power: "PWR"
        }
    }

    /// Styles that make sense for this metric (rates and RPM have no natural 0–100 % scale).
    var supportedStyles: [MenuBarStyle] {
        switch self {
        case .network: [.text, .sparkline, .columns, .dual]
        case .fan, .power: [.text, .sparkline, .columns]
        case .temperature: [.text, .sparkline, .columns, .heat]
        case .disk: [.text, .bar, .ring, .blocks, .heat]
        case .accessories: [.text, .sparkline, .bar, .ring, .blocks, .columns]
        default: MenuBarStyle.allCases.filter { $0 != .dual }
        }
    }

    var defaultInterval: Double {
        switch self {
        case .disk, .battery: 5
        case .accessories: 30
        case .temperature, .fan, .power: 2
        default: 1
        }
    }

    /// Fixed horizontal reference lines for the monitor charts. Empty for metrics without a
    /// meaningful absolute level (rates, RPM, watts).
    var chartThresholds: [ChartThreshold] {
        switch self {
        case .temperature:
            [ChartThreshold(value: 80, label: String(localized: "Hot"), level: .attention),
             ChartThreshold(value: 95, label: String(localized: "Too hot"), level: .critical)]
        case .memory:
            [ChartThreshold(value: 0.8, label: String(localized: "Tight"), level: .attention),
             ChartThreshold(value: 0.95, label: String(localized: "Running out"), level: .critical)]
        default:
            []
        }
    }
}

/// One fixed reference line in a monitor chart. `value` is in the chart's own units
/// (degrees Celsius for temperature, a 0...1 fraction for memory).
struct ChartThreshold: Identifiable, Sendable {
    let value: Double
    let label: String
    let level: StatusLevel
    var id: Double { value }
}

enum MenuBarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case text, sparkline, bar, ring
    /// Pixel styles: a vertical meter of blocks, and a histogram of block columns.
    case blocks, columns
    case heat, dual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: String(localized: "Number")
        case .sparkline: String(localized: "Line")
        case .bar: String(localized: "Bar")
        case .ring: String(localized: "Ring")
        case .blocks: String(localized: "Blocks")
        case .columns: String(localized: "Columns")
        case .heat: String(localized: "Heat")
        case .dual: String(localized: "Dual")
        }
    }
}

struct ModuleConfig: Codable, Hashable, Sendable {
    /// Disabled modules are not sampled at all.
    var enabled: Bool
    /// Shown in the menu bar (an enabled module can live only in the panel).
    var inMenuBar: Bool
    var style: MenuBarStyle
    /// Seconds between samples.
    var interval: Double
}

struct MonitorConfiguration: Codable, Hashable, Sendable {
    var modules: [MonitorModule: ModuleConfig]
    /// Two-line labels: name above value. Saves menu bar width when showing several metrics.
    var compact: Bool
    /// Page order in the menu bar panel. All pages are listed; the panel draws the ones that
    /// are not hidden and whose hardware is present.
    var panelPageOrder: [PanelPage]
    /// Pages the user switched off in Settings → Menu Bar.
    var hiddenPanelPages: Set<PanelPage>

    func config(_ m: MonitorModule) -> ModuleConfig {
        modules[m] ?? ModuleConfig(enabled: false, inMenuBar: false, style: .text, interval: m.defaultInterval)
    }

    /// Order with duplicates removed (first occurrence wins, so the user's sequence is kept),
    /// any missing pages appended at the end, and only known hidden pages kept. Hiding every
    /// page is repaired by unhiding the last page in `order`, so at least one stays visible.
    func normalized() -> MonitorConfiguration {
        var seen = Set<PanelPage>()
        var order: [PanelPage] = []
        for page in panelPageOrder where seen.insert(page).inserted {
            order.append(page)
        }
        for page in PanelPage.allCases where !seen.contains(page) {
            order.append(page)
        }
        var hidden = hiddenPanelPages.intersection(PanelPage.allCases)
        if hidden.isSuperset(of: order) {
            hidden.remove(order.last ?? .cpu)
        }
        return MonitorConfiguration(modules: modules, compact: compact,
                                    panelPageOrder: order, hiddenPanelPages: hidden)
    }

    var panelLayout: PanelLayout {
        PanelLayout(order: panelPageOrder, hidden: hiddenPanelPages)
    }

    /// Fills modules an older version did not store with their defaults. Old JSON predates new
    /// modules, and `config(_:)` reports a missing module as disabled, so every upgrade path
    /// must fill them or a newly added module such as `accessories` would silently turn off.
    func withMissingModulesFilled() -> MonitorConfiguration {
        var modules = modules
        var changed = false
        for module in MonitorModule.allCases where modules[module] == nil {
            modules[module] = MonitorConfiguration.default.config(module)
            changed = true
        }
        guard changed else { return self }
        return MonitorConfiguration(modules: modules, compact: compact,
                                    panelPageOrder: panelPageOrder,
                                    hiddenPanelPages: hiddenPanelPages)
    }

    /// Decodes stored or backup JSON from any version, filling modules that older versions did
    /// not store and normalizing the panel layout. Both the store load path and the backup
    /// snapshot path go through this so old installations upgrade the same way either way.
    static func upgraded(from data: Data) -> MonitorConfiguration? {
        guard let decoded = try? JSONDecoder().decode(MonitorConfiguration.self, from: data) else {
            return nil
        }
        return decoded.withMissingModulesFilled().normalized()
    }

    static let `default`: MonitorConfiguration = {
        var modules: [MonitorModule: ModuleConfig] = [:]
        for m in MonitorModule.allCases {
            let on: Set<MonitorModule> = [.cpu, .memory, .network, .temperature, .fan, .disk, .gpu, .power, .battery, .accessories]
            let bar: Set<MonitorModule> = [.cpu, .memory, .temperature]
            modules[m] = ModuleConfig(enabled: on.contains(m), inMenuBar: bar.contains(m),
                                      style: m == .cpu ? .sparkline : .text, interval: m.defaultInterval)
        }
        return MonitorConfiguration(modules: modules, compact: true,
                                    panelPageOrder: PanelPage.allCases, hiddenPanelPages: [])
    }()
}

/// Old stored JSON may not have `compact` or the panel fields, and its panel lists may contain
/// pages this version does not know. Absent fields fall back to the defaults so upgrading never
/// drops the whole configuration.
extension MonitorConfiguration {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modules = try container.decode([MonitorModule: ModuleConfig].self, forKey: .modules)
        compact = try container.decodeIfPresent(Bool.self, forKey: .compact) ?? true
        panelPageOrder = container.decodeFlexiblePages(forKey: .panelPageOrder) ?? PanelPage.allCases
        hiddenPanelPages = Set(container.decodeFlexiblePages(forKey: .hiddenPanelPages) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modules, forKey: .modules)
        try container.encode(compact, forKey: .compact)
        try container.encode(panelPageOrder, forKey: .panelPageOrder)
        // Sets have no stable order, so emit hidden pages filtered by allCases to keep the JSON stable.
        try container.encode(PanelPage.allCases.filter { hiddenPanelPages.contains($0) },
                             forKey: .hiddenPanelPages)
    }

    private enum CodingKeys: String, CodingKey {
        case modules, compact, panelPageOrder, hiddenPanelPages
    }
}

private extension KeyedDecodingContainer {
    /// Decodes an array of page raw values, silently dropping ones this version does not know.
    func decodeFlexiblePages(forKey key: Key) -> [PanelPage]? {
        guard let raw = try? decodeIfPresent([String].self, forKey: key) else { return nil }
        return raw.compactMap(PanelPage.init(rawValue:))
    }
}

/// Persists the configuration in UserDefaults (per-user preference, not shared data).
@MainActor
@Observable
final class MonitorSettingsStore {
    nonisolated static let key = "monitor.configuration.v1"

    var configuration: MonitorConfiguration {
        didSet { save() }
    }

    /// The domain the configuration lives in. The test host gets its own throwaway domain so a
    /// test that changes the configuration never changes the person's menu bar or panel.
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = TestHost.defaults) {
        self.defaults = defaults
        // The synthetic `--snapshot-demo` run shows the default menu bar (CPU sparkline, memory,
        // temperature) whatever this Mac's settings are, and never saves.
        configuration = DemoData.snapshot ? .default : Self.load(defaults)
    }

    subscript(module: MonitorModule) -> ModuleConfig {
        get { configuration.config(module) }
        set { configuration.modules[module] = newValue }
    }

    /// Re-reads the stored configuration after settings are imported.
    func reload() {
        configuration = Self.load(defaults)
    }

    /// Decodes the stored configuration, going through the shared upgrade path: modules that
    /// older versions did not have are filled with their defaults and the panel layout is
    /// normalized.
    private static func load(_ defaults: UserDefaults) -> MonitorConfiguration {
        guard let data = defaults.data(forKey: key),
              let saved = MonitorConfiguration.upgraded(from: data) else {
            return .default
        }
        return saved
    }

    private func save() {
        guard !DemoData.snapshot else { return }
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
