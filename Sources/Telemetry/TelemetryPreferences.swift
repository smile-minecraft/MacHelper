import Foundation

/// The single owner of every persisted telemetry key.
///
/// Privacy rule: turning telemetry off must erase the anonymous installation ID in the same
/// operation. Keeping the keys together makes that purge impossible to forget at a call site.
///
/// The value stores only a suite name and one resolved string, never a `UserDefaults` instance.
/// Foundation's `UserDefaults` is not `Sendable`, so holding one here would force an unsafe
/// annotation; recreating the (cached) instance per access keeps this genuinely race-free.
public struct TelemetryPreferences: Sendable {
    public static let enabledKey = "telemetry.enabled"
    public static let installIDKey = "telemetry.installId"
    public static let endpointOverrideKey = "telemetry.endpoint"
    public static let endpointInfoPlistKey = "MHTelemetryEndpointURL"

    private let suiteName: String?
    private let plistEndpoint: String?

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// - Parameters:
    ///   - suiteName: Pass an isolated suite in tests so no real preference is touched.
    ///   - infoDictionary: Injected for tests; the shipped app reads its own Info.plist.
    public init(suiteName: String? = nil, infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        self.suiteName = suiteName
        self.plistEndpoint = infoDictionary?[Self.endpointInfoPlistKey] as? String
    }

    /// Off unless someone explicitly stored `true`. A missing key never means opt-in.
    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// The anonymous installation ID, created lazily and only while opted in.
    ///
    /// Reading this while disabled returns `nil` and writes nothing, so an app that never opts
    /// in never leaves an identifier on disk.
    public var installID: String? {
        guard isEnabled else { return nil }
        if let existing = defaults.string(forKey: Self.installIDKey), !existing.isEmpty { return existing }
        return rotateInstallID()
    }

    /// Applies the opt-in switch. Disabling also erases the ID immediately.
    public func setEnabled(_ enabled: Bool) {
        if enabled {
            defaults.set(true, forKey: Self.enabledKey)
        } else {
            defaults.removeObject(forKey: Self.enabledKey)
            clearIdentity()
        }
    }

    /// Removes the anonymous identifier. Safe to call repeatedly.
    public func clearIdentity() {
        defaults.removeObject(forKey: Self.installIDKey)
    }

    /// Generates a fresh anonymous ID. Returns `nil` and clears storage while opted out.
    @discardableResult
    public func rotateInstallID() -> String? {
        guard isEnabled else {
            clearIdentity()
            return nil
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: Self.installIDKey)
        return fresh
    }

    /// A developer-supplied override stored in preferences, if any.
    public var endpointOverride: URL? {
        guard let raw = defaults.string(forKey: Self.endpointOverrideKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// The endpoint used by the transport: preference override first, then the app's build-time
    /// value. An empty `MHTelemetryEndpointURL` means "no endpoint", so nothing is transmitted.
    public var configuredEndpoint: URL? {
        if let override = endpointOverride { return override }
        guard let raw = plistEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// Stores or removes the developer override.
    public func setEndpointOverride(_ url: URL?) {
        if let url {
            defaults.set(url.absoluteString, forKey: Self.endpointOverrideKey)
        } else {
            defaults.removeObject(forKey: Self.endpointOverrideKey)
        }
    }
}

/// Launch arguments that identify a non-interactive helper instance.
///
/// Snapshot, measurement and self-test runs must never queue or send telemetry: they are not
/// normal user sessions and would otherwise report section views nobody actually visited.
public enum TelemetryRuntime {
    public static let excludedFlags = ["--measure-pages", "--selftest"]

    /// True when `arguments` describe a diagnostic launch rather than a normal app run.
    public static func isNonProduction(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains { argument in
            excludedFlags.contains(argument) || argument.hasPrefix("--snapshot")
        }
    }
}
