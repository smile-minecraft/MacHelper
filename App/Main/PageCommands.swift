import AppKit
import SwiftUI

/// One command a page offers to the menu bar and to the main window's toolbar.
///
/// A page builds these from the same state its buttons use, so a menu item is enabled exactly
/// when the matching button would be.
struct PageCommand: Identifiable {
    /// Stable across page switches and app launches, so a customized toolbar keeps its layout.
    let id: String
    let title: LocalizedStringKey
    let systemImage: String
    var isEnabled = true
    let run: () -> Void
}

/// The commands of the page on screen, published with `.focusedSceneValue(\.pageCommands, …)`.
///
/// The slots are the same on every page. A page without an action for a slot leaves it empty and
/// the menu bar shows that slot disabled instead of dropping it, so the menu never moves and ⌘R
/// always means the same thing. The toolbar, which belongs to one page at a time, shows only the
/// slots the page fills.
struct PageCommands {
    /// Back to the page's own start, at the toolbar's leading edge.
    var back: PageCommand?
    /// The page's main call to action.
    var primary: PageCommand?
    /// Reloads or rescans what the page shows; the Actions menu binds ⌘R to it.
    var refresh: PageCommand?
    /// The page's further actions, in the order its buttons show them.
    var options: [PageCommand] = []
    /// Whether the page shows a search field in the toolbar right now; Edit → Find… (⌘F) focuses it.
    var canSearch = false

    /// The same commands, marked as having a toolbar search field or not.
    func withSearch(_ on: Bool = true) -> PageCommands {
        var commands = self
        commands.canSearch = on
        return commands
    }
}

extension FocusedValues {
    /// The commands of the page on screen, set by the page itself.
    var pageCommands: PageCommands? {
        get { self[PageCommandsKey.self] }
        set { self[PageCommandsKey.self] = newValue }
    }
}

private struct PageCommandsKey: FocusedValueKey {
    typealias Value = PageCommands
}

/// The app's own menu, between View and Window: the current page's main action and its refresh.
struct PageCommandsMenu: Commands {
    @FocusedValue(\.pageCommands) private var commands

    var body: some Commands {
        CommandMenu("Actions") {
            Button { commands?.primary?.run() } label: {
                if let primary = commands?.primary {
                    Text(primary.title)
                } else {
                    Text("Primary Action")
                }
            }
            .disabled(commands?.primary?.isEnabled != true)
            Button { commands?.refresh?.run() } label: {
                if let refresh = commands?.refresh {
                    Text(refresh.title)
                } else {
                    Text("Refresh")
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(commands?.refresh?.isEnabled != true)
        }
    }
}

/// Edit → Find… (⌘F). SwiftUI's toolbar search field doesn't take ⌘F by itself, so the command
/// moves the focus into it, and is disabled on pages without a search.
struct PageFindCommands: Commands {
    @FocusedValue(\.pageCommands) private var commands

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { ToolbarSearch.focus() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(commands?.canSearch != true)
        }
    }
}

/// Puts the keyboard focus in the key window's toolbar search field.
@MainActor
enum ToolbarSearch {
    static func focus() {
        guard let window = NSApp.keyWindow, let toolbar = window.toolbar else { return }
        if let item = toolbar.items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
        } else if let field = toolbar.items.lazy.compactMap({ searchField(in: $0.view) }).first {
            window.makeFirstResponder(field)
        }
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }
}

/// The page's items in the window toolbar, each with a fixed id so View → Customize Toolbar… can
/// arrange them. The window has one toolbar, so the arrangement is shared by every page.
struct PageToolbar: CustomizableToolbarContent {
    let commands: PageCommands?

    var body: some CustomizableToolbarContent {
        if let back = commands?.back {
            ToolbarItem(id: "page.back", placement: .navigation) {
                PageToolbarButton(command: back, showsTitle: true)
            }
        }
        if let primary = commands?.primary {
            ToolbarItem(id: "page.primary", placement: .primaryAction) {
                PageToolbarButton(command: primary, showsTitle: true)
            }
        }
        if let refresh = commands?.refresh {
            ToolbarItem(id: "page.refresh", placement: .primaryAction) {
                PageToolbarButton(command: refresh)
            }
        }
        // One item per action, so each keeps its own label for VoiceOver and the customization sheet.
        ForEach(commands?.options ?? []) { option in
            ToolbarItem(id: "page.option.\(option.id)", placement: .primaryAction) {
                PageToolbarButton(command: option)
            }
        }
    }
}

private struct PageToolbarButton: View {
    let command: PageCommand
    var showsTitle = false

    var body: some View {
        Button(action: command.run) {
            if showsTitle {
                Label(command.title, systemImage: command.systemImage).labelStyle(.titleAndIcon)
            } else {
                Label(command.title, systemImage: command.systemImage)
            }
        }
        .disabled(!command.isEnabled)
        .help(command.title)
    }
}
