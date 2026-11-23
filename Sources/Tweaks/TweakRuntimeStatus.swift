import Darwin
import Foundation

/// Snapshot the running app publishes for the CLI. A stale file is not proof that the app is alive:
/// the CLI checks the recorded PID before reporting any state as active.
public struct TweakRuntimeStatus: Codable, Equatable, Sendable {
    public struct TweakState: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case active, needsPermission, unavailable, off }

        public let kind: Kind
        public let reason: String?

        public init(_ kind: Kind, reason: String? = nil) {
            self.kind = kind
            self.reason = reason
        }

        public static let active = TweakState(.active)
        public static let off = TweakState(.off)
        public static let needsPermission = TweakState(.needsPermission)
        public static func unavailable(_ reason: String) -> TweakState { TweakState(.unavailable, reason: reason) }
    }

    public var schemaVersion: Int
    public var appPID: Int32
    public var updatedAt: Date
    public var accessibilityGranted: Bool
    public var eventTapInstalled: Bool
    public var tweaks: [String: TweakState]

    public init(appPID: Int32, updatedAt: Date = Date(), accessibilityGranted: Bool,
                eventTapInstalled: Bool = false, tweaks: [String: TweakState] = [:]) {
        self.schemaVersion = 1
        self.appPID = appPID
        self.updatedAt = updatedAt
        self.accessibilityGranted = accessibilityGranted
        self.eventTapInstalled = eventTapInstalled
        self.tweaks = tweaks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        appPID = try c.decode(Int32.self, forKey: .appPID)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        accessibilityGranted = (try? c.decode(Bool.self, forKey: .accessibilityGranted)) ?? false
        eventTapInstalled = (try? c.decode(Bool.self, forKey: .eventTapInstalled)) ?? false
        tweaks = (try? c.decode([String: TweakState].self, forKey: .tweaks)) ?? [:]
    }

    public var isAppRunning: Bool { Self.processExists(appPID) }

    public static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM means the process exists but belongs to another user: still alive.
        return errno == EPERM
    }

    public static func load(from url: URL) -> TweakRuntimeStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TweakRuntimeStatus.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try TweakStore.writeAtomic(encoder.encode(self), to: url)
    }
}
