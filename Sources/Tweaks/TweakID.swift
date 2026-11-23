import Foundation

/// Every tweak known to this build, including the ones that ship as "Coming soon".
/// The raw values are the stable keys used in tweaks.json and in CLI output.
public enum TweakID: String, CaseIterable, Codable, Sendable {
    case finderCutPaste = "finder.cut-paste"
    case finderNewFile = "finder.new-file"
    case finderContextMenu = "finder.context-menu"
    case finderColumnAutosize = "finder.column-autosize"
    case dockClickAction = "dock.click-action"
    case musicBlockAutolaunch = "music.block-autolaunch"
    case windowTrafficLights = "window.traffic-lights"
    case windowCmdTabRestore = "window.cmd-tab-restore"
    case inputQuitGuard = "input.quit-guard"
    case windowSwitcherMenu = "window.switcher-menu"
    case missionControlWindowButtons = "mission-control.window-buttons"

    public var category: TweakCategory {
        switch self {
        case .finderCutPaste, .finderNewFile, .finderContextMenu, .finderColumnAutosize: .finder
        case .dockClickAction: .dock
        case .windowTrafficLights, .windowCmdTabRestore, .windowSwitcherMenu, .missionControlWindowButtons: .window
        case .inputQuitGuard: .keyboard
        case .musicBlockAutolaunch: .media
        }
    }
}

/// Sidebar groups on the Tweaks page. The title is a String Catalog key.
public enum TweakCategory: String, CaseIterable, Codable, Sendable {
    case finder, dock, window, keyboard, media

    public var title: String {
        switch self {
        case .finder: "Finder"
        case .dock: "Dock"
        case .window: "Windows"
        case .keyboard: "Keyboard"
        case .media: "Media"
        }
    }
}

public enum TweakPermission: String, Codable, Sendable {
    case accessibility = "accessibility"
    case automationFinder = "automation-finder"
    case finderExtension = "finder-extension"
}
