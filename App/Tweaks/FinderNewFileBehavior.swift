import AppKit
import CoreGraphics
import Foundation
import Tweaks

/// The settings one new file is made with, read once so the tap's thread only has to compare key
/// codes and hand a value to the main actor.
struct FinderNewFileSettings: Equatable, Sendable {
    let template: FinderFileTemplate
    let customExtension: String
    let baseName: String
    let shortcut: TweakShortcut

    static let defaultShortcut = TweakShortcut(keyCode: FinderRules.keyN,
                                               flags: TweakRules.controlFlag | TweakRules.alternateFlag)

    init(template: FinderFileTemplate, customExtension: String, baseName: String, shortcut: TweakShortcut) {
        self.template = template
        self.customExtension = customExtension
        self.baseName = baseName
        self.shortcut = shortcut
    }

    init(settings: TweakSettings) {
        self.init(template: FinderFileTemplate(rawValue: settings.string("template", for: .finderNewFile)) ?? .text,
                  customExtension: settings.string("customExtension", for: .finderNewFile),
                  baseName: settings.string("baseName", for: .finderNewFile),
                  // A typo in the shortcut falls back to the documented default instead of taking
                  // no key at all.
                  shortcut: TweakShortcut.parse(settings.string("shortcut", for: .finderNewFile)) ?? Self.defaultShortcut)
    }

    var fileExtension: String {
        FinderNewFileRules.fileExtension(template: template, customExtension: customExtension)
    }
}

/// Matches the global shortcut on the event tap's thread and hands the work to the main actor.
final class FinderNewFileBehavior: @unchecked Sendable {
    private struct Config {
        var enabled = false
        var settings = FinderNewFileSettings(template: .text, customExtension: "txt", baseName: "Untitled",
                                             shortcut: FinderNewFileSettings.defaultShortcut)
        var frontmostBundleID: String?
    }

    private let lock = NSLock()
    private var config = Config()

    func configure(enabled: Bool, settings: TweakSettings, frontmost: NSRunningApplication?) {
        let snapshot = FinderNewFileSettings(settings: settings)
        lock.withLock {
            config = Config(enabled: enabled, settings: snapshot,
                            frontmostBundleID: frontmost?.bundleIdentifier)
        }
    }

    func updateFrontmost(_ app: NSRunningApplication) {
        lock.withLock { config.frontmostBundleID = app.bundleIdentifier }
    }

    /// Nil: not this shortcut.
    func handle(_ type: CGEventType, _ event: CGEvent) -> EventTapService.Outcome? {
        guard type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
        let config = lock.withLock { self.config }
        guard config.enabled, config.frontmostBundleID == FinderRules.bundleID else { return nil }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        guard config.settings.shortcut.matches(keyCode: keyCode, flags: event.flags.rawValue) else { return nil }
        let settings = config.settings
        DispatchQueue.main.async {
            MainActor.assumeIsolated { FinderFileActions.createInCurrentFolder(settings, template: nil) }
        }
        return .suppress
    }
}

/// Creates the file and hands it back to Finder: selected in its window with the name ready to type
/// over. Everything here runs on the main actor; the Apple Event itself waits on its own queue.
@MainActor
enum FinderFileActions {
    private static var isCreating = false

    /// ⌃⌥N: the folder the front Finder window shows.
    static func createInCurrentFolder(_ settings: FinderNewFileSettings, template: FinderFileTemplate?) {
        guard !isCreating else { return }
        isCreating = true
        Task { @MainActor in
            defer { isCreating = false }
            do {
                let folder = try await FinderAutomation.currentFolder()
                let file = try create(in: folder, settings: settings, template: template)
                revealAndRename(file)
            } catch {
                report(error)
            }
        }
    }

    /// The extension's New File item: the folder it sent.
    static func createAndReveal(in folder: URL, settings: FinderNewFileSettings, template: FinderFileTemplate?) {
        do {
            let file = try create(in: folder, settings: settings, template: template)
            revealAndRename(file)
        } catch {
            report(error)
        }
    }

    /// "Untitled.txt", "Untitled 2.txt" … next to whatever is already there.
    static func create(in folder: URL, settings: FinderNewFileSettings, template: FinderFileTemplate?) throws -> URL {
        let template = template ?? settings.template
        let pathExtension = FinderNewFileRules.fileExtension(template: template, customExtension: settings.customExtension)
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let name = FinderNewFileRules.uniqueFileName(base: settings.baseName, pathExtension: pathExtension,
                                                     existing: existing)
        let file = folder.appendingPathComponent(name, isDirectory: false)
        let contents = template.contents
        // Never replaces a file: when the folder listing was unreadable or every name was taken,
        // the write fails instead of overwriting what is there.
        do {
            try contents.write(to: file, options: .withoutOverwriting)
        } catch {
            throw Failure.couldNotWrite(file.path)
        }
        return file
    }

    /// Shows the new file in Finder, selects it and starts a rename. The rename is the same key the
    /// person would press: Finder has no scriptable "start renaming".
    static func revealAndRename(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
        Task { @MainActor in
            guard (try? await Task.sleep(for: .milliseconds(260))) != nil else { return }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FinderRules.bundleID else { return }
            EventTapService.postKey(keyCode: FinderRules.keyReturn, flags: 0, marker: true)
        }
    }

    enum Failure: Error, Equatable {
        case couldNotWrite(String)
    }

    private static func report(_ error: Error) {
        switch error {
        case FinderAutomation.Failure.notPermitted:
            FinderHUD.show(String(localized: "Allow MacHelper to control Finder in System Settings › Privacy & Security › Automation."))
        case FinderAutomation.Failure.noFolderShown:
            FinderHUD.show(String(localized: "Open a Finder window first."))
        default:
            FinderHUD.show(String(localized: "The file could not be created in this folder."))
        }
    }
}
