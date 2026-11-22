import Foundation

// MARK: - Settings

/// How surfaces are drawn. Every material keeps theme ink on theme surfaces; they differ only in
/// how much of the desktop shows through behind the panel and its cards.
public enum SurfaceMaterial: String, Codable, Sendable, CaseIterable {
    /// Opaque theme surfaces everywhere: the highest legibility, the classic instrument look.
    case solid
    /// A slightly translucent panel behind opaque cards: the desktop is hinted at, numbers stay crisp.
    case frosted
    /// macOS 26 Liquid Glass panes over a strong, appearance-aware scrim. Falls back to `frosted`
    /// where glass isn't drawn (older systems, the pixel style, Increase Contrast).
    case liquidGlass

    public static let `default`: SurfaceMaterial = .frosted

    /// What is actually drawn: Reduce Transparency and the soft (neumorphic) style always win
    /// (solid, because translucency washes out dual shadows); Liquid Glass needs macOS 26, the
    /// smooth style and no Increase Contrast, and otherwise becomes frosted.
    public func effective(glassSupported: Bool, isPixel: Bool, isSoft: Bool = false, reduceTransparency: Bool, increaseContrast: Bool) -> SurfaceMaterial {
        if reduceTransparency || isSoft { return .solid }
        switch self {
        case .solid: return .solid
        case .frosted: return .frosted
        case .liquidGlass: return glassSupported && !isPixel && !increaseContrast ? .liquidGlass : .frosted
        }
    }

    public var isTranslucent: Bool { self != .solid }
}

/// Light or dark, for themes that have both variants. Single-variant themes keep their own polarity.
public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case system, light, dark
}

extension ThemeDefinition {
    /// The appearance the app must force for this theme: the theme's own polarity for a
    /// single-variant theme, the user's choice for an adaptive one, nil to follow the system.
    public func forcedDarkAppearance(mode: AppearanceMode) -> Bool? {
        guard followsSystemAppearance else { return isDark }
        switch mode {
        case .system: return nil
        case .light: return false
        case .dark: return true
        }
    }

    /// Whether the interface is dark for this theme, mode and system appearance.
    public func resolvesDark(mode: AppearanceMode, systemIsDark: Bool) -> Bool {
        forcedDarkAppearance(mode: mode) ?? systemIsDark
    }
}

// MARK: - Color math

extension HexColor {
    /// Source-over compositing of this (possibly translucent) color onto `background`.
    public func composited(over background: HexColor) -> HexColor {
        let a = alpha, b = background.alpha * (1 - a), out = a + b
        guard out > 0 else { return HexColor(red: 0, green: 0, blue: 0, alpha: 0) }
        return HexColor(red: (red * a + background.red * b) / out, green: (green * a + background.green * b) / out,
                        blue: (blue * a + background.blue * b) / out, alpha: out)
    }

    /// This color, moved toward black or white (whichever contrasts more with the backgrounds)
    /// just far enough to reach `ratio` against every one of them. Unchanged when it already does.
    public func ensuringContrast(_ ratio: Double, against backgrounds: [HexColor]) -> HexColor {
        func worst(_ c: HexColor) -> Double { backgrounds.map { c.contrast(with: $0) }.min() ?? 21 }
        let opaque = withAlpha(1)
        guard worst(opaque) < ratio else { return opaque }
        let black = HexColor(0x000000), white = HexColor(0xFFFFFF)
        let target = worst(black) >= worst(white) ? black : white
        var best = opaque
        for step in 1...20 {
            let c = opaque.mixed(with: target, Double(step) / 20)
            best = c
            if worst(c) >= ratio { break }
        }
        return best
    }

    public func ensuringContrast(_ ratio: Double, against background: HexColor) -> HexColor {
        ensuringContrast(ratio, against: [background])
    }
}

extension ThemeColors {
    /// Text roles nudged just enough to stay readable on cards and the page background (imported
    /// and custom themes can be low-contrast). Built-in themes already pass and come back unchanged.
    public func readable() -> ThemeColors {
        var c = self
        let surfaces = [card.withAlpha(1), base.withAlpha(1)]
        c.text = text.ensuringContrast(7, against: surfaces)
        c.textMuted = textMuted.ensuringContrast(4.5, against: surfaces)
        c.textFaint = textFaint.ensuringContrast(3, against: surfaces)
        return c
    }
}

// MARK: - Semantic surface tokens

/// Colors for controls, charts and translucent surfaces, derived from a theme variant so every
/// theme (built-in, custom or imported) gets readable selections and glass. Light variants get
/// bright scrims and dark ink; dark variants get deep scrims, light ink and luminous rims.
public struct SurfaceTokens: Sendable, Hashable {
    public enum Role: String, CaseIterable, Sendable {
        case selectionTrack, selectionTrackText, selectionFill, selectionBorder, selectionText
        case controlFill, controlBorder, controlText
        case chartAxisText, chartGridLine
        case glassPanelScrim, glassCardTint, glassCardBorder, glassShadow, glassControlTint, glassSelectionTint
        case frostedPanelScrim, panelCardFill, cardShadow
        case softHighlight, softShadow, softWell
    }

    public var isDark: Bool
    /// Recessed track behind tab strips and chip bars.
    public var selectionTrack: HexColor
    /// Labels of the unselected items on the track (and of chips beside it).
    public var selectionTrackText: HexColor
    /// The raised pill under the selected tab or chip (opaque).
    public var selectionFill: HexColor
    public var selectionBorder: HexColor
    public var selectionText: HexColor
    /// Secondary buttons: header icon buttons, the Quit capsule (opaque).
    public var controlFill: HexColor
    public var controlBorder: HexColor
    public var controlText: HexColor
    public var chartAxisText: HexColor
    public var chartGridLine: HexColor
    /// Wash over the popover's own material when Liquid Glass is on.
    public var glassPanelScrim: HexColor
    /// Tint of a Liquid Glass card.
    public var glassCardTint: HexColor
    /// Rim of a glass card: a luminous edge in dark, a fine ink line in light.
    public var glassCardBorder: HexColor
    public var glassShadow: HexColor
    /// Tint of glass controls (icon buttons, Quit) so their glyphs stay readable.
    public var glassControlTint: HexColor
    /// Tint of the glass selection pill.
    public var glassSelectionTint: HexColor
    /// Wash over the popover's material in the frosted look.
    public var frostedPanelScrim: HexColor
    /// Opaque card on a translucent panel: raised above it in light and dark alike.
    public var panelCardFill: HexColor
    /// Soft shadow under opaque cards on a translucent panel.
    public var cardShadow: HexColor
    /// Top-left light highlight for neumorphic (soft) extruded and recessed surfaces.
    public var softHighlight: HexColor
    /// Bottom-right cast shadow for neumorphic (soft) extruded and recessed surfaces.
    public var softShadow: HexColor
    /// Subtle interior tint for recessed neumorphic wells, tracks and channels.
    public var softWell: HexColor

    /// Worst-case backdrops a translucent surface may sit on: a white and a black wallpaper.
    public static let worstCaseBackdrops = [HexColor(0xFFFFFF), HexColor(0x000000)]

    public init(deriving c: ThemeColors) {
        let dark = c.base.isDark
        isDark = dark
        let ink = c.text.withAlpha(1)
        let card = c.card.withAlpha(1), base = c.base.withAlpha(1)
        let white = HexColor(0xFFFFFF), black = HexColor(0x000000)

        let fill = dark ? c.raised.withAlpha(1).mixed(with: ink, 0.12) : c.raised.withAlpha(1).mixed(with: white, 0.6)
        selectionFill = fill
        // The track is the theme's inset, deepened toward the ink only when the pill would
        // otherwise melt into it (very pale or very flat themes).
        var track = c.inset.withAlpha(1)
        for step in 1...10 where fill.contrast(with: track) < 1.2 {
            track = c.inset.withAlpha(1).mixed(with: dark ? black : ink, Double(step) * 0.03)
        }
        selectionTrack = track
        selectionTrackText = c.textMuted.ensuringContrast(4.5, against: [track, card])
        selectionBorder = dark ? white.withAlpha(0.16) : ink.withAlpha(0.16)
        selectionText = ink.ensuringContrast(7, against: selectionFill)

        controlFill = dark ? c.inset.withAlpha(1).mixed(with: ink, 0.06) : c.raised.withAlpha(1).mixed(with: c.inset.withAlpha(1), 0.45)
        controlBorder = dark ? white.withAlpha(0.12) : ink.withAlpha(0.14)
        controlText = c.textMuted.ensuringContrast(4.5, against: [controlFill, card])

        chartAxisText = c.textMuted.ensuringContrast(4.5, against: [card, base])
        chartGridLine = ink.withAlpha(dark ? 0.16 : 0.13)

        // Scrims: the lightest wash at which body and secondary text still pass over a white and
        // a black wallpaper. Built-in themes land on the floor; low-contrast themes get more.
        let panelFill = dark ? base : card
        glassPanelScrim = panelFill.withAlpha(Self.opacity(for: panelFill, floor: 0.88, inks: [(ink, 7), (c.textMuted, 4.5)]))
        frostedPanelScrim = panelFill.withAlpha(Self.opacity(for: panelFill, floor: 0.92, inks: [(ink, 7), (c.textMuted, 4.5)]))
        let cardFill = dark ? card : c.raised.withAlpha(1)
        panelCardFill = cardFill
        glassCardTint = cardFill.withAlpha(Self.opacity(for: cardFill, floor: dark ? 0.86 : 0.84, under: glassPanelScrim,
                                                         inks: [(ink, 7), (c.textMuted, 4.5), (c.textFaint, 4.5)]))
        glassCardBorder = dark ? white.withAlpha(0.14) : ink.withAlpha(0.10)
        glassShadow = black.withAlpha(dark ? 0.40 : 0.10)
        cardShadow = black.withAlpha(dark ? 0.30 : 0.07)
        glassControlTint = controlFill.withAlpha(Self.opacity(for: controlFill, floor: dark ? 0.82 : 0.78, inks: [(controlText, 4.5)]))
        glassSelectionTint = selectionFill.withAlpha(Self.opacity(for: selectionFill, floor: 0.92, inks: [(selectionText, 7)]))

        // Neumorphic light and shadow derived from `base` so custom and imported themes work in
        // soft style too: bright top-left light and cool-tinted bottom-right shadow in light,
        // subtle lifted rim and deep shadow in dark.
        softHighlight = dark ? base.mixed(with: white, 0.24).withAlpha(0.60) : base.mixed(with: white, 0.90).withAlpha(0.92)
        softShadow = dark ? black.withAlpha(0.62) : base.mixed(with: ink, 0.36).withAlpha(0.46)
        softWell = dark ? base.mixed(with: black, 0.16) : base.mixed(with: ink, 0.045)
    }

    /// The smallest opacity (from `floor`, in 2 % steps) at which `fill` — composited over
    /// `under` and then each worst-case backdrop — keeps every ink at its minimum ratio.
    static func opacity(for fill: HexColor, floor: Double, under: HexColor? = nil, inks: [(HexColor, Double)]) -> Double {
        var a = floor
        while a < 1 {
            let ok = worstCaseBackdrops.allSatisfy { wall in
                let backdrop = under.map { $0.composited(over: wall) } ?? wall
                let surface = fill.withAlpha(a).composited(over: backdrop)
                return inks.allSatisfy { $0.0.withAlpha(1).contrast(with: surface) >= $0.1 }
            }
            if ok { return a }
            a = min(a + 0.02, 1)
        }
        return 1
    }

    public subscript(role: Role) -> HexColor {
        switch role {
        case .selectionTrack: selectionTrack
        case .selectionTrackText: selectionTrackText
        case .selectionFill: selectionFill
        case .selectionBorder: selectionBorder
        case .selectionText: selectionText
        case .controlFill: controlFill
        case .controlBorder: controlBorder
        case .controlText: controlText
        case .chartAxisText: chartAxisText
        case .chartGridLine: chartGridLine
        case .glassPanelScrim: glassPanelScrim
        case .glassCardTint: glassCardTint
        case .glassCardBorder: glassCardBorder
        case .glassShadow: glassShadow
        case .glassControlTint: glassControlTint
        case .glassSelectionTint: glassSelectionTint
        case .frostedPanelScrim: frostedPanelScrim
        case .panelCardFill: panelCardFill
        case .cardShadow: cardShadow
        case .softHighlight: softHighlight
        case .softShadow: softShadow
        case .softWell: softWell
        }
    }
}

// MARK: - Resolution

/// A theme resolved for one appearance: the variant in use, its readable colors and its surface tokens.
public struct ResolvedTheme: Sendable, Hashable {
    public let theme: ThemeDefinition
    public let isDark: Bool
    public let colors: ThemeColors
    public let surfaces: SurfaceTokens

    public init(theme: ThemeDefinition, mode: AppearanceMode, systemIsDark: Bool) {
        let dark = theme.resolvesDark(mode: mode, systemIsDark: systemIsDark)
        self.init(theme: theme, variantDark: dark)
    }

    /// One specific variant (`dark` is ignored for single-variant themes).
    public init(theme: ThemeDefinition, variantDark: Bool) {
        self.theme = theme
        let colors = theme.colors(dark: variantDark).readable()
        self.colors = colors
        isDark = theme.followsSystemAppearance ? variantDark : theme.isDark
        surfaces = SurfaceTokens(deriving: colors)
    }

    /// Every variant of a theme (one or two).
    public static func variants(of theme: ThemeDefinition) -> [ResolvedTheme] {
        theme.followsSystemAppearance
            ? [ResolvedTheme(theme: theme, variantDark: false), ResolvedTheme(theme: theme, variantDark: true)]
            : [ResolvedTheme(theme: theme, variantDark: theme.isDark)]
    }
}

// MARK: - Contrast audit

/// WCAG contrast checks for one resolved theme: ink on every surface it is drawn on, in each
/// material, with translucent surfaces composited over a white and a black wallpaper.
public struct ThemeContrastAudit: Sendable {
    public struct Check: Sendable, CustomStringConvertible {
        public let name: String
        public let foreground: HexColor
        public let background: HexColor
        public let minimum: Double
        public var ratio: Double { foreground.contrast(with: background) }
        public var passes: Bool { ratio >= minimum }
        public var description: String { "\(name): \(foreground.hex) on \(background.hex) = \(String(format: "%.2f", ratio)) (min \(minimum))" }
    }

    public let checks: [Check]

    public var failures: [Check] { checks.filter { !$0.passes } }
    public var passes: Bool { failures.isEmpty }
    /// The lowest ratio of body text on any surface (for a quick rating).
    public var bodyTextMinimum: Double { checks.filter { $0.name.hasSuffix("text") }.map(\.ratio).min() ?? 21 }

    public init(_ r: ResolvedTheme) {
        let c = r.colors, s = r.surfaces
        let card = c.card.withAlpha(1), base = c.base.withAlpha(1)
        var out: [Check] = []
        func add(_ name: String, _ fg: HexColor, _ bg: HexColor, _ min: Double) {
            out.append(Check(name: name, foreground: fg.withAlpha(1), background: bg.withAlpha(1), minimum: min))
        }
        // Solid surfaces.
        for (surface, bg) in [("card", card), ("base", base)] {
            add("solid \(surface) text", c.text, bg, 7)
            add("solid \(surface) muted", c.textMuted, bg, 4.5)
            add("solid \(surface) chart axis", s.chartAxisText, bg, 4.5)
        }
        add("solid card faint", c.textFaint, card, 3)
        add("frosted card text", c.text, s.panelCardFill, 7)
        add("frosted card muted", c.textMuted, s.panelCardFill, 4.5)
        add("frosted card chart axis", s.chartAxisText, s.panelCardFill, 4.5)
        add("selection track text", s.selectionTrackText, s.selectionTrack, 4.5)
        add("selection text", s.selectionText, s.selectionFill, 7)
        add("control text", s.controlText, s.controlFill, 4.5)
        // Translucent surfaces over the worst wallpapers.
        for wall in SurfaceTokens.worstCaseBackdrops {
            let w = wall.luminance > 0.5 ? "white" : "black"
            let glassPanel = s.glassPanelScrim.composited(over: wall)
            let glassCard = s.glassCardTint.composited(over: glassPanel)
            let frostedPanel = s.frostedPanelScrim.composited(over: wall)
            add("glass panel/\(w) text", c.text, glassPanel, 7)
            add("glass panel/\(w) muted", c.textMuted, glassPanel, 4.5)
            add("glass card/\(w) text", c.text, glassCard, 7)
            add("glass card/\(w) muted", c.textMuted, glassCard, 4.5)
            add("glass card/\(w) faint", c.textFaint, glassCard, 3)
            add("glass card/\(w) chart axis", s.chartAxisText, glassCard, 4.5)
            add("glass selection/\(w) text", s.selectionText, s.glassSelectionTint.composited(over: glassPanel), 7)
            add("glass control/\(w) text", s.controlText, s.glassControlTint.composited(over: glassPanel), 4.5)
            add("frosted panel/\(w) text", c.text, frostedPanel, 7)
            add("frosted panel/\(w) muted", c.textMuted, frostedPanel, 4.5)
        }
        checks = out
    }
}
