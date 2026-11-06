import Foundation
import Testing
@testable import Theming

@Suite struct HexColorTests {
    @Test func parsesAllForms() throws {
        #expect(HexColor(hex: "#FF0000")?.hex == "#FF0000")
        #expect(HexColor(hex: "00ff00")?.hex == "#00FF00")
        #expect(HexColor(hex: "#F00")?.hex == "#FF0000")
        #expect(HexColor(hex: "#F008")?.hex == "#FF000088")
        #expect(HexColor(hex: "#11223380")?.alpha == Double(0x80) / 255)
        for bad in ["", "#12", "#12345", "#GGGGGG", "red", "#1234567"] { #expect(HexColor(hex: bad) == nil, "\(bad)") }
    }

    @Test func luminanceAndContrast() {
        let black = HexColor(0x000000), white = HexColor(0xFFFFFF)
        #expect(black.isDark && !white.isDark)
        #expect(abs(black.contrast(with: white) - 21) < 0.01)
        #expect(black.mixed(with: white, 0.5).hex == "#808080")
    }

    @Test func codableAsHexString() throws {
        let data = try JSONEncoder().encode([HexColor(0x123456, alpha: 0.5)])
        #expect(String(decoding: data, as: UTF8.self) == "[\"#12345680\"]")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([HexColor].self, from: Data("[\"nope\"]".utf8)) }
    }
}

@Suite struct BuiltInThemeTests {
    @Test func defaultsAndReadability() {
        #expect(BuiltInThemes.defaultID == "builtin.instrument")
        #expect(Set(BuiltInThemes.all.map(\.id)).count == BuiltInThemes.all.count)
        for t in BuiltInThemes.all {
            for c in [t.colors] + (t.dark.map { [$0] } ?? []) {
                #expect(c.text.contrast(with: c.card) >= 7, "\(t.name) text")
                #expect(c.textMuted.contrast(with: c.card) >= 4.5, "\(t.name) muted")
                #expect(c.textFaint.contrast(with: c.card) >= 3, "\(t.name) faint")
                for role in [ThemeColors.Role.blue, .mint, .amber, .rose, .orange] {
                    #expect(c[role].contrast(with: c.card) >= 2.5, "\(t.name) \(role)")
                }
            }
        }
        #expect(BuiltInThemes.classic.followsSystemAppearance && BuiltInThemes.instrument.followsSystemAppearance)
        // No violet or lavender in our own themes (hue 250–300°, noticeably saturated).
        for t in BuiltInThemes.all where t.id != BuiltInThemes.classic.id {
            for c in [t.colors] + (t.dark.map { [$0] } ?? []) {
                for role in ThemeColors.Role.allCases {
                    let h = c[role], mx = max(h.red, h.green, h.blue), mn = min(h.red, h.green, h.blue)
                    guard mx - mn > 0.12 else { continue }
                    var hue: Double
                    if mx == h.red { hue = 60 * ((h.green - h.blue) / (mx - mn)) }
                    else if mx == h.green { hue = 60 * ((h.blue - h.red) / (mx - mn) + 2) }
                    else { hue = 60 * ((h.red - h.green) / (mx - mn) + 4) }
                    if hue < 0 { hue += 360 }
                    #expect(!(250...300).contains(hue), "\(t.name) \(role) is violet (\(h.hex))")
                }
            }
        }
        #expect(BuiltInThemes.pixelNight.isDark && !BuiltInThemes.pixelDay.isDark)
    }

    @Test func roleSubscriptCoversEveryRole() {
        var c = BuiltInThemes.pixelNight.colors
        for role in ThemeColors.Role.allCases {
            c[role] = HexColor(0x010203)
            #expect(c[role] == HexColor(0x010203), "\(role)")
        }
    }
}

@Suite struct VSCodeThemeTests {
    @Test func stripsCommentsAndTrailingCommas() throws {
        let jsonc = """
        {
          // line comment
          "name": "A // not a comment", /* block
          comment */ "colors": { "editor.background": "#101010", },
          "tokenColors": [ { "scope": "string", "settings": { "foreground": "#00FF00" } }, ],
        }
        """
        let json = try VSCodeTheme.parseJSONC(Data(jsonc.utf8), name: "t")
        #expect(json["name"] as? String == "A // not a comment")
        #expect((json["colors"] as? [String: String])?["editor.background"] == "#101010")
        #expect((json["tokenColors"] as? [Any])?.count == 1)
    }

    @Test func mapsWorkbenchAndTerminalColors() {
        let colors: [String: Any] = [
            "editor.background": "#1E1E2E", "editor.foreground": "#CDD6F4", "sideBar.background": "#181825",
            "input.background": "#313244", "button.background": "#89B4FA", "terminal.ansiRed": "#F38BA8",
            "terminal.ansiGreen": "#A6E3A1", "terminal.ansiBlue": "#89B4FA", "panel.border": "#45475A",
        ]
        let t = VSCodeTheme.convert(colors: colors, tokenColors: [], type: "dark", name: "Mocha Test", source: nil)
        #expect(t.origin == .vscode)
        #expect(t.id == "vscode.mocha-test")
        #expect(t.colors.base.hex == "#1E1E2E")
        #expect(t.colors.card.hex == "#181825")
        #expect(t.colors.inset.hex == "#313244")
        #expect(t.colors.text.hex == "#CDD6F4")
        #expect(t.colors.rose.hex == "#F38BA8")
        #expect(t.colors.mint.hex == "#A6E3A1")
        #expect(t.colors.accent.hex == "#89B4FA")
        #expect(t.isDark)
    }

    @Test func fallsBackToTokenColorsAndKeepsTextReadable() {
        let tokens: [Any] = [["scope": ["string", "string.quoted"], "settings": ["foreground": "#22863A"]],
                             ["scope": "keyword, storage", "settings": ["foreground": "#D73A49"]]]
        // Nearly invisible muted text must be pulled toward the main text color.
        let colors: [String: Any] = ["editor.background": "#FFFFFF", "editor.foreground": "#24292E", "descriptionForeground": "#FAFAFA"]
        let t = VSCodeTheme.convert(colors: colors, tokenColors: tokens, type: "light", name: "Light", source: nil)
        #expect(!t.isDark)
        #expect(t.colors.mint.hex == "#22863A")
        #expect(t.colors.violet.hex == "#D73A49")
        #expect(t.colors.textMuted.contrast(with: t.colors.card) >= 4)
        #expect(t.colors.card != t.colors.base, "a missing sidebar color still gives a distinct card")
    }

    @Test func translucentColorsAreFlattened() {
        let t = VSCodeTheme.convert(colors: ["editor.background": "#000000", "editor.foreground": "#FFFFFF", "input.background": "#FFFFFF80"],
                                    tokenColors: [], type: "dark", name: "x", source: nil)
        #expect(t.colors.inset.alpha == 1)
        #expect(t.colors.inset.hex == "#808080")
    }

    @Test func loadsFileWithIncludeAndDiscoversExtensions() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vsc-\(UUID().uuidString)")
        let ext = root.appending(path: "acme.theme-1.0.0")
        try FileManager.default.createDirectory(at: ext.appending(path: "themes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(##"{"colors": {"editor.background": "#202020", "editor.foreground": "#EEEEEE"}}"##.utf8)
            .write(to: ext.appending(path: "themes/base.json"))
        try Data(##"{ "include": "./base.json", "colors": {"terminal.ansiRed": "#FF5555"}, /* c */ }"##.utf8)
            .write(to: ext.appending(path: "themes/acme-color-theme.json"))
        try Data(##"{"name":"acme","displayName":"%dn%","contributes":{"themes":[{"label":"%lbl%","uiTheme":"vs-dark","path":"./themes/acme-color-theme.json"},{"label":"Escape","path":"../../etc/x.json"}]}}"##.utf8)
            .write(to: ext.appending(path: "package.json"))
        try Data(##"{"dn":"Acme Themes","lbl":"Acme Dark"}"##.utf8).write(to: ext.appending(path: "package.nls.json"))

        let found = VSCodeTheme.installedThemes(roots: [("Test Editor", root.path)])
        #expect(found.map(\.label) == ["Acme Dark"], "the path escaping its extension folder is ignored")
        #expect(found.first?.extensionName == "Acme Themes")
        let t = try VSCodeTheme.load(url: URL(fileURLWithPath: try #require(found.first).path), name: "Acme Dark", uiTheme: "vs-dark")
        #expect(t.colors.base.hex == "#202020", "parent colors come through include")
        #expect(t.colors.rose.hex == "#FF5555")
        #expect(t.source?.hasSuffix("acme-color-theme.json") == true)
    }

    @Test func rejectsNonThemes() throws {
        let f = FileManager.default.temporaryDirectory.appending(path: "nottheme-\(UUID().uuidString).json")
        try Data(##"{"hello": 1}"##.utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(throws: VSCodeTheme.ImportError.self) { try VSCodeTheme.load(url: f) }
        #expect(throws: VSCodeTheme.ImportError.self) { try VSCodeTheme.parseJSONC(Data("not json".utf8), name: "x") }
    }

    @Test func importsARealInstalledThemeIfPresent() {
        // Read-only: if this Mac has VS Code-family themes, the first few import without errors.
        for t in VSCodeTheme.installedThemes().prefix(5) {
            #expect((try? VSCodeTheme.load(url: URL(fileURLWithPath: t.path), name: t.label, uiTheme: t.uiTheme)) != nil, "\(t.label)")
        }
    }
}

@Suite struct AppearanceSettingsTests {
    @Test func defaultsAreTheStandardPresetInSimpleMode() {
        let s = AppearanceSettings()
        #expect(AppearancePreset.matching(s) == .standard)
        #expect(s.style == .smooth && s.displayFont == .rounded && s.bodyFont == .system && s.iconSet == .pixel)
        #expect(s.mode == .simple && s.themeID == BuiltInThemes.instrument.id)
        #expect(s.menuBarFont == .rounded && s.menuBarLabel == .text && !s.menuBarColored)
        #expect(s.textScale == 1)
    }

    @Test func presetsApplyAndAreRecognized() {
        var s = AppearanceSettings()
        AppearancePreset.pixelRetro.apply(to: &s)
        #expect(s.style == .pixel && s.displayFont == .pixel && s.themeID == BuiltInThemes.pixelNight.id)
        #expect(AppearancePreset.matching(s) == .pixelRetro)
        s.textScale = 1.2
        s.menuBarFont = .pixel
        #expect(AppearancePreset.matching(s) == .pixelRetro, "text size and menu bar choices don't break a preset")
        s.bodyFont = .family("Menlo")
        #expect(AppearancePreset.matching(s) == nil, "changing a preset's own field makes the look custom")
    }

    @Test func partialAndOldSettingsDecode() throws {
        let partial = try JSONDecoder().decode(AppearanceSettings.self, from: Data(##"{"style":"smooth","textScale":9,"mode":"bogus"}"##.utf8))
        #expect(partial.style == .smooth)
        #expect(partial.textScale == AppearanceSettings.textScaleRange.upperBound, "out-of-range scale is clamped")
        #expect(partial.mode == .simple, "unknown values fall back to defaults")
        var s = AppearanceSettings()
        s.displayFont = .family("Menlo")
        s.bodyFont = .family("Avenir Next")
        s.mode = .advanced
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func pixelSizesSnapToTheGrid() {
        #expect(PixelFontMetrics.snapped(24) == 22)
        #expect(PixelFontMetrics.snapped(19) == 16.5)
        #expect(PixelFontMetrics.snapped(13) == 11)
        #expect(PixelFontMetrics.snapped(4) == 11)
        #expect(PixelFontMetrics.snapped(30) == 27.5)
        #expect(PixelFontMetrics.snapped(33) == 33)
    }
}

@Suite struct ThemeLibraryTests {
    @Test func saveLoadDeleteAndSafeFileNames() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = ThemeLibrary(directory: dir)
        var t = BuiltInThemes.pixelNight
        t.id = "custom.mine"
        t.origin = .custom
        try lib.save(t)
        #expect(lib.load().map(\.id) == ["custom.mine"])
        #expect(!lib.url(for: "../../evil").lastPathComponent.contains("/"))
        #expect(lib.url(for: "../../evil").deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        try lib.delete(id: "custom.mine")
        #expect(lib.load().isEmpty)
        #expect(ThemeLibrary.uniqueID("a", existing: ["a", "a-2"]) == "a-3")
    }

    @Test func builtInsSavedByMistakeAreIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ThemeLibrary(directory: dir).save(BuiltInThemes.classic)
        #expect(ThemeLibrary(directory: dir).load().isEmpty)
    }
}

@Suite struct AppLogoTests {
    @Test func logosAndDefault() throws {
        #expect(AppLogo.all.map(\.id) == ["apple", "slime", "sprout", "fan"])
        #expect(AppLogo.defaultID == "apple")
        #expect(AppearanceSettings().appLogo == "apple")
        let unknown = try JSONDecoder().decode(AppearanceSettings.self, from: Data(#"{"appLogo":"bitten"}"#.utf8))
        #expect(unknown.appLogo == AppLogo.defaultID, "an unknown logo id falls back to the default")
        var s = AppearanceSettings()
        s.appLogo = "sprout"
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(s)).appLogo == "sprout")
    }
}
