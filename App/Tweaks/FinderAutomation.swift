import AppKit
import ApplicationServices
import Foundation
import Permissions

/// Finder automation: the one Apple Event the tweaks send (`insertion location`) and what macOS
/// thinks about it. Automation is a separate TCC grant from Accessibility: without it Finder refuses
/// the script with -1743, and the tweaks must say so instead of quietly doing nothing.
///
/// The app runs with the Hardened Runtime, so it also needs the
/// `com.apple.security.automation.apple-events` entitlement (App/MacHelper.entitlements). Without
/// it macOS never shows the consent alert: asking returns at once and every script fails with -1743.
enum FinderAutomation {
    typealias Permission = FinderAutomationStatus

    static let finderBundleID = "com.apple.finder"

    enum Failure: Error, Equatable, LocalizedError {
        case notPermitted
        case noFolderShown
        /// The Finder reply did not look like a path; message is Finder's own error text.
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                "MacHelper is not allowed to control Finder."
            case .noFolderShown:
                "Finder did not report a folder."
            case .scriptFailed(let message):
                message
            }
        }
    }

    /// What macOS has already decided, without asking the person anything.
    static var permission: Permission {
        Permission(appleEventStatus: determinePermission(ask: false))
    }

    /// Asks macOS for the grant: the first time, the system shows its own alert. The call waits for
    /// the answer, so callers run it off the main thread. `.unavailable` means Finder was not
    /// running, so macOS had nothing to ask about.
    @discardableResult
    static func requestPermission() -> Permission {
        Permission(appleEventStatus: determinePermission(ask: true))
    }

    /// Starts Finder without bringing it forward and waits until it accepts Apple Events (a few
    /// seconds at most). False when it could not be started.
    @MainActor
    static func launchFinder() async -> Bool {
        if NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID).contains(where: \.isFinishedLaunching) {
            return true
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderBundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            return false
        }
        for _ in 0..<20 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID).contains(where: \.isFinishedLaunching) {
                return true
            }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return false }
        }
        return false
    }

    /// The folder the front Finder window shows. Runs off the main thread: a slow Finder must not
    /// stall the app's window while the event loop waits for the reply.
    static func currentFolder() async throws -> URL {
        let script = """
        tell application "Finder"
            set theFolder to insertion location as alias
            return POSIX path of theFolder
        end tell
        """
        let path = try await run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw Failure.noFolderShown }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The scripts run one at a time on their own queue: `NSAppleScript` is not thread-safe, and a
    /// blocked reply must never hold up the main thread.
    private static let queue = DispatchQueue(label: "MacHelper.finder-automation", qos: .userInitiated)

    private static func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: Failure.scriptFailed("The script could not be built."))
                    return
                }
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    continuation.resume(throwing: code == -1743
                        ? Failure.notPermitted
                        : Failure.scriptFailed(error[NSAppleScript.errorMessage] as? String ?? "Finder error \(code)."))
                    return
                }
                continuation.resume(returning: result.stringValue ?? "")
            }
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` for Finder's bundle id. The event class/id only picks
    /// the target; the person grants (or refuses) automation per app.
    private static func determinePermission(ask: Bool) -> OSStatus {
        guard let bundleID = finderBundleID.data(using: .utf8) else { return -1 }
        var target = AEAddressDesc()
        let created = bundleID.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return OSStatus(AECreateDesc(DescType(typeApplicationBundleID), base, buffer.count, &target))
        }
        guard created == noErr else { return created }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(kAECoreSuite),
                                                     AEEventID(kAEGetData), ask)
    }
}
