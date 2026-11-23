import Foundation

/// Reads and writes the file shared by the CLI and the app. The CLI's UserDefaults domain differs
/// from the app's, so a file is the only reliable common store.
public struct TweakStore: Sendable {
    public static let changeNotification = "com.machelper.MacHelper.tweaks.changed"

    public let directory: URL
    public var settingsURL: URL { directory.appending(path: "tweaks.json") }
    public var statusURL: URL { directory.appending(path: "tweaks-status.json") }

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let override = ProcessInfo.processInfo.environment["MACHELPER_TWEAKS_DIR"], !override.isEmpty {
            // Isolated test instances (and snapshots) can point at a scratch folder instead of the
            // user's real settings file.
            self.directory = URL(fileURLWithPath: override)
        } else {
            self.directory = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/MacHelper")
        }
    }

    public func load() -> TweakSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(TweakSettings.self, from: data) else { return TweakSettings() }
        return settings
    }

    public func save(_ settings: TweakSettings) throws {
        try Self.writeAtomic(try JSONEncoder().encode(settings), to: settingsURL)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(Self.changeNotification), object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Callers write their own value with the same atomic replace; used by the app for status.
    public static func writeAtomic(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        do {
            if fm.fileExists(atPath: url.path) {
                try fm.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
