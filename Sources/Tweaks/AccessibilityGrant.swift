import Foundation

/// What the running app knows about its Accessibility grant.
///
/// On macOS 27 a process keeps answering `AXIsProcessTrusted()` with the value it read first, so
/// a grant made in System Settings while MacHelper runs is only seen by a new process. That case
/// is `restartRequired`: the grant exists, but this process cannot use it until it relaunches.
public enum AccessibilityGrant: Equatable, Sendable {
    case granted
    case restartRequired
    case notGranted

    /// - Parameters:
    ///   - inProcess: `AXIsProcessTrusted()` in the running app.
    ///   - freshProcess: the same check in a newly started process, nil when it was not run.
    public init(inProcess: Bool, freshProcess: Bool?) {
        if inProcess {
            self = .granted
        } else if freshProcess == true {
            self = .restartRequired
        } else {
            self = .notGranted
        }
    }

    /// The name System Settings gives the Privacy & Security list that holds this grant.
    /// macOS 27 renamed "Accessibility" to "Device Control and Data Access".
    public static func settingsListName(macOSMajorVersion: Int) -> String {
        macOSMajorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }

    public static var settingsListName: String {
        settingsListName(macOSMajorVersion: runningMajorVersion)
    }

    /// True where System Settings shows "Device Control and Data Access" instead of "Accessibility".
    public static var usesDeviceControlName: Bool { runningMajorVersion >= 27 }

    private static var runningMajorVersion: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
}
