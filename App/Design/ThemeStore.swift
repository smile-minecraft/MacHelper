import AppKit
import CleanEngine
import CoreText
import Observation
import SwiftUI
import Theming

/// The current look: theme colors, interface style, fonts and text size. Views read it through
/// `Palette`, `Theme`, `Font.mh…` and `SurfaceShape`, so SwiftUI's observation redraws everything
/// when it changes. Mutated only on the main thread (from the settings UI).
@Observable
final class ThemeStore: @unchecked Sendable {
    nonisolated(unsafe) static let shared = ThemeStore()

    nonisolated static let settingsKey = "appearance.settings.v1"
    /// PostScript name of the bundled 俐方體11號 (Cubic 11, SIL OFL / free license, see Fonts/Cubic_11-OFL.txt).
    static let pixelFontName = "Cubic_11"

    var settings: AppearanceSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            rebuild()
        }
    }

    private(set) var customThemes: [ThemeDefinition] = []
    /// Snapshot instances run beside the real app and must never write its settings.
    @ObservationIgnored private let persists = !CommandLine.arguments.contains { $0.hasPrefix("--snapshot") || $0 == "--export-icon-template" }
    /// Resolved colors for the current theme (dynamic for themes with light and dark variants).
    private(set) var palette: [ThemeColors.Role: Color] = [:]
    @ObservationIgnored let library = ThemeLibrary(directory: MacHelperPaths.supportDirectory.appending(path: "themes"))
    @ObservationIgnored let iconLibrary = IconPackLibrary(root: MacHelperPaths.supportDirectory.appending(path: "icons"))
    private(set) var iconPacks: [IconPack] = []
    /// Single icons the user replaced by hand.
    private(set) var iconOverrides: IconPack?
    @ObservationIgnored private var imageCache: [URL: NSImage] = [:]
    @ObservationIgnored var exportTemplateOnLaunch: URL?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(AppearanceSettings.self, from: data) {
            settings = saved
        } else {
            var fresh = AppearanceSettings()
            // An existing install (monitor settings already saved) keeps every page: start in advanced mode.
            if UserDefaults.standard.data(forKey: MonitorSettingsStore.key) != nil { fresh.mode = .advanced }
            settings = fresh
        }
        // Snapshot previews only (never saved): `--snapshot-symbols`, `--snapshot-preset standard|pixel`, `--snapshot-simple`.
        if CommandLine.arguments.contains("--snapshot-symbols") { settings.iconSet = .symbols }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-preset"), i + 1 < CommandLine.arguments.count {
            var fresh = AppearanceSettings()
            fresh.mode = .advanced
            if CommandLine.arguments[i + 1] == "pixel" { AppearancePreset.pixelRetro.apply(to: &fresh) }
            settings = fresh
        }
        if CommandLine.arguments.contains("--snapshot-simple") { settings.mode = .simple }
        // Debug aid: `--export-icon-template DIR` writes the template and quits (used to check the export).
        if let i = CommandLine.arguments.firstIndex(of: "--export-icon-template"), i + 1 < CommandLine.arguments.count {
            exportTemplateOnLaunch = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        customThemes = library.load()
        Self.registerFonts()
        loadIcons()
        rebuild()
    }

    // MARK: Themes

    var allThemes: [ThemeDefinition] { BuiltInThemes.all + customThemes }

    var theme: ThemeDefinition { allThemes.first { $0.id == settings.themeID } ?? BuiltInThemes.pixelNight }

    var isPixel: Bool { settings.style == .pixel }
    var isSimple: Bool { settings.mode == .simple }

    func color(_ role: ThemeColors.Role) -> Color { palette[role] ?? .primary }

    /// Saves (adds or replaces) a custom theme and selects it.
    func saveCustom(_ theme: ThemeDefinition, select: Bool = true) throws {
        var t = theme
        if t.origin == .builtIn { t.origin = .custom }
        try library.save(t)
        customThemes = library.load()
        if select { settings.themeID = t.id }
        rebuild()
    }

    func deleteCustom(_ id: String) throws {
        try library.delete(id: id)
        customThemes = library.load()
        if settings.themeID == id { settings.themeID = BuiltInThemes.defaultID }
        rebuild()
    }

    /// An editable copy of a theme (built-in themes can't be changed in place).
    func duplicate(_ theme: ThemeDefinition) throws -> ThemeDefinition {
        let ids = Set(allThemes.map(\.id))
        var copy = theme
        copy.id = ThemeLibrary.uniqueID("custom." + theme.id.split(separator: ".").last.map(String.init)!, existing: ids)
        copy.name = String(localized: "\(theme.displayName) Copy")
        copy.origin = .custom
        try saveCustom(copy)
        return copy
    }

    /// Imports a VS Code theme file as a new custom theme and selects it.
    func importVSCode(url: URL, name: String? = nil, uiTheme: String? = nil) throws -> ThemeDefinition {
        var t = try VSCodeTheme.load(url: url, name: name, uiTheme: uiTheme)
        t.id = ThemeLibrary.uniqueID(t.id, existing: Set(allThemes.map(\.id)))
        try saveCustom(t)
        return t
    }

    func reloadFromDisk() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(AppearanceSettings.self, from: data) { settings = saved }
        customThemes = library.load()
        rebuild()
    }

    // MARK: Icons

    enum ResolvedIcon {
        case asset(String)
        case image(NSImage, pixelated: Bool)
        case symbol(String, Color)
    }

    /// Which picture to draw for an icon id: a hand-replaced icon, then the chosen pack, then
    /// system symbols, then the built-in pixel art.
    func icon(_ id: String) -> ResolvedIcon {
        if let file = iconOverrides?.files[id], let img = image(file) {
            return .image(img, pixelated: Self.isPixelArt(img, file: file, declared: nil))
        }
        switch settings.iconSet {
        case .pack(let packID):
            if let pack = iconPacks.first(where: { $0.id == packID }), let file = pack.files[id], let img = image(file) {
                return .image(img, pixelated: Self.isPixelArt(img, file: file, declared: pack.pixelated))
            }
        case .symbols:
            if let entry = IconCatalog.entry(id) { return .symbol(entry.symbol, color(entry.tint)) }
        case .pixel:
            break
        }
        return .asset(IconCatalog.assetName(id) ?? "px.mascot")
    }

    func importIconPack(from folder: URL) throws -> IconPack {
        let pack = try iconLibrary.importPack(from: folder)
        loadIcons()
        settings.iconSet = .pack(pack.id)
        return pack
    }

    func deleteIconPack(_ id: String) throws {
        try iconLibrary.deletePack(id: id)
        if settings.iconSet == .pack(id) { settings.iconSet = .pixel }
        loadIcons()
    }

    func setIconOverride(_ id: String, from file: URL) throws {
        try iconLibrary.setOverride(id, from: file)
        loadIcons()
    }

    func removeIconOverride(_ id: String) throws {
        try iconLibrary.removeOverride(id)
        loadIcons()
    }

    /// Writes every icon as it looks now (PNG), a pack.json and a list of ids into `folder`, as a
    /// starting point for making a pack.
    func exportIconTemplate(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lines = ["MacHelper icon pack", "", "Name each image after the icon id below (PNG, PDF, SVG, JPEG, TIFF, HEIC or ICNS),",
                     "for example cpu.png. Missing icons fall back to the built-in pixel art.",
                     "pack.json: \"pixelated\": true draws small images without smoothing.", "", "Icons:"]
        for entry in IconCatalog.entries {
            lines.append("  \(entry.id)  –  \(entry.title)")
            guard let png = pngData(for: entry.id) else { continue }
            try png.write(to: folder.appending(path: "\(entry.id).png"))
        }
        let manifest = IconPackManifest(name: String(localized: "My Icons"), pixelated: settings.iconSet == .pixel)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appending(path: "pack.json"))
        try lines.joined(separator: "\n").write(to: folder.appending(path: "README.txt"), atomically: true, encoding: .utf8)
    }

    private func pngData(for id: String) -> Data? {
        let image: NSImage?
        var pixel = false
        switch icon(id) {
        case .image(let img, let pixelated): image = img; pixel = pixelated
        case .asset(let name):
            image = id == "app" ? NSApp.applicationIconImage : NSImage(named: name)
            pixel = id != "app"
        case .symbol(let name, _): image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
        guard let image else { return nil }
        // Pixel art is enlarged 8× without smoothing so every pixel stays a crisp square.
        let side = id == "app" ? 512 : (pixel ? 128 : 256)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        ctx?.imageInterpolation = pixel ? .none : .high
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func loadIcons() {
        imageCache = [:]
        iconPacks = iconLibrary.packs()
        iconOverrides = iconLibrary.overrides()
        applyDockIcon()
    }

    private func image(_ url: URL) -> NSImage? {
        if let cached = imageCache[url] { return cached }
        guard let img = NSImage(contentsOf: url) else { return nil }
        imageCache[url] = img
        return img
    }

    /// Small bitmaps are pixel art (drawn without smoothing) unless the pack says otherwise.
    private static func isPixelArt(_ img: NSImage, file: URL, declared: Bool?) -> Bool {
        if let declared { return declared }
        guard !["svg", "pdf"].contains(file.pathExtension.lowercased()) else { return false }
        let px = img.representations.map(\.pixelsWide).max() ?? 0
        return px > 0 && px <= 64
    }

    /// The Dock always gets an explicit image while MacHelper runs, so a cached old bundle icon
    /// never shows: the user's `app` image, or the chosen logo, framed like a system icon.
    private func applyDockIcon() {
        let dock = dockImage()
        if Thread.isMainThread {
            MainActor.assumeIsolated { NSApp?.applicationIconImage = dock }
        }
    }

    private func dockImage() -> NSImage? {
        if case .image(let img, _) = icon("app") { return Self.isFullBleed(img) ? Self.framed(img) : img }
        return Self.framedLogo(settings.appLogo)
    }

    /// The chosen logo as shown in the Dock (for the panel header and previews).
    var logoImage: NSImage { dockImage() ?? NSApp.applicationIconImage }

    @ObservationIgnored private nonisolated(unsafe) static var framedCache: [String: NSImage] = [:]

    /// A logo asset framed like a macOS app icon (cached per logo).
    static func framedLogo(_ id: String) -> NSImage? {
        if let cached = framedCache[id] { return cached }
        guard let art = NSImage(named: "logo." + id) else { return nil }
        let img = framed(art)
        framedCache[id] = img
        return img
    }

    /// Full-bleed square art inside the system icon shape: the rounded square covers 824 of 1024
    /// points, centered (Apple's icon grid), drawn without smoothing so pixel art stays crisp.
    static func framed(_ art: NSImage) -> NSImage {
        let side: CGFloat = 1024, inset: CGFloat = 100
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let rect = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
            NSGraphicsContext.current?.imageInterpolation = .none
            NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185).addClip()
            art.draw(in: rect)
            return true
        }
    }

    /// Opaque corners mean square art that still needs the icon shape.
    static func isFullBleed(_ img: NSImage) -> Bool {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        return [(0, 0), (15, 0), (0, 15), (15, 15)].allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.9 }
    }

    // MARK: Interface size

    /// One step of ⌘+ / ⌘-: 10 %, kept inside the allowed range.
    func zoom(by steps: Int) {
        let r = AppearanceSettings.textScaleRange
        let next = ((settings.textScale + Double(steps) * 0.1) * 20).rounded() / 20
        settings.textScale = min(max(next, r.lowerBound), r.upperBound)
    }

    // MARK: Fonts

    private var scale: CGFloat { CGFloat(settings.textScale) }

    /// Readable text (descriptions, lists, settings).
    func bodyFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let s = size * scale
        switch settings.bodyFont {
        case .system: return .system(size: s, weight: weight, design: design)
        case .family(let name):
            // Numbers keep the system monospaced face so columns stay aligned.
            if design == .monospaced { return .system(size: s, weight: weight, design: .monospaced) }
            return .custom(name, fixedSize: s).weight(weight)
        }
    }

    /// Titles, headings and big numbers.
    func displayFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        let s = size * scale
        switch settings.displayFont {
        case .pixel: return .custom(Self.pixelFontName, fixedSize: PixelFontMetrics.snapped(s))
        case .system: return .system(size: s, weight: weight)
        case .rounded: return .system(size: s, weight: weight, design: .rounded)
        case .monospaced: return .system(size: s, weight: weight, design: .monospaced)
        case .family(let name): return .custom(name, fixedSize: s).weight(weight)
        }
    }

    /// Menu bar text: fixed sizes (the menu bar is 22 pt tall). Rounded by default: the most legible
    /// face at this size; fixed-width digits keep the item from changing width.
    func menuBarFont(size: CGFloat) -> Font {
        switch settings.menuBarFont {
        case .rounded: .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
        case .system: .system(size: size, weight: .medium).monospacedDigit()
        case .pixel: .custom(Self.pixelFontName, fixedSize: 11)
        }
    }

    /// A level color softened toward the menu bar's text color (white on a dark menu bar), so a
    /// value that needs attention is hinted at without shouting.
    static func menuBarTint(_ level: StatusLevel) -> Color {
        let base: NSColor = switch level {
        case .good: .labelColor
        case .attention: .systemYellow
        case .critical: .systemRed
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return base.blended(withFraction: dark ? 0.55 : 0.35, of: dark ? .white : .black) ?? base
        })
    }

    static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "Cubic_11", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// Installed font families for the font pickers.
    static var availableFamilies: [String] { NSFontManager.shared.availableFontFamilies.sorted() }

    // MARK: Private

    private func save() {
        guard persists else { return }
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
    }

    private func rebuild() {
        let t = theme
        let light = t.colors, dark = t.dark
        var p: [ThemeColors.Role: Color] = [:]
        for role in ThemeColors.Role.allCases {
            let l = light[role], d = dark?[role]
            p[role] = Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return (isDark ? (d ?? l) : l).nsColor
            })
        }
        palette = p
        applyDockIcon()
        let appearance: NSAppearance? = t.followsSystemAppearance ? nil : NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        if Thread.isMainThread {
            MainActor.assumeIsolated { NSApp?.appearance = appearance }
        } else {
            DispatchQueue.main.async { NSApp?.appearance = appearance }
        }
    }
}

extension ThemeDefinition {
    /// Built-in names are translated; imported and custom names are shown as written.
    var displayName: String {
        switch id {
        case BuiltInThemes.instrument.id: String(localized: "Instrument")
        case BuiltInThemes.pixelNight.id: String(localized: "Pixel Night")
        case BuiltInThemes.pixelDay.id: String(localized: "Pixel Day")
        case BuiltInThemes.classic.id: String(localized: "Classic")
        default: name
        }
    }
}

extension HexColor {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(nsColor: nsColor) }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }
}

// MARK: - Fonts used by views

extension Font {
    /// Drop-in for `.system(size:weight:design:)` that follows the body font and text size settings.
    static func mh(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        ThemeStore.shared.bodyFont(size: size, weight: weight, design: design)
    }

    /// Display face (pixel font by default) for titles and big numbers.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        ThemeStore.shared.displayFont(size: size, weight: weight)
    }

    // macOS text styles, scaled.
    static var mhLargeTitle: Font { .mh(size: 26) }
    static var mhTitle: Font { .mh(size: 22) }
    static var mhTitle2: Font { .mh(size: 17) }
    static var mhTitle3: Font { .mh(size: 15) }
    static var mhHeadline: Font { .mh(size: 13, weight: .bold) }
    static var mhBody: Font { .mh(size: 13) }
    static var mhCallout: Font { .mh(size: 12) }
    static var mhSubheadline: Font { .mh(size: 11) }
    static var mhFootnote: Font { .mh(size: 10) }
    static var mhCaption: Font { .mh(size: 10) }
    static var mhCaption2: Font { .mh(size: 10) }
}

// MARK: - Shapes

/// The one surface shape: notched "pixel" corners in the pixel style, rounded corners otherwise.
/// Stands in for `RoundedRectangle` and `Capsule` everywhere.
struct SurfaceShape: InsettableShape {
    var cornerRadius: CGFloat
    var capsule = false
    var pixel = ThemeStore.shared.isPixel
    private var insetAmount: CGFloat = 0

    init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        self.cornerRadius = cornerRadius
    }

    init(capsule: Bool) {
        cornerRadius = 0
        self.capsule = capsule
    }

    static var capsule: SurfaceShape { SurfaceShape(capsule: true) }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }
        if pixel { return PixelShape.path(in: r, steps: (capsule || cornerRadius >= 6) ? 2 : (cornerRadius > 0 ? 1 : 0)) }
        if capsule { return Capsule(style: .continuous).path(in: r) }
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> SurfaceShape {
        var s = self
        s.insetAmount += amount
        return s
    }
}

enum PixelShape {
    /// Unit of the stair-step corners.
    static let unit: CGFloat = 2

    /// A rectangle with `steps` pixel blocks cut from each corner (0 = square, 1 = one block, 2 = a
    /// two-step stair like a pixel-art rounded corner).
    static func path(in r: CGRect, steps: Int) -> Path {
        let u = min(unit, min(r.width, r.height) / 6)
        var p = Path()
        guard steps > 0, u > 0.5 else { p.addRect(r); return p }
        // Corner outline from the edge inwards, as offsets (x, y) for the top-left corner.
        let stair: [(CGFloat, CGFloat)] = steps == 1 ? [(0, u), (u, u), (u, 0)] : [(0, 2 * u), (u, 2 * u), (u, u), (2 * u, u), (2 * u, 0)]
        func corner(_ origin: CGPoint, _ sx: CGFloat, _ sy: CGFloat, reversed: Bool) {
            let pts = reversed ? stair.reversed() : stair
            for (dx, dy) in pts {
                let pt = CGPoint(x: origin.x + sx * dx, y: origin.y + sy * dy)
                if p.isEmpty { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
        corner(CGPoint(x: r.minX, y: r.minY), 1, 1, reversed: false)    // top-left: left edge → top edge
        corner(CGPoint(x: r.maxX, y: r.minY), -1, 1, reversed: true)    // top-right: top edge → right edge
        corner(CGPoint(x: r.maxX, y: r.maxY), -1, -1, reversed: false)  // bottom-right: right edge → bottom edge
        corner(CGPoint(x: r.minX, y: r.maxY), 1, -1, reversed: true)    // bottom-left: bottom edge → left edge
        p.closeSubpath()
        return p
    }
}
