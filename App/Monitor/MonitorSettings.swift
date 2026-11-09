import Foundation
import Observation

enum MonitorModule: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, disk, network, battery, temperature, fan, power
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: String(localized: "Memory")
        case .disk: String(localized: "Disk")
        case .network: String(localized: "Network")
        case .battery: String(localized: "Battery")
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
        default: MenuBarStyle.allCases.filter { $0 != .dual }
        }
    }

    var defaultInterval: Double {
        switch self {
        case .disk, .battery: 5
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

    func config(_ m: MonitorModule) -> ModuleConfig {
        modules[m] ?? ModuleConfig(enabled: false, inMenuBar: false, style: .text, interval: m.defaultInterval)
    }

    static let `default`: MonitorConfiguration = {
        var modules: [MonitorModule: ModuleConfig] = [:]
        for m in MonitorModule.allCases {
            let on: Set<MonitorModule> = [.cpu, .memory, .network, .temperature, .fan, .disk, .gpu, .power, .battery]
            let bar: Set<MonitorModule> = [.cpu, .memory, .temperature]
            modules[m] = ModuleConfig(enabled: on.contains(m), inMenuBar: bar.contains(m),
                                      style: m == .cpu ? .sparkline : .text, interval: m.defaultInterval)
        }
        return MonitorConfiguration(modules: modules, compact: true)
    }()
}

/// Persists the configuration in UserDefaults (per-user preference, not shared data).
@MainActor
@Observable
final class MonitorSettingsStore {
    nonisolated static let key = "monitor.configuration.v1"

    var configuration: MonitorConfiguration {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(MonitorConfiguration.self, from: data) {
            configuration = saved
        } else {
            configuration = .default
        }
    }

    subscript(module: MonitorModule) -> ModuleConfig {
        get { configuration.config(module) }
        set { configuration.modules[module] = newValue }
    }

    /// Re-reads the stored configuration after settings are imported.
    func reload() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(MonitorConfiguration.self, from: data) {
            configuration = saved
        } else {
            configuration = .default
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
