import Diagnostics
import Metrics
import SwiftUI

/// How a reading should be read at a glance: fine, worth a look, or a problem. Shared by the
/// overview, the menu bar panel and the menu bar item so the same value always gets the same color.
enum StatusLevel: Int, Comparable {
    case good, attention, critical

    static func < (a: StatusLevel, b: StatusLevel) -> Bool { a.rawValue < b.rawValue }

    var color: Color {
        switch self {
        // Instrument rule: normal readings stay in the text color; only attention and critical are colored.
        case .good: Palette.text
        case .attention: Theme.amber
        case .critical: Theme.rose
        }
    }
}

/// A level plus the plain-language word for it ("Light", "Tight", "Almost full").
struct Reading {
    let level: StatusLevel
    let word: String
}

enum StatusRules {
    static func cpu(_ total: Double?) -> Reading? {
        guard let t = total else { return nil }
        if t >= 0.85 { return Reading(level: .critical, word: String(localized: "Very busy")) }
        if t >= 0.6 { return Reading(level: .attention, word: String(localized: "Busy")) }
        return Reading(level: .good, word: String(localized: "Light"))
    }

    static func memory(_ m: MemoryReading?) -> Reading? {
        guard let m else { return nil }
        switch m.pressure {
        case .critical: return Reading(level: .critical, word: String(localized: "Running out"))
        case .warning: return Reading(level: .attention, word: String(localized: "Tight"))
        case .normal: return Reading(level: .good, word: String(localized: "Plenty"))
        }
    }

    static func temperature(_ celsius: Double?) -> Reading? {
        guard let c = celsius else { return nil }
        if c >= 95 { return Reading(level: .critical, word: String(localized: "Too hot")) }
        if c >= 80 { return Reading(level: .attention, word: String(localized: "Hot")) }
        if c >= 65 { return Reading(level: .good, word: String(localized: "Warm")) }
        return Reading(level: .good, word: String(localized: "Cool"))
    }

    /// Free bytes on the startup disk (see `DiskSpaceLevels`: 25 GB or more is fine, under 10 GB is critical).
    static func disk(freeBytes: Int64?) -> Reading? {
        guard let b = freeBytes else { return nil }
        switch DiskSpaceLevels.level(freeBytes: Double(b)) {
        case .critical: return Reading(level: .critical, word: String(localized: "Almost full"))
        case .low: return Reading(level: .attention, word: String(localized: "Getting low"))
        case .healthy: return Reading(level: .good, word: String(localized: "Plenty of space"))
        }
    }

    /// For 0…1 values shown in the menu bar (CPU, GPU, memory).
    static func fraction(_ f: Double?) -> StatusLevel? {
        guard let f else { return nil }
        return f >= 0.85 ? .critical : (f >= 0.6 ? .attention : .good)
    }
}

@MainActor
extension MonitorStore {
    var diskFreeBytes: Int64? { disk.map { Int64($0.availableBytes) } }

    var diskFreeFraction: Double? {
        disk.flatMap { $0.totalBytes > 0 ? Double($0.availableBytes) / Double($0.totalBytes) : nil }
    }

    var memoryFraction: Double? {
        memory.flatMap { $0.totalBytes > 0 ? Double($0.usedBytes) / Double($0.totalBytes) : nil }
    }
}
