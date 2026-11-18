import Foundation

/// A page in the menu bar panel. The raw values are stored in user defaults and in backups,
/// so they must stay stable.
enum PanelPage: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, disk, network, battery, power
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: String(localized: "CPU")
        case .gpu: String(localized: "GPU")
        case .memory: String(localized: "Memory")
        case .disk: String(localized: "SSD")
        case .network: String(localized: "Network")
        case .battery: String(localized: "Battery")
        case .power: String(localized: "Power")
        }
    }

    var icon: String {
        switch self {
        case .cpu: "px.cpu"
        case .gpu: "px.gpu"
        case .memory: "px.memory"
        case .disk: "px.ssd"
        case .network: "px.network"
        case .battery: "px.battery"
        case .power: "px.power"
        }
    }

    /// Pages whose hardware may be absent. Battery needs an internal battery, or at least one
    /// connected accessory with a reading — enabling the accessories module alone is not enough.
    /// Power needs power or fan sensors.
    func isAvailable(in modules: Set<MonitorModule>, hasAccessories: Bool) -> Bool {
        switch self {
        case .battery:
            modules.contains(.battery) || hasAccessories
        case .power:
            !modules.isDisjoint(with: [.power, .fan])
        default:
            true
        }
    }
}

/// Which pages the panel shows and in what order. `order` lists every page (the user controls the
/// sequence), `hidden` lists the pages the user switched off. `visiblePages` applies both filters,
/// so it is the single source of truth for what the panel draws.
struct PanelLayout: Hashable, Sendable {
    var order: [PanelPage]
    var hidden: Set<PanelPage>

    func visiblePages(isAvailable: (PanelPage) -> Bool) -> [PanelPage] {
        order.filter { !hidden.contains($0) && isAvailable($0) }
    }
}
