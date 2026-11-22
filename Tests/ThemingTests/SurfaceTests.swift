import Foundation
import Testing
@testable import Theming

@Suite struct SurfaceSettingsTests {
    @Test func defaultsAreLegible() {
        let s = AppearanceSettings()
        #expect(s.surfaceMaterial == .frosted)
        #expect(s.appearanceMode == .system)
        #expect(AppearancePreset.matching(s) == .standard, "the new fields don't break the default preset")
    }

    @Test func legacyJSONWithoutNewKeysDecodes() throws {
        // Settings saved by 0.4.0 and earlier: no surfaceMaterial or appearanceMode.
        let legacy = ##"""
        {"mode":"advanced","themeID":"builtin.pixel-night","style":"smooth","displayFont":{"rounded":{}},
         "bodyFont":{"system":{}},"textScale":1.1,"iconSet":{"pixel":{}},"appLogo":"slime",
         "menuBarFont":"rounded","menuBarLabel":"icon","menuBarColored":true}
        """##
        let s = try JSONDecoder().decode(AppearanceSettings.self, from: Data(legacy.utf8))
        #expect(s.themeID == BuiltInThemes.pixelNight.id && s.mode == .advanced && s.appLogo == "slime")
        #expect(s.menuBarLabel == .icon && s.menuBarColored && abs(s.textScale - 1.1) < 0.0001)
        #expect(s.surfaceMaterial == .default && s.appearanceMode == .system)
        // Empty and garbage values fall back too.
        let empty = try JSONDecoder().decode(AppearanceSettings.self, from: Data("{}".utf8))
        #expect(empty == AppearanceSettings())
        let bogus = try JSONDecoder().decode(AppearanceSettings.self,
                                             from: Data(##"{"surfaceMaterial":"plasma","appearanceMode":7}"##.utf8))
        #expect(bogus.surfaceMaterial == .default && bogus.appearanceMode == .system)
    }

    @Test func newFieldsRoundTrip() throws {
        for material in SurfaceMaterial.allCases {
            for mode in AppearanceMode.allCases {
                var s = AppearanceSettings()
                s.surfaceMaterial = material
                s.appearanceMode = mode
                #expect(try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(s)) == s)
            }
        }
    }

    @Test func effectiveMaterialFallsBack() {
        let glass = SurfaceMaterial.liquidGlass
        #expect(glass.effective(glassSupported: true, isPixel: false, reduceTransparency: false, increaseContrast: false) == .liquidGlass)
        #expect(glass.effective(glassSupported: false, isPixel: false, reduceTransparency: false, increaseContrast: false) == .frosted,
                "older macOS: frosted")
        #expect(glass.effective(glassSupported: true, isPixel: true, reduceTransparency: false, increaseContrast: false) == .frosted,
                "pixel style keeps flat blocks")
        #expect(glass.effective(glassSupported: true, isPixel: false, reduceTransparency: false, increaseContrast: true) == .frosted)
        for m in SurfaceMaterial.allCases {
            #expect(m.effective(glassSupported: true, isPixel: false, reduceTransparency: true, increaseContrast: false) == .solid,
                    "Reduce Transparency always wins")
        }
        #expect(SurfaceMaterial.solid.effective(glassSupported: true, isPixel: false, reduceTransparency: false, increaseContrast: false) == .solid)
        #expect(SurfaceMaterial.frosted.effective(glassSupported: true, isPixel: true, reduceTransparency: false, increaseContrast: true) == .frosted)
    }
}

@Suite struct ThemeResolutionTests {
    @Test func singleVariantThemesKeepTheirPolarity() {
        for mode in AppearanceMode.allCases {
            for system in [false, true] {
                let night = ResolvedTheme(theme: BuiltInThemes.pixelNight, mode: mode, systemIsDark: system)
                #expect(night.isDark && night.surfaces.isDark, "Pixel Night is dark in \(mode), system dark \(system)")
                #expect(night.colors.text == BuiltInThemes.pixelNight.colors.text)
                let day = ResolvedTheme(theme: BuiltInThemes.pixelDay, mode: mode, systemIsDark: system)
                #expect(!day.isDark && !day.surfaces.isDark)
            }
            #expect(BuiltInThemes.pixelNight.forcedDarkAppearance(mode: mode) == true)
            #expect(BuiltInThemes.pixelDay.forcedDarkAppearance(mode: mode) == false)
        }
    }

    @Test func adaptiveThemesFollowTheMode() {
        let t = BuiltInThemes.instrument
        #expect(t.forcedDarkAppearance(mode: .system) == nil)
        #expect(t.forcedDarkAppearance(mode: .light) == false)
        #expect(t.forcedDarkAppearance(mode: .dark) == true)
        #expect(ResolvedTheme(theme: t, mode: .system, systemIsDark: true).isDark)
        #expect(!ResolvedTheme(theme: t, mode: .system, systemIsDark: false).isDark)
        #expect(!ResolvedTheme(theme: t, mode: .light, systemIsDark: true).isDark)
        #expect(ResolvedTheme(theme: t, mode: .dark, systemIsDark: false).isDark)
        #expect(ResolvedTheme(theme: t, mode: .dark, systemIsDark: false).colors.card == t.dark?.card)
        #expect(ResolvedTheme(theme: t, mode: .light, systemIsDark: true).colors.card == t.colors.card)
        #expect(ResolvedTheme.variants(of: t).count == 2 && ResolvedTheme.variants(of: BuiltInThemes.pixelNight).count == 1)
    }
}

@Suite struct ContrastAuditTests {
    /// Every built-in variant passes every check: solid, frosted and glass surfaces, over a white
    /// and a black wallpaper.
    @Test func builtInThemesPassEverywhere() {
        for theme in BuiltInThemes.all {
            for r in ResolvedTheme.variants(of: theme) {
                let audit = ThemeContrastAudit(r)
                #expect(audit.passes, "\(theme.name) \(r.isDark ? "dark" : "light"): \(audit.failures)")
                #expect(audit.checks.count > 20)
            }
        }
    }

    /// Stricter goals for our own themes than the audit's floor: faint labels (peaks, axis
    /// captions, column headers) stay at AA on every card, and selections are distinct.
    @Test func builtInThemesMeetStrictGoals() {
        for theme in BuiltInThemes.all {
            for r in ResolvedTheme.variants(of: theme) {
                let c = r.colors, s = r.surfaces, name = "\(theme.name) \(r.isDark ? "dark" : "light")"
                #expect(c.textFaint.contrast(with: c.card) >= 4.5, "\(name) faint/card")
                #expect(c.textFaint.contrast(with: c.base) >= 4.5, "\(name) faint/base")
                #expect(s.chartAxisText.contrast(with: c.card) >= 4.5 && s.chartAxisText.contrast(with: c.base) >= 4.5, "\(name) axis")
                #expect(s.selectionText.contrast(with: s.selectionFill) >= 7, "\(name) selection")
                #expect(s.selectionFill.contrast(with: s.selectionTrack) >= 1.15, "\(name) pill stands off its track")
                #expect(s.controlText.contrast(with: s.controlFill) >= 4.5, "\(name) control")
                for wall in SurfaceTokens.worstCaseBackdrops {
                    let card = s.glassCardTint.composited(over: s.glassPanelScrim.composited(over: wall))
                    #expect(c.textFaint.contrast(with: card) >= 4.5, "\(name) faint on glass card over \(wall.hex)")
                }
                // Built-ins are already readable: the safety net changes nothing.
                #expect(c == theme.colors(dark: r.isDark), "\(name) readable() is a no-op")
            }
        }
    }

    @Test func polarityOfTokens() {
        for theme in BuiltInThemes.all {
            for r in ResolvedTheme.variants(of: theme) {
                let s = r.surfaces
                // Light scrims are bright and carry dark ink; dark scrims are deep and carry light ink.
                #expect(s.glassPanelScrim.isDark == r.isDark && s.glassCardTint.isDark == r.isDark, "\(theme.name)")
                #expect(s.selectionText.isDark != r.isDark && s.selectionFill.isDark == r.isDark, "\(theme.name)")
                #expect(s.glassPanelScrim.alpha >= 0.88 && s.glassCardTint.alpha >= 0.84)
                #expect(s.glassShadow.alpha > (r.isDark ? 0.3 : 0.05))
            }
        }
    }

    /// Deliberately washed-out imported themes (a dark one with dim grey text, a light one with
    /// pale text) still get readable text, selections and scrims everywhere.
    @Test func lowContrastThemesAreRescued() {
        func poor(base: UInt32, card: UInt32, inset: UInt32, raised: UInt32, text: UInt32, muted: UInt32, faint: UInt32) -> ThemeDefinition {
            let g = HexColor(0x808080)
            let c = ThemeColors(base: HexColor(base), card: HexColor(card), inset: HexColor(inset), raised: HexColor(raised),
                                stroke: g, hairline: g, text: HexColor(text), textMuted: HexColor(muted), textFaint: HexColor(faint),
                                accent: g, blue: g, cyan: g, mint: g, amber: g, rose: g, violet: g, orange: g, slate: g)
            return ThemeDefinition(id: "custom.poor", name: "Poor", origin: .vscode, colors: c)
        }
        let dim = poor(base: 0x1E1E1E, card: 0x252526, inset: 0x2D2D2D, raised: 0x333334, text: 0x6A6A6A, muted: 0x4A4A4A, faint: 0x3A3A3A)
        let pale = poor(base: 0xF3F3F3, card: 0xFFFFFF, inset: 0xF0F0F0, raised: 0xFFFFFF, text: 0xB0B0B0, muted: 0xC8C8C8, faint: 0xDDDDDD)
        for theme in [dim, pale] {
            let r = ResolvedTheme(theme: theme, mode: .system, systemIsDark: false)
            #expect(r.isDark == theme.isDark)
            let audit = ThemeContrastAudit(r)
            #expect(audit.passes, "\(audit.failures)")
        }
    }

    @Test func colorMath() {
        let white = HexColor(0xFFFFFF), black = HexColor(0x000000)
        #expect(black.withAlpha(0.5).composited(over: white).hex == "#808080")
        #expect(white.withAlpha(1).composited(over: black) == white)
        #expect(HexColor(0x777777).ensuringContrast(4.5, against: white).contrast(with: white) >= 4.5)
        #expect(HexColor(0x777777).ensuringContrast(4.5, against: black).contrast(with: black) >= 4.5)
        let fine = HexColor(0x111111)
        #expect(fine.ensuringContrast(4.5, against: white) == fine, "already readable: unchanged")
    }
}
