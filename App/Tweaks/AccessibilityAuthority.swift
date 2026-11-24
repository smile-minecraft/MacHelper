import ApplicationServices
import Foundation

/// Accessibility is a per-executable TCC grant. The App checks it before installing any event tap;
/// the CLI never installs one and only reports what the App wrote.
enum AccessibilityAuthority {
    /// Run as the only argument, the app executable prints nothing, exits 0 when trusted and 1 when
    /// not, and never starts its user interface.
    static let probeArgument = "--accessibility-probe"

    /// The answer this process read first; on macOS 27 it does not change while the process runs.
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt once and returns the state right away.
    @discardableResult
    static func requestPrompt() -> Bool {
        let options = [("AXTrustedCheckOptionPrompt" as CFString): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func runProbeAndExit() -> Never {
        exit(AXIsProcessTrusted() ? 0 : 1)
    }

    /// Asks a new process running this app's own executable, so TCC checks the same code identity
    /// and the answer reflects a grant made after this process started.
    static func isGrantedInFreshProcess() async -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = [probeArgument]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
