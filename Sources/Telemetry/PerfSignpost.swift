import OSLog

/// The four subsystems the profiler surfaces in Instruments' Points of Interest lane.
public enum PerfCategory: String, Sendable {
    case sampling
    case storage
    case diskScan
    case ui
}

/// Thin wrapper around `OSSignposter` with static interval names.
///
/// `StaticString` names are baked into the binary, so there is no string formatting on a hot
/// path. When tracing is off, `isEnabled` is false and `beginInterval` is skipped entirely: the
/// call sites pay one Boolean check and nothing else.
public struct PerfSignpost: Sendable {
    private let signposter: OSSignposter

    public init(subsystem: String = "com.machelper.MacHelper", category: PerfCategory) {
        signposter = OSSignposter(subsystem: subsystem, category: category.rawValue)
    }

    /// Returns `nil` when nobody is tracing, which makes the matching `endInterval` a no-op.
    public func beginInterval(_ name: StaticString) -> OSSignpostIntervalState? {
        guard signposter.isEnabled else { return nil }
        return signposter.beginInterval(name)
    }

    public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState?) {
        guard let state else { return }
        signposter.endInterval(name, state)
    }

    /// Measures one synchronous closure. Use the begin/end pair when the work crosses an `await`.
    public func withInterval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        guard let state = beginInterval(name) else { return try body() }
        defer { endInterval(name, state) }
        return try body()
    }
}

public extension PerfSignpost {
    static let sampling = PerfSignpost(category: .sampling)
    static let storage = PerfSignpost(category: .storage)
    static let diskScan = PerfSignpost(category: .diskScan)
    static let ui = PerfSignpost(category: .ui)
}
