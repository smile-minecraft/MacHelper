import Darwin

/// Thrown when DiskScan cannot install the ban on materializing cloud-only (dataless) files,
/// e.g. because the kernel policy call failed.
public enum MaterializeProtectionError: Error, Sendable {
    case processPolicyUnavailable
}

extension MaterializeProtectionError: CustomStringConvertible {
    public var description: String {
        "macOS would not disable automatic downloads of cloud-only files; stopped before reading anything"
    }
}

/// The ban is installed per thread, never per process: a process-wide ban would stay in force
/// after the scan and make every other feature fail to read cloud-only files (for example a
/// settings backup the user picks from iCloud Drive) until the app is relaunched.
enum ThreadMaterializePolicy {
    /// Installs the ban on the calling thread. Returns false when the kernel refused it.
    static func install() -> Bool {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                       IOPOL_SCOPE_THREAD,
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
    }

    /// Returns the calling thread to the process policy (the system default).
    static func restore() {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                           IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)
    }

    /// Runs `body` synchronously with the ban on the calling thread and lifts it afterwards.
    /// `body` must not hop threads, so it is synchronous by construction.
    static func withBan<T>(_ body: () throws -> T) throws -> T {
        guard install() else { throw MaterializeProtectionError.processPolicyUnavailable }
        defer { restore() }
        return try body()
    }
}
