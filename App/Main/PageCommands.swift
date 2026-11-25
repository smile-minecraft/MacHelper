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

/// The page's items in the window toolbar, each with a fixed id so View → Customize Toolbar… can
/// arrange them and keep that arrangement per page.
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
        if let options = commands?.options, !options.isEmpty {
            // The page's further actions share one customizable item, so hiding it in the
            // customization sheet removes exactly what the page added.
            ToolbarItem(id: "page.options", placement: .primaryAction) {
                HStack(spacing: 0) {
                    ForEach(options) { PageToolbarButton(command: $0) }
                }
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
