import Foundation

/// An sRGB color with alpha, written as `#RRGGBB` or `#RRGGBBAA` (the form VS Code themes use).
public struct HexColor: Codable, Sendable, Hashable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    public init(_ rgb: UInt32, alpha: Double = 1) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, alpha: alpha)
    }

    /// Accepts `#RGB`, `#RGBA`, `#RRGGBB` and `#RRGGBBAA` (the leading `#` is optional).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard [3, 4, 6, 8].contains(s.count), s.allSatisfy(\.isHexDigit), let v = UInt64(s, radix: 16) else { return nil }
        func short(_ shift: UInt64) -> Double { Double((v >> shift) & 0xF) * 17 / 255 }
        func long(_ shift: UInt64) -> Double { Double((v >> shift) & 0xFF) / 255 }
        switch s.count {
        case 3: self.init(red: short(8), green: short(4), blue: short(0))
        case 4: self.init(red: short(12), green: short(8), blue: short(4), alpha: short(0))
        case 6: self.init(red: long(16), green: long(8), blue: long(0))
        default: self.init(red: long(24), green: long(16), blue: long(8), alpha: long(0))
        }
    }

    public var hex: String {
        let rgb = String(format: "#%02X%02X%02X", Self.byte(red), Self.byte(green), Self.byte(blue))
        return alpha >= 1 ? rgb : rgb + String(format: "%02X", Self.byte(alpha))
    }

    public var description: String { hex }

    /// Relative luminance (WCAG), 0 = black, 1 = white.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    public var isDark: Bool { luminance < 0.4 }

    public func withAlpha(_ a: Double) -> HexColor { HexColor(red: red, green: green, blue: blue, alpha: a) }

    /// Linear mix toward `other` (0 = self, 1 = other); alpha mixes too.
    public func mixed(with other: HexColor, _ t: Double) -> HexColor {
        let t = Self.clamp(t)
        return HexColor(red: red + (other.red - red) * t, green: green + (other.green - green) * t,
                        blue: blue + (other.blue - blue) * t, alpha: alpha + (other.alpha - alpha) * t)
    }

    /// WCAG contrast ratio against another color (1…21).
    public func contrast(with other: HexColor) -> Double {
        let a = luminance + 0.05, b = other.luminance + 0.05
        return max(a, b) / min(a, b)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = HexColor(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad color \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    private static func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
    private static func byte(_ v: Double) -> Int { Int((clamp(v) * 255).rounded()) }
}

/// Every color the interface uses. Surfaces and text first, then the data colors charts and
/// badges use (the names describe their default hue; a theme may remap them).
public struct ThemeColors: Codable, Sendable, Hashable {
    public enum Role: String, CaseIterable, Codable, Sendable, Identifiable {
        case base, card, inset, raised, stroke, hairline, text, textMuted, textFaint
        case accent, blue, cyan, mint, amber, rose, violet, orange, slate
        public var id: String { rawValue }

        public var isSurface: Bool {
            switch self {
            case .base, .card, .inset, .raised, .stroke, .hairline, .text, .textMuted, .textFaint: true
            default: false
            }
        }
    }

    public var base, card, inset, raised, stroke, hairline: HexColor
    public var text, textMuted, textFaint: HexColor
    public var accent, blue, cyan, mint, amber, rose, violet, orange, slate: HexColor

    public init(base: HexColor, card: HexColor, inset: HexColor, raised: HexColor, stroke: HexColor, hairline: HexColor,
                text: HexColor, textMuted: HexColor, textFaint: HexColor, accent: HexColor, blue: HexColor, cyan: HexColor,
                mint: HexColor, amber: HexColor, rose: HexColor, violet: HexColor, orange: HexColor, slate: HexColor) {
        self.base = base; self.card = card; self.inset = inset; self.raised = raised; self.stroke = stroke; self.hairline = hairline
        self.text = text; self.textMuted = textMuted; self.textFaint = textFaint
        self.accent = accent; self.blue = blue; self.cyan = cyan; self.mint = mint; self.amber = amber
        self.rose = rose; self.violet = violet; self.orange = orange; self.slate = slate
    }

    public subscript(role: Role) -> HexColor {
        get {
            switch role {
            case .base: base
            case .card: card
            case .inset: inset
            case .raised: raised
            case .stroke: stroke
            case .hairline: hairline
            case .text: text
            case .textMuted: textMuted
            case .textFaint: textFaint
            case .accent: accent
            case .blue: blue
            case .cyan: cyan
            case .mint: mint
            case .amber: amber
            case .rose: rose
            case .violet: violet
            case .orange: orange
            case .slate: slate
            }
        }
        set {
            switch role {
            case .base: base = newValue
            case .card: card = newValue
            case .inset: inset = newValue
            case .raised: raised = newValue
            case .stroke: stroke = newValue
            case .hairline: hairline = newValue
            case .text: text = newValue
            case .textMuted: textMuted = newValue
            case .textFaint: textFaint = newValue
            case .accent: accent = newValue
            case .blue: blue = newValue
            case .cyan: cyan = newValue
            case .mint: mint = newValue
            case .amber: amber = newValue
            case .rose: rose = newValue
            case .violet: violet = newValue
            case .orange: orange = newValue
            case .slate: slate = newValue
            }
        }
    }
}

/// A named color theme. `dark` set means the theme has a light and a dark variant and follows
/// the system appearance; otherwise the app uses the appearance that matches `colors`.
public struct ThemeDefinition: Codable, Sendable, Hashable, Identifiable {
    public enum Origin: String, Codable, Sendable { case builtIn, custom, vscode }

    public var schemaVersion = 1
    public var id: String
    public var name: String
    public var origin: Origin
    public var colors: ThemeColors
    public var dark: ThemeColors?
    /// Where an imported theme came from (file or extension), for display only.
    public var source: String?

    public init(id: String, name: String, origin: Origin, colors: ThemeColors, dark: ThemeColors? = nil, source: String? = nil) {
        self.id = id
        self.name = name
        self.origin = origin
        self.colors = colors
        self.dark = dark
        self.source = source
    }

    public var followsSystemAppearance: Bool { dark != nil }
    /// For a single-variant theme: whether it is a dark theme.
    public var isDark: Bool { colors.base.isDark }

    public func colors(dark isDarkAppearance: Bool) -> ThemeColors {
        guard let dark else { return colors }
        return isDarkAppearance ? dark : colors
    }
}

public enum BuiltInThemes {
    /// Default: a retro night palette for the pixel style.
    public static let pixelNight = ThemeDefinition(
        id: "builtin.pixel-night", name: "Pixel Night", origin: .builtIn,
        colors: ThemeColors(
            base: HexColor(0x1A1C2C), card: HexColor(0x23263A), inset: HexColor(0x2D3149), raised: HexColor(0x363D5C),
            stroke: HexColor(0x566C86, alpha: 0.75), hairline: HexColor(0x94B0C2, alpha: 0.14),
            text: HexColor(0xF4F4F4), textMuted: HexColor(0xA9BDCB), textFaint: HexColor(0x7C8FA8),
            accent: HexColor(0x5BD080), blue: HexColor(0x41A6F6), cyan: HexColor(0x73EFF7), mint: HexColor(0x5BD080),
            amber: HexColor(0xFFCD75), rose: HexColor(0xF0607A), violet: HexColor(0x7FA7C9), orange: HexColor(0xEF7D57),
            slate: HexColor(0x94B0C2)))

    public static let pixelDay = ThemeDefinition(
        id: "builtin.pixel-day", name: "Pixel Day", origin: .builtIn,
        colors: ThemeColors(
            base: HexColor(0xF2EEE3), card: HexColor(0xFFFCF4), inset: HexColor(0xE7E1D2), raised: HexColor(0xFFFFFF),
            stroke: HexColor(0x29366F, alpha: 0.45), hairline: HexColor(0x29366F, alpha: 0.12),
            text: HexColor(0x1A1C2C), textMuted: HexColor(0x48506B), textFaint: HexColor(0x6B7390),
            accent: HexColor(0x23885A), blue: HexColor(0x3B5DC9), cyan: HexColor(0x1F7F8C), mint: HexColor(0x23885A),
            amber: HexColor(0xB37400), rose: HexColor(0xB13E53), violet: HexColor(0x4C6A92), orange: HexColor(0xC4522B),
            slate: HexColor(0x566C86)))

    /// The previous neutral zinc look; follows the system light / dark setting.
    public static let classic = ThemeDefinition(
        id: "builtin.classic", name: "Classic", origin: .builtIn,
        colors: ThemeColors(
            base: HexColor(0xFAFAFA), card: HexColor(0xFFFFFF), inset: HexColor(0xF0F0F2), raised: HexColor(0xFFFFFF),
            stroke: HexColor(0x18181B, alpha: 0.08), hairline: HexColor(0x18181B, alpha: 0.06),
            text: HexColor(0x18181B), textMuted: HexColor(0x52525B), textFaint: HexColor(0x71717A),
            accent: HexColor(0x3DA87A), blue: HexColor(0x5C8CDB), cyan: HexColor(0x40A8BD), mint: HexColor(0x3DA87A),
            amber: HexColor(0xB07D2A), rose: HexColor(0xDB636E), violet: HexColor(0x7D8CB3), orange: HexColor(0xDB7A40),
            slate: HexColor(0x949AA3)),
        dark: ThemeColors(
            base: HexColor(0x111113), card: HexColor(0x18181B), inset: HexColor(0x232327), raised: HexColor(0x2C2C31),
            stroke: HexColor(0xFFFFFF, alpha: 0.075), hairline: HexColor(0xFFFFFF, alpha: 0.06),
            text: HexColor(0xF4F4F5), textMuted: HexColor(0xA1A1AA), textFaint: HexColor(0x8B8B94),
            accent: HexColor(0x3DA87A), blue: HexColor(0x5C8CDB), cyan: HexColor(0x40A8BD), mint: HexColor(0x3DA87A),
            amber: HexColor(0xD69E40), rose: HexColor(0xDB636E), violet: HexColor(0x7D8CB3), orange: HexColor(0xDB7A40),
            slate: HexColor(0x949AA3)))

    /// Default: an instrument panel. Aluminum and graphite surfaces, graphite ink; charts stay
    /// neutral and only state is colored (amber = attention, red = critical). The data roles are
    /// graded neutrals so two series stay apart without a rainbow.
    public static let instrument = ThemeDefinition(
        id: "builtin.instrument", name: "Instrument", origin: .builtIn,
        colors: ThemeColors(
            base: HexColor(0xE8E9EB), card: HexColor(0xF4F5F6), inset: HexColor(0xDCDEE1), raised: HexColor(0xFFFFFF),
            stroke: HexColor(0x1C1E22, alpha: 0.10), hairline: HexColor(0x1C1E22, alpha: 0.08),
            text: HexColor(0x1C1E22), textMuted: HexColor(0x575C64), textFaint: HexColor(0x6E737B),
            accent: HexColor(0x24272C), blue: HexColor(0x3A3F47), cyan: HexColor(0x5E646D), mint: HexColor(0x3D6B5A),
            amber: HexColor(0xA86A12), rose: HexColor(0xC0362D), violet: HexColor(0x4A5059), orange: HexColor(0x8A5A2B),
            slate: HexColor(0x6E737B)),
        dark: ThemeColors(
            base: HexColor(0x1E2024), card: HexColor(0x26292E), inset: HexColor(0x30343A), raised: HexColor(0x373B42),
            stroke: HexColor(0xFFFFFF, alpha: 0.10), hairline: HexColor(0xFFFFFF, alpha: 0.07),
            text: HexColor(0xECEDEF), textMuted: HexColor(0xA6ABB3), textFaint: HexColor(0x8A9099),
            accent: HexColor(0xE4E6E9), blue: HexColor(0xC9CDD3), cyan: HexColor(0x9BA1AA), mint: HexColor(0x8FC2AE),
            amber: HexColor(0xE6A63E), rose: HexColor(0xF26B60), violet: HexColor(0xB4B9C1), orange: HexColor(0xD9A16A),
            slate: HexColor(0x8A9099)))

    public static let all = [instrument, pixelNight, pixelDay, classic]
    public static let defaultID = instrument.id
}
