/// A four-character SMC code such as `F0Ac` or the type `flt `.
public struct FourCC: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Strings shorter than four characters are padded with spaces (`"flt"` → `"flt "`).
    public init(_ string: String) {
        var bytes = Array(string.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        rawValue = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public init(stringLiteral value: String) { self.init(value) }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: rawValue >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
