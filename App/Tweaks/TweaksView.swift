import SwiftUI
import Tweaks

struct TweaksView: View {
    @Bindable var model: TweakSettingsModel

    var body: some View {
        Form {
            Section {
                Text("Changes are saved to tweaks.json and applied by MacHelper while it is running.")
                    .settingsCaption()
                if model.status?.isAppRunning == false {
                    Text("MacHelper is not running; changes take effect when you open it.")
                        .settingsCaption(Theme.amber)
                }
            }
            ForEach(TweakCategory.allCases, id: \.self) { category in
                Section(LocalizedStringKey(category.title)) {
                    ForEach(TweakCatalog.ids(in: category)) { definition in
                        tweakRow(definition)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .settingsSurface()
        .navigationTitle(Text("Tweaks"))
    }

    @ViewBuilder
    private func tweakRow(_ definition: TweakDefinition) -> some View {
        let enabled = model.settings.isEnabled(definition.id)
        let state = model.status?.tweaks[definition.id.rawValue]?.kind
        Toggle(isOn: Binding(
            get: { enabled },
            set: { model.setEnabled(definition.id, $0) }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(definition.title))
                    .font(.mh(size: 13.5, weight: .semibold))
                Text(LocalizedStringKey(definition.detail))
                    .settingsCaption()
                HStack(spacing: 8) {
                    Text(stateLabel(definition, state)).settingsCaption(stateColor(definition, state))
                    if definition.permissions.contains(.accessibility), model.status?.accessibilityGranted != true {
                        Button("Grant Accessibility") { TweakEngine.requestAccessibility() }
                            .buttonStyle(.link)
                            .font(.mhCaption)
                    }
                    if definition.permissions.contains(.finderExtension) {
                        Text("Requires Finder extension").settingsCaption()
                    }
                    if definition.permissions.contains(.automationFinder) {
                        Text("Requires Finder automation").settingsCaption()
                    }
                }
                if definition.implemented, enabled {
                    ForEach(definition.options, id: \.id) { option in
                        optionRow(option, id: definition.id)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(!definition.implemented)
    }

    @ViewBuilder
    private func optionRow(_ option: TweakOptionDefinition, id: TweakID) -> some View {
        switch option.kind {
        case .bool:
            Toggle(LocalizedStringKey(optionLabel(option.id)),
                   isOn: Binding(get: { model.settings.bool(option.id, for: id) },
                                 set: { model.setValue(option.id, for: id, to: .bool($0)) }))
                .font(.mhCallout)
        case .int:
            Stepper(value: Binding(get: { model.settings.int(option.id, for: id) },
                                   set: { model.setValue(option.id, for: id, to: .int($0)) }),
                    in: Int(option.minimum ?? 0)...Int(option.maximum ?? 100)) {
                Text("\(model.settings.int(option.id, for: id))").font(.mhCallout)
            }
        case .double:
            VStack(alignment: .leading, spacing: 2) {
                Text("Hold duration: \(model.settings.double(option.id, for: id), specifier: "%.1f") s")
                    .font(.mhCallout)
                Slider(value: Binding(get: { model.settings.double(option.id, for: id) },
                                      set: { model.setValue(option.id, for: id, to: .double($0)) }),
                       in: (option.minimum ?? 0)...(option.maximum ?? 1), step: 0.1)
            }
        case .string:
            VStack(alignment: .leading, spacing: 2) {
                TextField(LocalizedStringKey(optionLabel(option.id)),
                          text: Binding(get: { model.settings.string(option.id, for: id) },
                                        set: { model.setValue(option.id, for: id, to: .string($0)) }))
                    .font(.mhCallout)
                if option.id == "hotkey" {
                    Text("Modifiers and one key, for example control+option+w.").settingsCaption()
                }
            }
        case .enumeration:
            Picker(LocalizedStringKey(optionLabel(option.id)), selection: Binding(
                get: { model.settings.string(option.id, for: id) },
                set: { model.setValue(option.id, for: id, to: .string($0)) }
            )) {
                ForEach(option.allowedValues ?? [], id: \.self) { value in
                    Text(LocalizedStringKey(optionLabel(value))).tag(value)
                }
            }
            .font(.mhCallout)
        case .appList:
            TextField(LocalizedStringKey(optionLabel(option.id)),
                      text: Binding(get: { model.settings.stringList(option.id, for: id).joined(separator: ", ") },
                                    set: { model.setValue(option.id, for: id, to: .stringList($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })) }))
                .font(.mhCallout)
        }
    }

    private func stateLabel(_ definition: TweakDefinition, _ state: TweakRuntimeStatus.TweakState.Kind?) -> String {
        if !definition.implemented {
            // A tweak that cannot be offered says why; the rest are simply not written yet.
            return definition.unavailableReason.map { NSLocalizedString($0, comment: "") }
                ?? String(localized: "Coming soon")
        }
        guard let state else { return String(localized: "Waiting for MacHelper") }
        switch state {
        case .active: return String(localized: "Active")
        case .off: return String(localized: "Off")
        case .needsPermission: return String(localized: "Needs permission")
        case .unavailable: return String(localized: "Unavailable")
        }
    }

    private func stateColor(_ definition: TweakDefinition, _ state: TweakRuntimeStatus.TweakState.Kind?) -> Color {
        if !definition.implemented { return Palette.textFaint }
        switch state {
        case .active: return Theme.mint
        case .needsPermission: return Theme.amber
        case .unavailable: return Theme.rose
        default: return Palette.textMuted
        }
    }

    private func optionLabel(_ id: String) -> String {
        switch id {
        case "replacementBundleID": "Replacement app bundle id"
        case "mode": "Guard mode"
        case "hold": "Hold"
        case "holdSeconds": "Hold duration"
        case "doublePress": "Double press"
        case "guardCloseWindow": "Also guard ⌘W"
        case "excludedApps": "Excluded app bundle ids"
        case "action": "Click action"
        case "cycleWindows": "Cycle windows"
        case "closeAction": "Close button"
        case "minimizeAction": "Minimize button"
        case "zoomAction": "Zoom button"
        case "showIcons": "Show app icons"
        case "hotkey": "Global shortcut"
        case "buttons": "Buttons to show"
        case "hide": "Hide app"
        case "minimize": "Minimize windows"
        case "shortcut": "Shortcut"
        case "template": "Template"
        case "text": "Plain text"
        case "markdown": "Markdown"
        case "rtf": "Rich text"
        case "custom": "Custom extension"
        case "baseName": "File name"
        case "customExtension": "Custom extension"
        case "terminalBundleID": "Terminal app bundle id"
        case "quit": "Quit app on the last window"
        case "close": "Close the window"
        case "fullScreen": "Enter full screen"
        case "fill": "Fill the screen"
        case "zoom": "System zoom"
        default: id
        }
    }
}
