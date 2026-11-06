import AppKit
import SwiftUI
import Theming
import UniformTypeIdentifiers

/// Settings → Appearance: mode, theme, style, fonts, text size and menu bar look.
struct AppearanceSettingsView: View {
    @Bindable private var store = ThemeStore.shared
    @State private var editing: ThemeDefinition?
    @State private var showImport = false
    @State private var message: String?

    @State private var showDetails = false

    var body: some View {
        Form {
            Section {
                Picker("Show", selection: $store.settings.mode) {
                    Text("Simple").tag(AppearanceSettings.Mode.simple)
                    Text("Advanced").tag(AppearanceSettings.Mode.advanced)
                }
                .pickerStyle(.segmented)
                Text(store.settings.mode == .simple
                     ? "Shows the essentials in plain language: how your Mac is doing, free space, and one-click cleanup. Monitoring charts, fan curves and startup items are hidden."
                     : "Shows every page, chart and technical detail: monitoring history, fan curves, launch agents and per-process numbers.")
                    .settingsCaption()
            } header: { Text("Interface Mode") }

            Section {
                HStack(spacing: 12) {
                    ForEach(AppearancePreset.allCases, id: \.self) { preset in
                        PresetCard(preset: preset, selected: AppearancePreset.matching(store.settings) == preset) {
                            AppearancePreset.allCases.first { $0 == preset }?.apply(to: &store.settings)
                        }
                    }
                }
                Text(AppearancePreset.matching(store.settings) == nil
                     ? "Custom: you changed details below. Pick a look to start over from it."
                     : "A ready-made look sets the colors, shapes, title font and icons together. Change any detail below to make it your own.")
                    .settingsCaption()
            } header: { Text("Look") }

            Section {
                ThemeGallery(store: store)
                HStack {
                    Button("Edit Colors…") { beginEditing() }
                    Button("Import VS Code Theme…") { showImport = true }
                    Spacer()
                    if store.theme.origin != .builtIn {
                        Button("Export…") { exportCurrent() }
                        Button("Delete", role: .destructive) { deleteCurrent() }
                    }
                }
                if let message { Text(message).settingsCaption() }
            } header: { Text("Colors") } footer: {
                Text("Editing a built-in theme saves your changes as a new copy, so the original stays. Imported VS Code themes keep their colors; only colors are read from the file.")
                    .settingsCaption()
            }

            Section {
                DisclosureGroup("Fonts, text size and shapes", isExpanded: $showDetails) {
                    Picker("Shapes", selection: $store.settings.style) {
                        Text("Rounded").tag(AppearanceSettings.Style.smooth)
                        Text("Pixel").tag(AppearanceSettings.Style.pixel)
                    }
                    .pickerStyle(.segmented)
                    Text(store.settings.style == .pixel
                         ? "Pixel: stepped corners and block borders, like a retro game."
                         : "Rounded: soft corners and smooth rings.")
                        .settingsCaption()
                    Picker("Titles and numbers", selection: displayFont) {
                        Text("System Rounded").tag("rounded")
                        Text("System").tag("system")
                        Text("System Monospaced").tag("monospaced")
                        Text("Cubic 11 (pixel)").tag("pixel")
                        Divider()
                        ForEach(ThemeStore.availableFamilies, id: \.self) { Text($0).tag("family:" + $0) }
                    }
                    Picker("Body text", selection: bodyFont) {
                        Text("System").tag("system")
                        Divider()
                        ForEach(ThemeStore.availableFamilies, id: \.self) { Text($0).tag("family:" + $0) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Text size")
                            Spacer()
                            Text(store.settings.textScale.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                                .foregroundStyle(Palette.textMuted)
                            Button("Reset") { store.settings.textScale = 1 }.disabled(store.settings.textScale == 1)
                        }
                        Slider(value: $store.settings.textScale, in: AppearanceSettings.textScaleRange, step: 0.05) {
                            EmptyView()
                        } minimumValueLabel: { Text(verbatim: "A").font(.mh(size: 10)) } maximumValueLabel: { Text(verbatim: "A").font(.mh(size: 15)) }
                    }
                    FontPreview()
                }
            } header: { Text("Details") } footer: {
                Text("Titles and big numbers use the title font; descriptions and lists use the body font so they stay easy to read.")
                    .settingsCaption()
            }

            Section {
                Picker("Icon set", selection: iconSet) {
                    Text("Pixel art (built-in)").tag("pixel")
                    Text("System symbols").tag("symbols")
                    if !store.iconPacks.isEmpty { Divider() }
                    ForEach(store.iconPacks) { Text($0.name).tag("pack:" + $0.id) }
                }
                LogoPicker(store: store)
                IconGrid(store: store, message: $message)
                HStack {
                    Button("Import Icon Pack…") { importIconPack() }
                    Button("Export as Template…") { exportIconTemplate() }
                    Button("Open Icons Folder") {
                        try? FileManager.default.createDirectory(at: store.iconLibrary.root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(store.iconLibrary.root)
                    }
                    Spacer()
                    if case .pack(let id) = store.settings.iconSet {
                        Button("Delete Pack", role: .destructive) {
                            do { try store.deleteIconPack(id) } catch { message = "\(error)" }
                        }
                    }
                }
            } header: { Text("Icons") } footer: {
                Text("Click an icon to replace it with your own image; replaced icons are used with every set. An icon pack is a folder of images named after the icons (cpu.png, fans.svg …); export the template to see every name. Images in a pack that MacHelper doesn’t use are ignored.")
                    .settingsCaption()
            }

            Section {
                Text("Menu bar font, labels and value colors are in the Menu Bar tab.").settingsCaption()
            }
        }
        .formStyle(.grouped)
        .settingsSurface()
        .sheet(item: $editing) { theme in
            ThemeEditor(original: theme) { edited in
                do { try store.saveCustom(edited); message = nil } catch { message = "\(error)" }
            }
        }
        .sheet(isPresented: $showImport) {
            VSCodeImportSheet(onPick: { item in
                do {
                    let t = try store.importVSCode(url: URL(fileURLWithPath: item.path), name: item.label, uiTheme: item.uiTheme)
                    message = String(localized: "Imported “\(t.name)”.")
                } catch { message = "\(error)" }
            }, onChooseFile: importFile)
        }
    }

    // MARK: Font pickers (string tags keep the menus simple)

    private var displayFont: Binding<String> {
        Binding(get: {
            switch store.settings.displayFont {
            case .pixel: "pixel"
            case .system: "system"
            case .rounded: "rounded"
            case .monospaced: "monospaced"
            case .family(let f): "family:" + f
            }
        }, set: { tag in
            store.settings.displayFont = switch tag {
            case "system": .system
            case "rounded": .rounded
            case "monospaced": .monospaced
            case let t where t.hasPrefix("family:"): .family(String(t.dropFirst(7)))
            default: .pixel
            }
        })
    }

    private var bodyFont: Binding<String> {
        Binding(get: {
            if case .family(let f) = store.settings.bodyFont { return "family:" + f }
            return "system"
        }, set: { tag in
            store.settings.bodyFont = tag.hasPrefix("family:") ? .family(String(tag.dropFirst(7))) : .system
        })
    }

    private var iconSet: Binding<String> {
        Binding(get: {
            switch store.settings.iconSet {
            case .pixel: "pixel"
            case .symbols: "symbols"
            case .pack(let id): "pack:" + id
            }
        }, set: { tag in
            store.settings.iconSet = tag == "symbols" ? .symbols : (tag.hasPrefix("pack:") ? .pack(String(tag.dropFirst(5))) : .pixel)
        })
    }

    private func importIconPack() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a folder of icon images")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let pack = try store.importIconPack(from: url)
            message = String(localized: "Imported \(pack.files.count) icons from “\(pack.name)”.")
        } catch { message = "\(error)" }
    }

    private func exportIconTemplate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        panel.message = String(localized: "Choose where to create the “MacHelper Icons” folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.appending(path: "MacHelper Icons")
        do {
            try store.exportIconTemplate(to: folder)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            message = String(localized: "Exported the icon template.")
        } catch { message = "\(error)" }
    }

    // MARK: Actions

    /// Built-in themes are copied first, so the original stays available.
    private func beginEditing() {
        if store.theme.origin == .builtIn {
            do { editing = try store.duplicate(store.theme) } catch { message = "\(error)" }
        } else {
            editing = store.theme
        }
    }

    private func duplicateCurrent() {
        do { _ = try store.duplicate(store.theme) } catch { message = "\(error)" }
    }

    private func deleteCurrent() {
        do { try store.deleteCustom(store.theme.id) } catch { message = "\(error)" }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a VS Code color theme (.json)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let t = try store.importVSCode(url: url)
            message = String(localized: "Imported “\(t.name)”.")
        } catch { message = "\(error)" }
    }

    private func exportCurrent() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = store.theme.displayName + ".machelper-theme.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(store.theme).write(to: url, options: .atomic)
            message = String(localized: "Exported to \(url.lastPathComponent).")
        } catch { message = "\(error)" }
    }
}

// MARK: - Presets

private struct PresetCard: View {
    let preset: AppearancePreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                    .frame(height: 64)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.mhBody.weight(.semibold)).foregroundStyle(Palette.text)
                        Text(subtitle).font(.mhCaption).foregroundStyle(Palette.textMuted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Theme.accent : Palette.textFaint)
                }
            }
            .padding(10)
            .background(Palette.inset.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.accent : Palette.stroke, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var title: String {
        switch preset {
        case .standard: String(localized: "Standard")
        case .pixelRetro: String(localized: "Pixel Retro")
        }
    }

    private var subtitle: String {
        switch preset {
        case .standard: String(localized: "A calm instrument panel: neutral grays, and color only when something needs attention.")
        case .pixelRetro: String(localized: "Retro game look with a pixel font and stepped corners.")
        }
    }

    /// Drawn in the preset's own colors and font, whatever is selected now.
    @ViewBuilder private var preview: some View {
        let theme = preset == .standard ? BuiltInThemes.instrument : BuiltInThemes.pixelNight
        let c = theme.colors(dark: true)
        HStack(spacing: 8) {
            Text(verbatim: "42%")
                .font(preset == .standard ? .system(size: 22, weight: .semibold, design: .rounded) : .custom(ThemeStore.pixelFontName, fixedSize: 22))
                .foregroundStyle(c.text.color)
            VStack(alignment: .leading, spacing: 4) {
                ForEach([c.blue, c.mint, c.amber], id: \.self) { col in
                    Rectangle().fill(col.color).frame(width: 46, height: 5)
                        .clipShape(RoundedRectangle(cornerRadius: preset == .standard ? 2.5 : 0))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.card.color)
    }
}

// MARK: - Logo

/// The app icon: shown in the Dock while MacHelper runs and in the menu bar panel.
private struct LogoPicker: View {
    @Bindable var store: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App icon").font(.mhBody)
            HStack(spacing: 14) {
                ForEach(AppLogo.all) { logo in
                    let selected = store.settings.appLogo == logo.id
                    Button { store.settings.appLogo = logo.id } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let img = ThemeStore.framedLogo(logo.id) { Image(nsImage: img).resizable() }
                            }
                            .frame(width: 64, height: 64)
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2).padding(4))
                            Text(LocalizedStringKey(logo.title)).font(.mhCaption).foregroundStyle(selected ? Palette.text : Palette.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(LocalizedStringKey(logo.title)))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text("The Dock and the menu bar panel use the icon you pick (or your own image for “App icon (Dock)” below) while MacHelper runs. Finder shows the pixel apple, the icon inside the app.")
                .settingsCaption()
        }
    }
}

// MARK: - Icons

/// Every icon as it looks now; click one to replace it or restore it.
private struct IconGrid: View {
    let store: ThemeStore
    @Binding var message: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], spacing: 10) {
            ForEach(IconCatalog.entries) { entry in
                let replaced = store.iconOverrides?.files[entry.id] != nil
                Menu {
                    Button("Replace with Image…") { replace(entry.id) }
                    if replaced {
                        Button("Restore Default") {
                            do { try store.removeIconOverride(entry.id) } catch { message = "\(error)" }
                        }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Group {
                            if entry.id == "app", case .asset = store.icon("app") {
                                Image(nsImage: NSApp.applicationIconImage).resizable()
                            } else {
                                PixelIcon(name: IconCatalog.assetName(entry.id) ?? "app", size: 32)
                            }
                        }
                        .frame(width: 32, height: 32)
                        Text(LocalizedStringKey(entry.title)).font(.mhCaption2).foregroundStyle(Palette.textMuted)
                            .lineLimit(2).multilineTextAlignment(.center)
                        if replaced { Text("Replaced").font(.mhCaption2).foregroundStyle(Theme.accent) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help(entry.id)
            }
        }
        .padding(.vertical, 4)
    }

    private func replace(_ id: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .pdf, .svg, .jpeg, .tiff, .heic, .icns]
        panel.message = String(localized: "Choose an image (a square one works best)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.setIconOverride(id, from: url); message = nil } catch { message = "\(error)" }
    }
}

// MARK: - Gallery

private struct ThemeGallery: View {
    let store: ThemeStore

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(store.allThemes) { theme in
                Button { store.settings.themeID = theme.id } label: {
                    ThemeSwatch(theme: theme, selected: theme.id == store.theme.id)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(theme.displayName))
                .accessibilityAddTraits(theme.id == store.theme.id ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// A miniature of the theme drawn in its own colors (so it reads right whatever is selected).
private struct ThemeSwatch: View {
    let theme: ThemeDefinition
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.colors(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "42%").font(.display(16)).foregroundStyle(c.text.color)
                HStack(spacing: 3) {
                    ForEach([c.blue, c.mint, c.amber, c.rose, c.violet], id: \.self) { col in
                        Rectangle().fill(col.color).frame(width: 12, height: 6)
                    }
                }
                Rectangle().fill(c.textMuted.color).frame(width: 60, height: 3)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(c.card.color)
            .overlay(Rectangle().strokeBorder(c.stroke.color, lineWidth: 1))
            .padding(8)
            .background(c.base.color)
            .clipShape(SurfaceShape(cornerRadius: 8))
            .overlay(SurfaceShape(cornerRadius: 8).strokeBorder(selected ? Theme.accent : Palette.stroke, lineWidth: selected ? 3 : 1))
            HStack(spacing: 4) {
                Text(theme.displayName).font(.mhCallout.weight(selected ? .semibold : .regular)).foregroundStyle(Palette.text).lineLimit(1)
                Spacer(minLength: 0)
                Text(originLabel).font(.mhCaption2).foregroundStyle(Palette.textFaint)
            }
        }
    }

    private var originLabel: String {
        switch theme.origin {
        case .builtIn: theme.followsSystemAppearance ? String(localized: "Light & Dark") : String(localized: "Built-in")
        case .custom: String(localized: "Custom")
        case .vscode: "VS Code"
        }
    }
}

private struct FontPreview: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CPU").font(Theme.label).foregroundStyle(Palette.textMuted)
                Text(verbatim: "42%").font(Theme.numeral).foregroundStyle(Palette.text)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Everything looks good").font(Theme.heading).foregroundStyle(Palette.text)
                Text("Temperatures, memory and disk space are all in a healthy range.").font(.mhCallout).foregroundStyle(Palette.textMuted)
            }
        }
        .card(padding: 12)
    }
}

// MARK: - Color editor

private struct ThemeEditor: View {
    let original: ThemeDefinition
    let onSave: (ThemeDefinition) -> Void
    @State private var draft: ThemeDefinition
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    init(original: ThemeDefinition, onSave: @escaping (ThemeDefinition) -> Void) {
        self.original = original
        self.onSave = onSave
        _draft = State(initialValue: original)
    }

    /// Themes with two variants edit the one matching the current appearance.
    private var editsDark: Bool { draft.dark != nil && scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Colors").font(Theme.heading)
            TextField("Name", text: $draft.name)
            if draft.dark != nil {
                Text(editsDark ? "Editing the dark variant (switch the system appearance to edit the light one)."
                               : "Editing the light variant (switch the system appearance to edit the dark one).")
                    .font(.mhCaption).foregroundStyle(Palette.textMuted)
            }
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(ThemeColors.Role.allCases) { role in
                        GridRow {
                            Text(Self.title(role)).font(.mhBody)
                            ColorPicker("", selection: binding(role), supportsOpacity: role == .stroke || role == .hairline).labelsHidden()
                            Text(value(role).hex).font(.mh(size: 11, design: .monospaced)).foregroundStyle(Palette.textMuted).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            preview
            HStack {
                Button("Reset") { draft = original }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 640)
    }

    private func value(_ role: ThemeColors.Role) -> HexColor {
        editsDark ? draft.dark![role] : draft.colors[role]
    }

    private func binding(_ role: ThemeColors.Role) -> Binding<Color> {
        Binding(get: { value(role).color }, set: { new in
            let hex = HexColor(NSColor(new))
            if editsDark { draft.dark![role] = hex } else { draft.colors[role] = hex }
        })
    }

    private var preview: some View {
        let c = editsDark ? draft.dark! : draft.colors
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CPU").font(.mh(size: 11)).foregroundStyle(c.textMuted.color)
                Text(verbatim: "42%").font(.display(22)).foregroundStyle(c.text.color)
                Text("Normal").font(.mh(size: 10)).foregroundStyle(c.mint.color)
            }
            .padding(10).background(c.card.color).overlay(Rectangle().strokeBorder(c.stroke.color, lineWidth: 2))
            HStack(spacing: 4) {
                ForEach([ThemeColors.Role.accent, .blue, .cyan, .mint, .amber, .orange, .rose, .violet], id: \.self) { r in
                    Rectangle().fill(c[r].color).frame(width: 16, height: 28)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c.base.color)
    }

    static func title(_ role: ThemeColors.Role) -> String {
        switch role {
        case .base: String(localized: "Window background")
        case .card: String(localized: "Cards")
        case .inset: String(localized: "Fields and tracks")
        case .raised: String(localized: "Selected and raised")
        case .stroke: String(localized: "Borders")
        case .hairline: String(localized: "Dividers")
        case .text: String(localized: "Text")
        case .textMuted: String(localized: "Secondary text")
        case .textFaint: String(localized: "Faint text")
        case .accent: String(localized: "Accent")
        case .blue: String(localized: "Blue (CPU, links)")
        case .cyan: String(localized: "Cyan (network)")
        case .mint: String(localized: "Green (good)")
        case .amber: String(localized: "Yellow (attention)")
        case .rose: String(localized: "Red (warning)")
        case .violet: String(localized: "Violet (GPU)")
        case .orange: String(localized: "Orange (temperature)")
        case .slate: String(localized: "Gray")
        }
    }
}

// MARK: - VS Code import

private struct VSCodeImportSheet: View {
    let onPick: (VSCodeTheme.Installed) -> Void
    let onChooseFile: () -> Void
    @State private var themes: [VSCodeTheme.Installed]?
    @State private var search = ""
    @State private var selection: VSCodeTheme.Installed.ID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import from VS Code").font(Theme.heading)
            Text("Themes installed in VS Code, Cursor, VSCodium and Windsurf, including the built-in ones.")
                .font(.mhCallout).foregroundStyle(Palette.textMuted)
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            if let themes {
                if themes.isEmpty {
                    Text("No VS Code-family editor was found. Use “Choose a .json File…” to import a theme file instead.")
                        .font(.mhCallout).foregroundStyle(Palette.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered(themes), selection: $selection) { t in
                        HStack {
                            Image(systemName: t.isDark ? "moon.fill" : "sun.max.fill").foregroundStyle(Palette.textMuted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.label).font(.mhBody)
                                Text("\(t.extensionName) · \(t.editor)").font(.mhCaption).foregroundStyle(Palette.textMuted)
                            }
                        }
                        .tag(t.id)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button("Choose a .json File…") { dismiss(); DispatchQueue.main.async { onChooseFile() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    if let t = themes?.first(where: { $0.id == selection }) { onPick(t) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .task { themes = await Task.detached(priority: .userInitiated) { VSCodeTheme.installedThemes() }.value }
    }

    private func filtered(_ all: [VSCodeTheme.Installed]) -> [VSCodeTheme.Installed] {
        search.isEmpty ? all : all.filter { $0.label.localizedCaseInsensitiveContains(search) || $0.extensionName.localizedCaseInsensitiveContains(search) }
    }
}
