import CleanEngine
import Foundation

/// The app's only way to read the Background Task Management list: through the root Helper.
/// Running sfltool in the app would ask for an administrator password every time, so without
/// the Helper this reports that it is needed instead.
@MainActor
enum BackgroundItemsSource {
    private static var cached: (items: [BackgroundItem], at: Date)?
    /// The list changes rarely; reuse a recent read (health check period switches, tab changes).
    static let maxAge: TimeInterval = 300

    /// The active count from a recent read, without waiting for the Helper. Health uses it to
    /// show its report immediately and fills the count in when the read finishes.
    static var cachedActiveCount: Int? {
        cached.map { BackgroundItems.activeCount($0.items) }
    }

    static func load(forceRefresh: Bool = false) async -> Result<[BackgroundItem], BackgroundItems.Failure> {
        if !forceRefresh, let cached, Date().timeIntervalSince(cached.at) < maxAge { return .success(cached.items) }
        guard HelperClient.shared.status == .enabled else {
            return .failure(.unavailable(String(localized: "Needs the Helper (Settings → Helper). Without it macOS would ask for an administrator password every time.")))
        }
        let result: Result<[BackgroundItem], BackgroundItems.Failure>
        do {
            let text = try await HelperClient.shared.dumpBackgroundItems()
            result = await Task.detached(priority: .userInitiated) { BackgroundItems.items(fromDump: text) }.value
        } catch {
            result = .failure(.unavailable("\(error)"))
        }
        if case .success(let items) = result { cached = (items, Date()) }
        return result
    }
}
