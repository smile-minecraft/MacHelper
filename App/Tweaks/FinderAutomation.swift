import AppKit
import ApplicationServices
import Foundation

/// Finder automation: the one Apple Event the tweaks send (`insertion location`) and what macOS
/// thinks about it. Automation is a separate TCC grant from Accessibility: without it Finder refuses
/// the script with -1743, and the tweaks must say so instead of quietly doing nothing.
enum FinderAutomation {
    enum Permission: String, Equatable, Sendable {
        case granted
        case denied
        case undetermined
        case unavailable
    }

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
        switch determinePermission(ask: false) {
        case noErr: return .granted
        case -1743: return .denied        // errAEEventNotPermitted
        case -1744: return .undetermined  // errAEEventWouldRequireUserConsent
        default: return .unavailable      // Finder not running, or no reply
        }
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
        guard let bundleID = "com.apple.finder".data(using: .utf8) else { return -1 }
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
