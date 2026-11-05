import Foundation
import Metrics
import Observation
import UserNotifications

struct AlertSettings: Codable, Equatable {
    var temperatureEnabled = false
    var temperatureCelsius: Double = 95
    var memoryPressureEnabled = false
    var diskEnabled = false
    var diskFreeGB: Double = 10
    /// Minimum time between two notifications of the same kind.
    var cooldownMinutes: Double = 30
}

/// Posts a notification when a reading stays past its threshold (temperature for 2 minutes, memory
/// pressure critical, free disk space low), at most once per cooldown per kind.
@MainActor
@Observable
final class AlertCenter {
    enum Kind: String { case temperature, memory, disk }

    var settings: AlertSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
            if settings.anyEnabled { requestAuthorization() }
        }
    }
    private(set) var authorizationDenied = false

    @ObservationIgnored nonisolated static let key = "alerts.settings"
    @ObservationIgnored private var lastSent: [Kind: Date] = [:]
    @ObservationIgnored private var hotSince: Date?

    init() {
        settings = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(AlertSettings.self, from: $0) }
            ?? AlertSettings()
    }

    /// Re-reads the stored settings after settings are imported.
    func reload() {
        settings = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(AlertSettings.self, from: $0) } ?? AlertSettings()
    }

    func check(cpuCelsius: Double?, memory: MemoryReading?, disk: DiskReading?, now: Date = Date()) {
        let s = settings
        if s.temperatureEnabled, let t = cpuCelsius {
            if t >= s.temperatureCelsius {
                if hotSince == nil { hotSince = now }
                if let since = hotSince, now.timeIntervalSince(since) >= 120 {
                    send(.temperature, title: String(localized: "Mac is running hot"),
                         body: String(localized: "CPU temperature has been \(Fmt.celsius(t)) for over 2 minutes."), now: now)
                }
            } else {
                hotSince = nil
            }
        }
        if s.memoryPressureEnabled, let m = memory, m.pressure == .critical {
            send(.memory, title: String(localized: "Memory pressure is critical"),
                 body: String(localized: "Apps may slow down. Quit apps you don’t need, or check the top processes in MacHelper."), now: now)
        }
        if s.diskEnabled, let d = disk, Double(d.availableBytes) < s.diskFreeGB * 1_000_000_000 {
            send(.disk, title: String(localized: "Startup disk is almost full"),
                 body: String(localized: "Only \(Fmt.bytes(d.availableBytes)) free. Open Optimize to free up space."), now: now)
        }
    }

    private func send(_ kind: Kind, title: String, body: String, now: Date) {
        if let last = lastSent[kind], now.timeIntervalSince(last) < settings.cooldownMinutes * 60 { return }
        lastSent[kind] = now
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "machelper.\(kind.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorizationDenied = !granted }
        }
    }

    /// Sends one sample notification right away (Settings → Test).
    func sendTest() {
        requestAuthorization()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "MacHelper alerts are on")
        content.body = String(localized: "You’ll be notified like this when a threshold is crossed.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "machelper.test", content: content, trigger: nil))
    }
}

extension AlertSettings {
    var anyEnabled: Bool { temperatureEnabled || memoryPressureEnabled || diskEnabled }
}
