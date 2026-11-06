import Foundation

/// Converts VS Code color themes (`*-color-theme.json`, the format VS Code, Cursor, VSCodium and
/// Windsurf share) into a MacHelper theme. Only colors are read; nothing in the file is executed.
public enum VSCodeTheme {
    public enum ImportError: Error, CustomStringConvertible, Equatable {
        case unreadable(String)
        case notATheme(String)
        case tooLarge(String)

        public var description: String {
            switch self {
            case .unreadable(let p): "\(p) couldn’t be read as JSON"
            case .notATheme(let p): "\(p) has no colors or token colors"
            case .tooLarge(let p): "\(p) is too large for a color theme"
            }
        }
    }

    public static let maxFileSize = 5_000_000

    // MARK: JSON with comments

    /// Removes `//` and `/* */` comments and trailing commas outside strings (VS Code themes are JSONC).
    public static func stripJSONC(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        let chars = Array(text.unicodeScalars)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.unicodeScalars.append(c)
                if c == "\\", i + 1 < chars.count { out.unicodeScalars.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.unicodeScalars.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "," {
                // Drop the comma when only whitespace separates it from a closing bracket.
                var j = i + 1
                while j < chars.count, chars[j].properties.isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { i += 1; continue }
            }
            out.unicodeScalars.append(c)
            i += 1
        }
        return out
    }

    public static func parseJSONC(_ data: Data, name: String) throws -> [String: Any] {
        guard data.count <= maxFileSize else { throw ImportError.tooLarge(name) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
              let object = try? JSONSerialization.jsonObject(with: Data(stripJSONC(text).utf8)) as? [String: Any]
        else { throw ImportError.unreadable(name) }
        return object
    }

    // MARK: Loading

    /// Loads a theme file, following `include` (a parent theme) up to a few levels.
    public static func load(url: URL, name: String? = nil, uiTheme: String? = nil) throws -> ThemeDefinition {
        let json = try loadMerged(url: url, depth: 0)
        let colors = json["colors"] as? [String: Any] ?? [:]
        let tokens = json["tokenColors"] as? [Any] ?? []
        guard !colors.isEmpty || !tokens.isEmpty else { throw ImportError.notATheme(url.lastPathComponent) }
        let title = name ?? (json["name"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let type = (json["type"] as? String) ?? uiTheme.map { $0 == "vs" || $0 == "hc-light" ? "light" : "dark" }
        return convert(colors: colors, tokenColors: tokens, type: type, name: title, source: url.path)
    }

    static func loadMerged(url: URL, depth: Int) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable(url.lastPathComponent) }
        var json = try parseJSONC(data, name: url.lastPathComponent)
        guard depth < 4, let include = json["include"] as? String else { return json }
        let parentURL = url.deletingLastPathComponent().appending(path: include).standardizedFileURL
        // Only files next to the theme (same extension folder); never climb out of it.
        guard parentURL.path.hasPrefix(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path),
              let parent = try? loadMerged(url: parentURL, depth: depth + 1) else { return json }
        var colors = parent["colors"] as? [String: Any] ?? [:]
        colors.merge(json["colors"] as? [String: Any] ?? [:]) { _, child in child }
        json["colors"] = colors
        json["tokenColors"] = (parent["tokenColors"] as? [Any] ?? []) + (json["tokenColors"] as? [Any] ?? [])
        if json["type"] == nil { json["type"] = parent["type"] }
        return json
    }

    // MARK: Conversion

    /// Maps VS Code's workbench colors (and token colors as a fallback) onto MacHelper's roles.
    public static func convert(colors raw: [String: Any], tokenColors: [Any], type: String?, name: String, source: String?) -> ThemeDefinition {
        var c: [String: HexColor] = [:]
        for (k, v) in raw { if let s = v as? String, let hex = HexColor(hex: s) { c[k] = hex } }
        let tokens = tokenForegrounds(tokenColors)

        let guessedDark = c["editor.background"].map(\.isDark) ?? (type.map { $0 != "light" && $0 != "hc-light" } ?? true)
        let base = opaque(c["editor.background"], over: nil) ?? HexColor(guessedDark ? 0x1E1E1E : 0xFFFFFF)
        let text = opaque(first(c, "editor.foreground", "foreground"), over: base) ?? HexColor(guessedDark ? 0xD4D4D4 : 0x333333)

        func surface(_ keys: [String], fallbackMix: Double) -> HexColor {
            if let v = opaque(first(c, keys), over: base), v != base { return v }
            return base.mixed(with: text, fallbackMix)
        }
        let card = surface(["sideBar.background", "editorWidget.background", "panel.background", "editorGroupHeader.tabsBackground"], fallbackMix: 0.04)
        let inset = surface(["input.background", "dropdown.background", "editor.lineHighlightBackground", "list.inactiveSelectionBackground"], fallbackMix: 0.08)
        let raised = surface(["menu.background", "quickInput.background", "editorSuggestWidget.background", "editorWidget.background"], fallbackMix: 0.11)

        func readable(_ color: HexColor?, fallback: HexColor, minContrast: Double) -> HexColor {
            var v = opaque(color, over: card) ?? fallback
            var step = 0
            while v.contrast(with: card) < minContrast, step < 10 { v = v.mixed(with: text, 0.2); step += 1 }
            return v
        }
        let textMuted = readable(first(c, "descriptionForeground", "tab.inactiveForeground", "sideBarSectionHeader.foreground"),
                                 fallback: text.mixed(with: base, 0.3), minContrast: 4)
        let textFaint = readable(first(c, "editorLineNumber.foreground", "disabledForeground"),
                                 fallback: text.mixed(with: base, 0.45), minContrast: 2.8)

        let stroke = first(c, "panel.border", "editorGroup.border", "sideBar.border", "widget.border", "contrastBorder")
            .map { $0.alpha < 0.05 ? text.withAlpha(0.12) : $0 } ?? text.withAlpha(0.12)
        let hairline = text.withAlpha(0.08)

        func data(_ keys: [String], tokenScopes: [String], fallback: UInt32) -> HexColor {
            let picked = first(c, keys) ?? tokenScopes.lazy.compactMap { tokens[$0] }.first
            return readable(picked, fallback: HexColor(fallback), minContrast: 2.4)
        }
        let blue = data(["terminal.ansiBrightBlue", "terminal.ansiBlue", "textLink.foreground"],
                        tokenScopes: ["entity.name.function", "support.function"], fallback: 0x3B8EEA)
        let cyan = data(["terminal.ansiCyan", "terminal.ansiBrightCyan"], tokenScopes: ["support.type", "entity.name.type"], fallback: 0x29B8DB)
        let mint = data(["terminal.ansiGreen", "terminal.ansiBrightGreen", "gitDecoration.untrackedResourceForeground"],
                        tokenScopes: ["string"], fallback: 0x23D18B)
        let amber = data(["terminal.ansiYellow", "editorWarning.foreground", "terminal.ansiBrightYellow"],
                         tokenScopes: ["entity.name.class", "support.class"], fallback: 0xE5C07B)
        let rose = data(["terminal.ansiRed", "errorForeground", "editorError.foreground", "terminal.ansiBrightRed"],
                        tokenScopes: ["invalid", "variable.language"], fallback: 0xF14C4C)
        let violet = data(["terminal.ansiMagenta", "terminal.ansiBrightMagenta"], tokenScopes: ["keyword", "storage", "keyword.control"],
                          fallback: 0xBC3FBC)
        let orange = data(["editorWarning.foreground", "gitDecoration.modifiedResourceForeground"],
                          tokenScopes: ["constant.numeric", "constant", "constant.language"], fallback: 0xD19A66)
        let accent = readable(first(c, "button.background", "focusBorder", "activityBarBadge.background", "textLink.foreground"),
                              fallback: blue, minContrast: 2.2)

        let colors = ThemeColors(base: base, card: card, inset: inset, raised: raised, stroke: stroke, hairline: hairline,
                                 text: text, textMuted: textMuted, textFaint: textFaint, accent: accent, blue: blue, cyan: cyan,
                                 mint: mint, amber: amber, rose: rose, violet: violet, orange: orange, slate: textMuted)
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        return ThemeDefinition(id: "vscode.\(slug)", name: name, origin: .vscode, colors: colors, source: source)
    }

    static func first(_ c: [String: HexColor], _ keys: String...) -> HexColor? { first(c, keys) }
    static func first(_ c: [String: HexColor], _ keys: [String]) -> HexColor? { keys.lazy.compactMap { c[$0] }.first }

    /// A translucent color drawn over `background` (VS Code allows alpha almost everywhere).
    static func opaque(_ color: HexColor?, over background: HexColor?) -> HexColor? {
        guard let color else { return nil }
        guard color.alpha < 1, let background else { return color.withAlpha(1) }
        return background.mixed(with: color.withAlpha(1), color.alpha).withAlpha(1)
    }

    /// Scope → foreground, first definition wins.
    static func tokenForegrounds(_ tokenColors: [Any]) -> [String: HexColor] {
        var out: [String: HexColor] = [:]
        for case let rule as [String: Any] in tokenColors {
            guard let settings = rule["settings"] as? [String: Any], let fg = (settings["foreground"] as? String).flatMap(HexColor.init(hex:))
            else { continue }
            let scopes: [String]
            if let s = rule["scope"] as? String { scopes = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            else { scopes = rule["scope"] as? [String] ?? [] }
            for s in scopes where out[s] == nil { out[s] = fg }
        }
        return out
    }

    // MARK: Installed themes

    public struct Installed: Sendable, Hashable, Identifiable {
        public let label: String
        public let editor: String
        public let extensionName: String
        public let path: String
        public let uiTheme: String?
        public var id: String { path }
        public var isDark: Bool { uiTheme.map { $0 != "vs" && $0 != "hc-light" } ?? true }
    }

    /// Extension folders of VS Code-family editors: user extensions and the themes built into the apps.
    public static func extensionRoots(home: String = NSHomeDirectory()) -> [(editor: String, path: String)] {
        let apps = [("Visual Studio Code", "Visual Studio Code.app"), ("Cursor", "Cursor.app"), ("VSCodium", "VSCodium.app"),
                    ("Windsurf", "Windsurf.app"), ("VS Code Insiders", "Visual Studio Code - Insiders.app")]
        var roots: [(String, String)] = [("Visual Studio Code", home + "/.vscode/extensions"), ("VS Code Insiders", home + "/.vscode-insiders/extensions"),
                                         ("Cursor", home + "/.cursor/extensions"), ("VSCodium", home + "/.vscode-oss/extensions"),
                                         ("Windsurf", home + "/.windsurf/extensions")]
        for (editor, app) in apps {
            for dir in ["/Applications", home + "/Applications"] {
                roots.append((editor, "\(dir)/\(app)/Contents/Resources/app/extensions"))
            }
        }
        return roots
    }

    public static func installedThemes(roots: [(editor: String, path: String)] = extensionRoots()) -> [Installed] {
        let fm = FileManager.default
        var found: [Installed] = []
        var seen = Set<String>()
        for (editor, root) in roots {
            for ext in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let dir = URL(fileURLWithPath: root).appending(path: ext)
                guard let data = try? Data(contentsOf: dir.appending(path: "package.json")), data.count < maxFileSize,
                      let pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let themes = (pkg["contributes"] as? [String: Any])?["themes"] as? [[String: Any]] else { continue }
                let nls = (try? Data(contentsOf: dir.appending(path: "package.nls.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let extName = localized(pkg["displayName"] as? String ?? pkg["name"] as? String ?? ext, nls)
                for t in themes {
                    guard let rel = t["path"] as? String else { continue }
                    let file = dir.appending(path: rel).standardizedFileURL
                    // Theme files must live inside their extension folder.
                    guard file.path.hasPrefix(dir.standardizedFileURL.path + "/"), seen.insert(file.path).inserted else { continue }
                    let label = localized(t["label"] as? String ?? t["id"] as? String ?? file.deletingPathExtension().lastPathComponent, nls)
                    found.append(Installed(label: label, editor: editor, extensionName: extName, path: file.path, uiTheme: t["uiTheme"] as? String))
                }
            }
        }
        return found.sorted { ($0.label.lowercased(), $0.editor) < ($1.label.lowercased(), $1.editor) }
    }

    /// "%key%" placeholders resolve through package.nls.json.
    static func localized(_ s: String, _ nls: [String: Any]) -> String {
        guard s.hasPrefix("%"), s.hasSuffix("%"), s.count > 2 else { return s }
        let key = String(s.dropFirst().dropLast())
        if let v = nls[key] as? String { return v }
        if let v = (nls[key] as? [String: Any])?["message"] as? String { return v }
        return key
    }
}
