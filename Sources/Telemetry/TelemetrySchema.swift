import Foundation
import OSLog

private let schemaLogger = Logger(subsystem: "com.machelper.MacHelper", category: "telemetry.schema")

/// How far a timestamp is rounded before it leaves the process. Coarser buckets are harder to
/// correlate with a person's activity.
public enum TelemetryTimeBucket: Sendable {
    case hour
    case day
}

/// One anonymous, already-sanitized observation.
public struct TelemetryEvent: Sendable, Codable, Equatable {
    public var name: String
    public var timestampBucket: String
    public var properties: [String: String]

    public init(name: String, timestampBucket: String, properties: [String: String]) {
        self.name = name
        self.timestampBucket = timestampBucket
        self.properties = properties
    }
}

/// The complete JSON body sent to the endpoint. Every field is either a fixed vocabulary value
/// or a coarse bucket; none of them can carry a user-supplied string.
public struct TelemetryEnvelope: Sendable, Codable, Equatable {
    public var schemaVersion: Int
    public var installId: String
    public var appVersion: String
    public var buildNumber: String
    public var osVersion: String
    public var chipFamily: String
    public var localeLanguage: String
    public var events: [TelemetryEvent]

    public init(
        schemaVersion: Int = TelemetrySanitizer.schemaVersion,
        installId: String,
        appVersion: String = TelemetryDeviceFacts.appVersion,
        buildNumber: String = TelemetryDeviceFacts.buildNumber,
        osVersion: String = TelemetryDeviceFacts.osVersion,
        chipFamily: String = TelemetryDeviceFacts.chipFamily,
        localeLanguage: String = TelemetryDeviceFacts.localeLanguage,
        events: [TelemetryEvent]
    ) {
        self.schemaVersion = schemaVersion
        self.installId = installId
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
        self.chipFamily = chipFamily
        self.localeLanguage = localeLanguage
        self.events = events
    }
}

/// Coarse, non-identifying device facts. Deliberately excludes model identifiers, serial numbers,
/// hostnames and anything derived from the user's file system.
public enum TelemetryDeviceFacts {
    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    public static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    public static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Two families only. An exact CPU model would be a fingerprint.
    public static var chipFamily: String {
        #if arch(arm64)
        "apple-silicon"
        #else
        "intel"
        #endif
    }

    public static var localeLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }
}

/// Last line of defence before an event is buffered.
///
/// The design is a strict allowlist, not a search-and-replace over free text. A property survives
/// only when both its key and its value are in a fixed, lowercase vocabulary, which makes paths,
/// emails, addresses and arbitrary user strings impossible to smuggle through. The extra pattern
/// checks cover numeric-looking addresses that the general value pattern would otherwise accept.
public enum TelemetrySanitizer {
    public static let schemaVersion = 1
    private static let maxValueLength = 64

    /// Names the client is allowed to emit.
    public static let allowedEventNames: Set<String> = [
        "app_launch", "section_view", "action", "performance_summary",
    ]

    /// Keys the client is allowed to attach. Nothing outside this set is forwarded.
    public static let allowedPropertyKeys: Set<String> = [
        "section", "category", "action", "cold_start_ms", "main_thread_stalls", "memory_mb",
    ]

    private static let safeValuePattern = "^[a-z0-9][a-z0-9_.-]{0,\(maxValueLength - 1)}$"
    private static let ipv4Pattern = "^[0-9]{1,3}(\\.[0-9]{1,3}){3}$"
    private static let macPattern = "^[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}$"

    /// Returns the name when it is in the vocabulary, otherwise `nil` so the caller drops it.
    public static func sanitize(name: String) -> String? {
        allowedEventNames.contains(name) ? name : nil
    }

    /// Drops every disallowed key and every value that is not a short, lowercase token.
    public static func sanitize(properties: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in properties {
            guard allowedPropertyKeys.contains(key), isSafeValue(value) else { continue }
            result[key] = value
        }
        return result
    }

    /// Applies both checks. Returns `nil` for a name or payload that cannot be trusted.
    public static func sanitize(event: TelemetryEvent) -> TelemetryEvent? {
        guard let name = sanitize(name: event.name) else { return nil }
        return TelemetryEvent(name: name,
                              timestampBucket: event.timestampBucket,
                              properties: sanitize(properties: event.properties))
    }

    /// Rounds to a UTC hour or day boundary and formats without a locale-dependent formatter.
    public static func bucket(_ date: Date = Date(), granularity: TelemetryTimeBucket = .hour) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard granularity == .hour else { return day }
        return "\(day)T\(String(format: "%02d", parts.hour ?? 0)):00:00Z"
    }

    /// True for a value that is safe to put on the wire.
    public static func isSafeValue(_ value: String) -> Bool {
        guard value.utf8.count <= maxValueLength,
              matches(value, pattern: safeValuePattern),
              !matches(value, pattern: ipv4Pattern),
              !matches(value, pattern: macPattern) else { return false }
        // A path, email or hostname would also need a character outside the safe pattern, but
        // check explicitly so a future change to that pattern cannot silently open a leak.
        return !value.contains("/") && !value.contains("@") && !value.contains(":")
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Builds a deterministic preview. Kept here, next to the schema, so the settings screen and the
/// tests always describe the exact same payload shape.
public enum TelemetrySample {
    public static func payloadJSON() -> String {
        let envelope = TelemetryEnvelope(
            installId: "00000000-0000-0000-0000-000000000000",
            appVersion: "0.4.0",
            buildNumber: "1",
            osVersion: "15.0.0",
            chipFamily: "apple-silicon",
            localeLanguage: "en",
            events: [
                TelemetryEvent(name: "app_launch",
                               timestampBucket: TelemetrySanitizer.bucket(Date(timeIntervalSince1970: 1_762_000_000)),
                               properties: ["cold_start_ms": "450"]),
                TelemetryEvent(name: "section_view",
                               timestampBucket: TelemetrySanitizer.bucket(Date(timeIntervalSince1970: 1_762_000_600)),
                               properties: ["section": "monitor"]),
                TelemetryEvent(name: "performance_summary",
                               timestampBucket: TelemetrySanitizer.bucket(Date(timeIntervalSince1970: 1_762_001_200)),
                               properties: ["main_thread_stalls": "2", "memory_mb": "320"]),
            ])
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(envelope), as: UTF8.self)
        } catch {
            schemaLogger.error("Could not encode the sample payload: \(error.localizedDescription, privacy: .private)")
            return Self.fallbackJSON
        }
    }

    /// Used only if `JSONEncoder` ever fails on this all-String schema.
    private static let fallbackJSON = """
    {
      "appVersion" : "0.4.0",
      "buildNumber" : "1",
      "chipFamily" : "apple-silicon",
      "events" : [],
      "installId" : "00000000-0000-0000-0000-000000000000",
      "localeLanguage" : "en",
      "osVersion" : "15.0.0",
      "schemaVersion" : 1
    }
    """
}
