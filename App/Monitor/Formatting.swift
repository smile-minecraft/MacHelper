import Foundation

enum Fmt {
    static func percent(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "\(Int((v * 100).rounded()))%"
    }

    /// Compact byte rate for the menu bar: "940K", "12M", "1.2G".
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let b = bytesPerSecond else { return "–" }
        return compactBytes(b)
    }

    static func compactBytes(_ b: Double) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = max(b, 0)
        var i = 0
        while value >= 1000, i < units.count - 1 {
            value /= 1024
            i += 1
        }
        let digits = value < 10 && i > 0 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return digits + units[i]
    }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    /// RAM sizes use binary units, so 32 GiB reads "32 GB" like Activity Monitor (not "34.36 GB").
    static func memory(_ b: UInt64) -> String {
        b == 0 ? "0" : ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .memory)
    }

    static func shortPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    static func celsius(_ c: Double?) -> String {
        guard let c else { return "–" }
        return "\(Int(c.rounded()))°"
    }

    static func rpm(_ r: Double?) -> String {
        guard let r else { return "–" }
        return "\(Int(r.rounded()))"
    }

    static func watts(_ w: Double?) -> String {
        guard let w else { return "–" }
        return w < 10 ? String(format: "%.1fW", w) : String(format: "%.0fW", w)
    }
}

extension Fmt {
    /// Readable names for Apple Silicon HID sensors ("PMU tdie6" → "CPU die 6").
    static func sensorName(_ raw: String) -> String {
        let digits = raw.reversed().prefix { $0.isNumber }.reversed()
        let n = String(digits)
        let stem = raw.dropLast(n.count).trimmingCharacters(in: .whitespaces)
        let second = stem.hasPrefix("PMU2")
        switch stem {
        case "PMU tdie", "PMU2 tdie": return String(localized: "CPU die \(n)") + (second ? " ²" : "")
        case "PMU tdev", "PMU2 tdev": return String(localized: "Device sensor \(n)") + (second ? " ²" : "")
        case "PMU tcal", "PMU2 tcal": return String(localized: "Calibration sensor") + (second ? " ²" : "")
        case "NAND CH0 temp": return String(localized: "SSD")
        case "gas gauge battery": return String(localized: "Battery")
        default: return raw
        }
    }
}
