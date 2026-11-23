import ApplicationServices
import ArgumentParser
import Foundation
import Tweaks

/// Lists and acts on other apps' windows through Accessibility. The same window inventory the menu
/// bar item and the Mission Control overlay use, so `windows list` shows the same windows they do.
struct WindowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List, focus, minimize, restore and close windows through Accessibility.",
        discussion: """
        A window id is "<pid>:<window>": the app's process id and the window server's number for the
        window, which is what `windows list` prints. The number stays the same while the window is
        open, so an id from an earlier `list` never reaches a different window.
        Accessibility is a per-executable permission. Without it every command reports that and
        exits non-zero instead of pretending the action worked.
        """,
        subcommands: [WindowsList.self, WindowsFocus.self, WindowsMinimize.self,
                      WindowsRestore.self, WindowsClose.self],
        defaultSubcommand: WindowsList.self)

    /// Every command needs the grant itself; a helper process that was given Accessibility through
    /// its terminal is the usual test setup, so the check is honest about which process lacks it.
    static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw ValidationError("""
            Accessibility permission is not granted to this process. Grant it under System Settings → \
            Privacy & Security → Accessibility for the app that runs this command (a terminal run \
            counts the terminal), then try again.
            """)
        }
    }
}

struct WindowsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every app's ordinary windows, including minimized ones.")

    @OptionGroup var output: OutputOptions

    func run() throws {
        try WindowsCommand.requireAccessibility()
        let windows = WindowCatalog.snapshots()
        if output.json {
            struct Out: Encodable {
                let schemaVersion = 1
                let accessibilityGranted = true
                let windows: [WindowSnapshot]
            }
            try Output.json(Out(windows: windows))
            return
        }
        guard !windows.isEmpty else {
            Output.line("No open windows.")
            return
        }
        let idWidth = windows.map(\.id.description.count).max() ?? 7
        let appWidth = windows.map(\.app.count).max() ?? 3
        for window in windows {
            let state = window.minimized ? "minimized" : (window.visible ? "visible" : "hidden")
            var line = "\(Output.pad(window.id.description, idWidth))  \(Output.pad(window.app, appWidth))  \(state)"
            let title = window.title.isEmpty ? "(untitled)" : window.title
            line += "  \(title)"
            if let frame = window.frame {
                line += "  [\(Int(frame.x)),\(Int(frame.y)) \(Int(frame.width))x\(Int(frame.height))]"
            }
            Output.line(line)
        }
    }
}

/// JSON for the commands that change a window.
struct WindowActionOutput: Encodable {
    let schemaVersion = 1
    let action: WindowAction
    let window: String
    let ok: Bool
}

/// The three commands that change a window share their argument, permission check and output shape.
protocol WindowActionCommand: ParsableCommand {
    var output: OutputOptions { get }
    var window: String { get }
    static var action: WindowAction { get }
}

extension WindowActionCommand {
    func run() throws {
        try WindowsCommand.requireAccessibility()
        guard let identity = WindowIdentity(window) else {
            throw ValidationError("Invalid window id \"\(window)\". Use the id from `machelper windows list`, for example 533:8421.")
        }
        let worked = AccessibilityWindows.perform(Self.action, on: identity)
        if output.json {
            try Output.json(WindowActionOutput(action: Self.action, window: window, ok: worked))
        } else if worked {
            Output.line("\(Self.action.rawValue.capitalized) \(window).")
        } else {
            Output.err("Could not \(Self.action.rawValue) window \(window): it is gone, or the app did not answer.")
        }
        guard worked else { throw ExitCode(1) }
    }
}

struct WindowsFocus: WindowActionCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Bring a window back and in front, activating its app.")
    @OptionGroup var output: OutputOptions
    @Argument(help: "Window id from `machelper windows list`, for example 533:8421.") var window: String
    static let action = WindowAction.focus
}

struct WindowsMinimize: WindowActionCommand {
    static let configuration = CommandConfiguration(commandName: "minimize", abstract: "Minimize a window.")
    @OptionGroup var output: OutputOptions
    @Argument(help: "Window id from `machelper windows list`.") var window: String
    static let action = WindowAction.minimize
}

struct WindowsRestore: WindowActionCommand {
    static let configuration = CommandConfiguration(commandName: "restore", abstract: "Restore a minimized window.")
    @OptionGroup var output: OutputOptions
    @Argument(help: "Window id from `machelper windows list`.") var window: String
    static let action = WindowAction.restore
}

struct WindowsClose: WindowActionCommand {
    static let configuration = CommandConfiguration(commandName: "close", abstract: "Close a window.")
    @OptionGroup var output: OutputOptions
    @Argument(help: "Window id from `machelper windows list`.") var window: String
    static let action = WindowAction.close
}
