import AppKit
import Foundation
import Tweaks

/// Performs what the Finder extension's menu items ask for. The extension itself never writes a
/// file, changes the clipboard or starts a process: it sends paths, and every action here is
/// re-validated against the file system first.
@MainActor
enum FinderMenuService {
    /// Actions the extension offers; the one it may not show (or the person disabled) is ignored.
    static func perform(_ request: FinderMenuRequest, settings: TweakSettings) {
        guard settings.isEnabled(.finderContextMenu) else { return }
        guard let valid = FinderMenuRequestRules.validate(request, environment) else {
            FinderHUD.show(String(localized: "The Finder selection is no longer available."))
            return
        }
        switch valid.action {
        case .newFile:
            let newFile = FinderNewFileSettings(settings: settings)
            FinderFileActions.createAndReveal(in: URL(fileURLWithPath: valid.paths[0]), settings: newFile,
                                              template: valid.template)
        case .copyPath:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(valid.paths.joined(separator: "\n"), forType: .string)
        case .openTerminal:
            openTerminal(with: valid.paths, settings: settings)
        case .cut:
            cut(valid.paths, moves: settings.isEnabled(.finderCutPaste) && AccessibilityAuthority.isGranted)
        }
    }

    /// The disk checks behind validation. Injected into the pure rules so both use one definition
    /// of "exists", "is a folder" and "can be written to".
    static var environment: FinderMenuRequestRules.Environment {
        FinderMenuRequestRules.Environment(
            exists: { path in FileManager.default.fileExists(atPath: path) },
            isDirectory: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            isWritableDirectory: { path in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return false }
                return FileManager.default.isWritableFile(atPath: path)
            })
    }

    private static func openTerminal(with paths: [String], settings: TweakSettings) {
        let bundleID = settings.string("terminalBundleID", for: .finderContextMenu)
        let terminal = bundleID.isEmpty ? "com.apple.Terminal" : bundleID
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal) else {
            FinderHUD.show(String(localized: "The terminal app could not be found."))
            return
        }
        let folders = paths.prefix(8).map {
            URL(fileURLWithPath: FinderMenuRequestRules.terminalDirectory(for: $0, isDirectory: isDirectory($0)),
                isDirectory: true)
        }
        NSWorkspace.shared.open(Array(folders), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Without the keyboard tweak nothing turns the next ⌘V into a move, so the hint says so
    /// instead of promising one.
    private static func cut(_ paths: [String], moves: Bool) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        guard moves else {
            FinderHUD.show(String(localized: "Copied. Turn on Cut and paste files in Finder to move items instead."))
            return
        }
        // The keyboard tweak owns the cut state: arming it is what turns the next ⌘V into ⌥⌘V.
        TweakEngine.shared.armFinderCut(changeCount: pasteboard.changeCount)
        FinderHUD.show(String(localized: "Cut. Paste in Finder to move the items."))
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// How the extension's request reaches the app: a `machelper://finder/…` URL. The handler is
/// installed by the tweak engine, so it exists exactly when the tweaks run.
@MainActor
final class FinderMenuChannel: NSObject {
    static let shared = FinderMenuChannel()

    private var installed = false
    /// Requests are identified by the id the extension put in the URL: a second delivery of the same
    /// click (for example when macOS reopens the URL) must not create a second file.
    private var seen: [String: Date] = [:]
    private let duplicateWindow: TimeInterval = 5

    func install() {
        guard !installed else { return }
        installed = true
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handle(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text),
              let request = FinderMenuURL.parse(url) else { return }
        deliver(request)
    }

    func deliver(_ request: FinderMenuRequest) {
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < duplicateWindow }
        guard seen[request.id] == nil else { return }
        seen[request.id] = now
        FinderMenuService.perform(request, settings: TweakStore().load())
    }
}

/// Whether macOS has the Finder extension registered and switched on. Asked from `pluginkit` once
/// in a while: the answer changes only when the person changes it in System Settings.
enum FinderExtensionStatus {
    /// The extension lives inside this app, so its identifier follows the app's.
    static var bundleID: String { (Bundle.main.bundleIdentifier ?? "com.machelper.MacHelper") + ".FinderExtension" }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (value: Bool?, at: Date)?
    private static let cacheLifetime: TimeInterval = 5

    static func isEnabled() -> Bool? {
        if let cached = lock.withLock({ cache }), Date().timeIntervalSince(cached.at) < cacheLifetime {
            return cached.value
        }
        let value = query()
        lock.withLock { cache = (value, Date()) }
        return value
    }

    private static func query() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", bundleID]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(whereSeparator: \.isNewline) where line.contains(bundleID) {
            return line.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        }
        // PlugInKit answered and does not know the extension: this build's appex is not registered
        // on this Mac (an older MacHelper without the extension is installed, or it was never
        // opened from the folder it lives in).
        return false
    }
}
