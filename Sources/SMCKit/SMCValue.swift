import Foundation

/// Raw bytes read from (or about to be written to) an SMC key, plus its declared type.
public struct SMCValue: Sendable, Hashable, CustomStringConvertible {
    public let key: FourCC
    public let type: FourCC
    public let bytes: [UInt8]

    public init(key: FourCC, type: FourCC, bytes: [UInt8]) {
        self.key = key
        self.type = type
        self.bytes = bytes
    }

    /// Numeric interpretation of the value, or nil when the type is not numeric / unknown.
    public var doubleValue: Double? { SMCCodec.decode(type: type, bytes: bytes) }

    public var description: String {
        if let v = doubleValue { return "\(key) [\(type)] = \(v)" }
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        return "\(key) [\(type)] = <\(hex)>"
    }
}

/// Encoding and decoding of SMC data types.
///
/// - `flt `: IEEE754 float, little-endian (used on Apple Silicon and newer Intel keys)
/// - `fpXY` / `spXY`: unsigned / signed fixed point, big-endian, Y = fractional bits (hex digit)
/// - `ui8 `…`ui64`, `si8 `…`si64`: big-endian integers
/// - `flag`: one byte boolean
public enum SMCCodec {
    public static func decode(type: FourCC, bytes: [UInt8]) -> Double? {
        let t = type.description
        switch t {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "flag":
            guard let b = bytes.first else { return nil }
            return b == 0 ? 0 : 1
        case "ui8 ", "ui16", "ui32", "ui64":
            return bytes.isEmpty ? nil : Double(bigEndianUnsigned(bytes))
        case "si8 ", "si16", "si32", "si64":
            return bytes.isEmpty ? nil : Double(bigEndianSigned(bytes))
        default:
            break
        }
        if let (signed, fraction) = fixedPointFormat(t), bytes.count >= 2 {
            let raw = Array(bytes.prefix(2))
            let value = signed ? Double(bigEndianSigned(raw)) : Double(bigEndianUnsigned(raw))
            return value / Double(1 << fraction)
        }
        return nil
    }

    /// Encodes `value` into exactly `size` bytes of the given type. Returns nil for unsupported types.
    public static func encode(_ value: Double, type: FourCC, size: Int) -> [UInt8]? {
        let t = type.description
        switch t {
        case "flt ":
            guard size == 4 else { return nil }
            let bits = Float(value).bitPattern
            return [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: bits >> $0) }
        case "flag":
            guard size == 1 else { return nil }
            return [value != 0 ? 1 : 0]
        case "ui8 ", "ui16", "ui32", "ui64":
            let rounded = value.rounded()
            guard rounded >= 0, size < 8 ? rounded < Double(UInt64(1) << UInt64(size * 8)) : rounded < 0x1p64
            else { return nil }
            return bigEndianBytes(UInt64(rounded), size: size)
        case "si8 ", "si16", "si32", "si64":
            let rounded = value.rounded()
            let limit = Double(UInt64(1) << UInt64(min(size, 8) * 8 - 1))
            guard rounded >= -limit, rounded < limit else { return nil }
            return bigEndianBytes(UInt64(bitPattern: Int64(rounded)), size: size)
        default:
            break
        }
        if let (signed, fraction) = fixedPointFormat(t), size == 2 {
            let scaled = (value * Double(1 << fraction)).rounded()
            if signed {
                guard let v = Int16(exactly: scaled) else { return nil }
                return bigEndianBytes(UInt64(UInt16(bitPattern: v)), size: 2)
            }
            guard let v = UInt16(exactly: scaled) else { return nil }
            return bigEndianBytes(UInt64(v), size: 2)
        }
        return nil
    }

    private static func fixedPointFormat(_ t: String) -> (signed: Bool, fraction: Int)? {
        let chars = Array(t)
        guard chars.count == 4 else { return nil }
        let prefix = String(chars[0...1])
        guard prefix == "fp" || prefix == "sp",
              let whole = Int(String(chars[2]), radix: 16),
              let fraction = Int(String(chars[3]), radix: 16),
              whole + fraction == (prefix == "sp" ? 15 : 16)
        else { return nil }
        return (prefix == "sp", fraction)
    }

    private static func bigEndianUnsigned(_ bytes: [UInt8]) -> UInt64 {
        bytes.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func bigEndianSigned(_ bytes: [UInt8]) -> Int64 {
        let n = min(bytes.count, 8)
        let raw = bigEndianUnsigned(bytes)
        let shift = UInt64(64 - n * 8)
        return Int64(bitPattern: raw << shift) >> Int64(shift)
    }

    private static func bigEndianBytes(_ value: UInt64, size: Int) -> [UInt8]? {
        guard (1...8).contains(size) else { return nil }
        return (0..<size).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }
}
