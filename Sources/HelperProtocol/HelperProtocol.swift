import Foundation

public enum HelperConstants {
    public static let appBundleIdentifier = "com.machelper.MacHelper"
    public static let helperBundleIdentifier = "com.machelper.MacHelper.Helper"
    public static let machServiceName = "com.machelper.MacHelper.Helper"
    /// File name inside `MacHelper.app/Contents/Library/LaunchDaemons/`.
    public static let daemonPlistName = "com.machelper.MacHelper.Helper.plist"
    /// Name of the helper executable inside `MacHelper.app/Contents/MacOS/`.
    public static let helperExecutableName = "MacHelperHelper"
    /// Bump when the XPC interface changes; the app refuses to talk to a mismatched helper.
    public static let protocolVersion = 3
}

/// XPC interface exported by the root Helper daemon.
///
/// Values cross the boundary as JSON `Data` so the interface stays small and versionable;
/// the Codable models live in SMCKit / FanControl and are shared by both sides.
@objc public protocol HelperXPC {
    func handshake(reply: @escaping @Sendable (_ protocolVersion: Int, _ helperVersion: String) -> Void)
    func readFans(reply: @escaping @Sendable (_ json: Data?, _ error: String?) -> Void)

    /// `json` is an encoded `FanPolicy`. The Helper validates, persists and starts executing it.
    func applyFanPolicy(_ json: Data, reply: @escaping @Sendable (_ error: String?) -> Void)
    /// Encoded `FanControlStatus`.
    func fanControlStatus(reply: @escaping @Sendable (_ json: Data?, _ error: String?) -> Void)
    /// Liveness signal from the app. Policies that require it fall back to automatic when it stops.
    func heartbeat(reply: @escaping @Sendable () -> Void)

    /// Runs one root maintenance task by id. The Helper maps ids to fixed commands; unknown ids are refused.
    func runMaintenance(_ taskID: String, reply: @escaping @Sendable (_ ok: Bool, _ output: String) -> Void)
}

public enum HelperTiming {
    /// How often the app sends a heartbeat.
    public static let heartbeatInterval: TimeInterval = 10
    /// How long the Helper waits without one before releasing heartbeat-guarded control.
    public static let heartbeatTimeout: TimeInterval = 30
}
