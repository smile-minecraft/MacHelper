import Foundation

public enum ChipFamily: Sendable, Hashable, CustomStringConvertible {
    case intel
    /// Apple Silicon, e.g. generation 4 / variant "Pro" for "Apple M4 Pro".
    case apple(generation: Int, variant: String?)
    case unknown(String)

    public static let current: ChipFamily = parse(brand: sysctlString("machdep.cpu.brand_string") ?? "")

    public static func parse(brand: String) -> ChipFamily {
        if brand.localizedCaseInsensitiveContains("intel") { return .intel }
        // "Apple M4", "Apple M3 Max", "Apple M5 Pro"
        let parts = brand.split(separator: " ")
        if parts.count >= 2, parts[0] == "Apple", parts[1].first == "M", let gen = Int(parts[1].dropFirst()) {
            return .apple(generation: gen, variant: parts.count > 2 ? parts[2...].joined(separator: " ") : nil)
        }
        return .unknown(brand)
    }

    public var isAppleSilicon: Bool {
        if case .apple = self { return true }
        return false
    }

    /// Base M4 (not Pro/Max/Ultra). The SMC CPU rail layout used by the power sampler is verified
    /// there; later chips expose different rails. Used to keep the fallback from reading another
    /// part's power.
    public var isBaseM4: Bool {
        if case .apple(generation: 4, variant: nil) = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .intel: "Intel"
        case .apple(let g, let v): "Apple M\(g)" + (v.map { " \($0)" } ?? "")
        case .unknown(let s): "Unknown (\(s))"
        }
    }
}

public func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

public func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    // Some sysctls are 32-bit; size tells us how many bytes were written.
    return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
}
