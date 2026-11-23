import Cocoa
import FinderSync
import Tweaks

/// The Finder Sync extension: it only offers menu items. Every action travels to the app as a
/// `machelper://finder/…` URL, because the extension is sandboxed and the app is the process that
/// validates the paths and does the work.
final class FinderSync: FIFinderSync {
    /// Which menu was asked for last. A right-click on a folder's background acts on the folder,
    /// whatever happens to be selected in another pane.
    private var askedKind: FIMenuKind = .contextualMenuForItems

    override init() {
        super.init()
        // One extension for every folder: the menu items have to appear wherever a person
        // right-clicks, not only in a configured list of folders.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        askedKind = menuKind
        switch menuKind {
        case .contextualMenuForItems, .contextualMenuForContainer:
            return makeMenu()
        default:
            return nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "")
        menu.addItem(newFileItem())
        menu.addItem(item(String(localized: "Copy Path"), #selector(copyPath(_:))))
        menu.addItem(item(String(localized: "Open in Terminal"), #selector(openTerminal(_:))))
        // Cut only makes sense on items; on a folder's background it would cut the folder.
        if !(FIFinderSyncController.default().selectedItemURLs() ?? []).isEmpty {
            menu.addItem(item(String(localized: "Cut"), #selector(cut(_:))))
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        // The action has to come back to this object even when the item sits in a submenu.
        item.target = self
        return item
    }

    private func newFileItem() -> NSMenuItem {
        let parent = NSMenuItem(title: String(localized: "New File"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: String(localized: "New File"))
        for template in FinderFileTemplate.allCases {
            let item = NSMenuItem(title: title(for: template), action: #selector(newFile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = template.rawValue
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func title(for template: FinderFileTemplate) -> String {
        switch template {
        case .text: String(localized: "Plain Text")
        case .markdown: String(localized: "Markdown")
        case .rtf: String(localized: "Rich Text")
        case .custom: String(localized: "Custom Extension")
        }
    }

    // MARK: - Actions

    @objc private func newFile(_ sender: NSMenuItem) {
        let template = (sender.representedObject as? String).flatMap(FinderFileTemplate.init(rawValue:))
        send(.newFile, template: template)
    }

    @objc private func copyPath(_ sender: NSMenuItem) { send(.copyPath) }
    @objc private func openTerminal(_ sender: NSMenuItem) { send(.openTerminal) }
    @objc private func cut(_ sender: NSMenuItem) { send(.cut) }

    /// The extension never acts on its own: it hands Finder's selection to the app.
    private func send(_ action: FinderMenuAction, template: FinderFileTemplate? = nil) {
        let controller = FIFinderSyncController.default()
        let selected = askedKind == .contextualMenuForContainer ? [] : (controller.selectedItemURLs() ?? [])
        let paths = (selected.isEmpty ? [controller.targetedURL()].compactMap { $0 } : selected).map(\.path)
        guard !paths.isEmpty else { return }
        let request = FinderMenuRequest(action: action, paths: paths, template: template)
        guard let url = FinderMenuURL.make(request) else { return }
        NSWorkspace.shared.open(url)
    }
}
