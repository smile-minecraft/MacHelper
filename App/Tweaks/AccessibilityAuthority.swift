import ApplicationServices
import Foundation

/// Accessibility is a per-executable TCC grant. The App checks it before installing any event tap;
/// the CLI never installs one and only reports what the App wrote.
enum AccessibilityAuthority {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt once and returns the state right away. The grant itself is picked up
    /// by TweakEngine's poll, so the app does not need to be restarted afterwards.
    @discardableResult
    static func requestPrompt() -> Bool {
        let options = [("AXTrustedCheckOptionPrompt" as CFString): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
