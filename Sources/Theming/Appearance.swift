import Foundation

/// The user's look-and-feel choices. Optional-free with defaults on decode, so older or partial
/// settings always load.
public struct AppearanceSettings: Codable, Sendable, Equatable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        /// Notched corners, block borders, segmented gauges.
        case pixel
        /// Rounded cards and continuous rings.
        case smooth
    }

    /// Font for page titles, card headings and big numbers.
    public enum DisplayFont: Codable, Sendable, Hashable {
        case pixel, system, rounded, monospaced
        case family(String)
    }

    /// Font for everything meant to be read: descriptions, lists, settings.
    public enum BodyFont: Codable, Sendable, Hashable {
        case system
        case family(String)
    }

    /// How much the interface shows. Simple: everyday tools and plain-language summaries;
    /// advanced: every page, chart and technical detail.
    public enum Mode: String, Codable, Sendable, CaseIterable { case simple, advanced }

    /// Which icons the interface draws. Single icons replaced by hand win over every set.
    public enum IconSet: Codable, Sendable, Hashable {
        /// The built-in pixel art.
        case pixel
        /// macOS SF Symbols tinted with theme colors.
        case symbols
        /// An imported icon pack (folder id); icons it lacks fall back to the pixel art.
        case pack(String)
    }

    /// Menu bar values: system rounded (default, easiest to read at 22 pt), plain system, or pixel.
    public enum MenuBarFont: String, Codable, Sendable, CaseIterable { case rounded, system, pixel }
    /// What identifies each item in the menu bar.
    public enum MenuBarLabel: String, Codable, Sendable, CaseIterable { case text, icon, none }

    public var mode: Mode = .simple
    public var themeID: String = BuiltInThemes.instrument.id
    public var style: Style = .smooth
    public var displayFont: DisplayFont = .rounded
    public var bodyFont: BodyFont = .system
    /// Multiplies every font size (0.8…1.5).
    public var textScale: Double = 1
    public var iconSet: IconSet = .pixel
    /// App icon shown in the Dock and the panel header (`AppLogo.all` ids).
    public var appLogo: String = AppLogo.defaultID
    public var menuBarFont: MenuBarFont = .rounded
    public var menuBarLabel: MenuBarLabel = .text
    /// Tint values that need attention with a pale version of the level color (close to white).
    /// Off: every value uses the menu bar's own text color.
    public var menuBarColored: Bool = false

    public static let textScaleRange: ClosedRange<Double> = 0.8...1.5

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings()
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? d.mode
        themeID = (try? c.decode(String.self, forKey: .themeID)) ?? d.themeID
        style = (try? c.decode(Style.self, forKey: .style)) ?? d.style
        displayFont = (try? c.decode(DisplayFont.self, forKey: .displayFont)) ?? d.displayFont
        bodyFont = (try? c.decode(BodyFont.self, forKey: .bodyFont)) ?? d.bodyFont
        textScale = ((try? c.decode(Double.self, forKey: .textScale)) ?? d.textScale).clamped(to: Self.textScaleRange)
        iconSet = (try? c.decode(IconSet.self, forKey: .iconSet)) ?? d.iconSet
        appLogo = (try? c.decode(String.self, forKey: .appLogo)).flatMap { AppLogo.ids.contains($0) ? $0 : nil } ?? d.appLogo
        menuBarFont = (try? c.decode(MenuBarFont.self, forKey: .menuBarFont)) ?? d.menuBarFont
        menuBarLabel = (try? c.decode(MenuBarLabel.self, forKey: .menuBarLabel)) ?? d.menuBarLabel
        menuBarColored = (try? c.decode(Bool.self, forKey: .menuBarColored)) ?? d.menuBarColored
    }
}

/// The built-in app icons. The bundle carries `defaultID` (what Finder shows); the others are
/// asset images `logo.<id>` that replace the Dock icon while MacHelper runs.
public enum AppLogo {
    public struct Entry: Sendable, Hashable, Identifiable {
        public let id: String
        /// English name (the app localizes it).
        public let title: String
    }

    public static let all: [Entry] = [
        Entry(id: "apple", title: "Pixel apple"),
        Entry(id: "slime", title: "Blue slime"),
        Entry(id: "sprout", title: "Slime with a leaf"),
        Entry(id: "fan", title: "Fan"),
    ]
    public static let ids = Set(all.map(\.id))
    public static let defaultID = "apple"
}

/// Ready-made looks. Picking one sets the theme, shape, display font and icons together; any
/// later change to those turns the look into "custom" (`matching` returns nil).
public enum AppearancePreset: String, CaseIterable, Sendable {
    /// Instrument panel: neutral aluminum / graphite (follows light / dark), rounded shapes,
    /// system rounded numbers; color only for state.
    case standard
    /// Retro game look: pixel night colors, notched shapes, the Cubic 11 pixel font.
    case pixelRetro

    public func apply(to s: inout AppearanceSettings) {
        switch self {
        case .standard:
            s.themeID = BuiltInThemes.instrument.id; s.style = .smooth; s.displayFont = .rounded; s.bodyFont = .system; s.iconSet = .pixel
        case .pixelRetro:
            s.themeID = BuiltInThemes.pixelNight.id; s.style = .pixel; s.displayFont = .pixel; s.bodyFont = .system; s.iconSet = .pixel
        }
    }

    public static func matching(_ s: AppearanceSettings) -> AppearancePreset? {
        allCases.first { preset in
            var probe = s
            preset.apply(to: &probe)
            return probe == s
        }
    }
}

extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { isFinite ? Swift.min(Swift.max(self, r.lowerBound), r.upperBound) : r.lowerBound }
}

/// Size snapping for the pixel font: Cubic 11 is drawn on an 11-pixel grid, so it is sharpest at
/// multiples of 5.5 pt (each font pixel = a whole number of Retina pixels).
public enum PixelFontMetrics {
    public static let grid: Double = 5.5

    public static func snapped(_ size: Double) -> Double {
        max(11, (size / grid).rounded() * grid)
    }
}

/// User themes saved as JSON files (one per theme) in a folder.
public struct ThemeLibrary: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func load() -> [ThemeDefinition] {
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(ThemeDefinition.self, from: $0) } }
            .filter { $0.origin != .builtIn }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ theme: ThemeDefinition) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(theme).write(to: url(for: theme.id), options: .atomic)
    }

    public func delete(id: String) throws {
        let u = url(for: id)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }

    /// A file name from the id: letters, digits, dots and dashes only.
    public func url(for id: String) -> URL {
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" }.prefix(120))
        return directory.appending(path: (safe.isEmpty || safe.hasPrefix(".") ? "theme" + safe : safe) + ".json")
    }

    /// An id not used by `existing`, based on `base`.
    public static func uniqueID(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var i = 2
        while existing.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }
}
