import AppKit
import CleanEngine
import Foundation
import Observation

@MainActor
@Observable
final class StartupModel {
    /// Reading every launch agent's plist and owner app is cheap enough to repeat, but not on
    /// every page switch; the overview also reads this list for its broken-item hint.
    static let itemsMaxAge: TimeInterval = 60

    private(set) var items: [StartupItem] = []
    private(set) var loading = false
    /// True while the old list stays on screen and a newer one is being read.
    private(set) var refreshing = false
    @ObservationIgnored private var itemsLoadedAt: Date?
    var search = ""
    var onlyBroken = false
    private(set) var message: String?
    /// System daemons are switched through the root Helper.
    private(set) var helperEnabled = false

    enum Tab: String, CaseIterable, Identifiable { case launchd, background; var id: String { rawValue } }
    var tab: Tab = .launchd
    private(set) var backgroundGroups: [BackgroundItemGroup] = []
    private(set) var backgroundError: String?
    private(set) var loadingBackground = false
    var showDisabledBackground = false

    var visibleBackgroundGroups: [BackgroundItemGroup] {
        backgroundGroups.filter { g in
            (showDisabledBackground || g.enabled)
                && (search.isEmpty || g.title.localizedCaseInsensitiveContains(search)
                    || g.items.contains { $0.displayName.localizedCaseInsensitiveContains(search) || $0.identifier.localizedCaseInsensitiveContains(search) })
        }
    }

    /// Reads the Background Task Management list through the Helper (a few seconds, no password).
    /// The refresh button passes `forceRefresh`; opening the tab reuses a recent read.
    func loadBackground(forceRefresh: Bool = false) async {
        guard !loadingBackground else { return }
        loadingBackground = true
        let result = await BackgroundItemsSource.load(forceRefresh: forceRefresh)
        switch result {
        case .success(let items):
            backgroundGroups = BackgroundItems.groups(items)
            backgroundError = nil
            PageLoadProbe.mark(.startup, "background")
        case .failure(.unavailable(let message)):
            backgroundError = message
            PageLoadProbe.mark(.startup, "background-error")
        }
        loadingBackground = false
    }

    var visible: [StartupItem] {
        items.filter { item in
            (!onlyBroken || item.programMissing)
                && (search.isEmpty || item.label.localizedCaseInsensitiveContains(search)
                    || (item.ownerName?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    func load(forceRefresh: Bool = false) async {
        guard !loading, !refreshing else { return }
        if !forceRefresh, !items.isEmpty {
            PageLoadProbe.mark(.startup, "cache")
            PageLoadProbe.mark(.startup, "items")
            if let at = itemsLoadedAt, Date().timeIntervalSince(at) < Self.itemsMaxAge { return }
            refreshing = true
        } else {
            loading = true
        }
        defer {
            loading = false
            refreshing = false
        }
        helperEnabled = HelperClient.shared.status == .enabled
        items = await Task.detached(priority: .userInitiated) { StartupItems.list() }.value
        itemsLoadedAt = Date()
        PageLoadProbe.mark(.startup, "items")
        PageLoadProbe.mark(.startup, "refresh")
    }

    func canToggle(_ item: StartupItem) -> Bool {
        !item.isProtected && (!item.scope.needsHelper || helperEnabled)
    }

    func setEnabled(_ item: StartupItem, _ enabled: Bool) async {
        message = nil
        do {
            if item.scope.needsHelper {
                // The Helper re-validates the path and reads the label from the plist itself.
                try await HelperClient.shared.setSystemDaemonEnabled(plistPath: item.plistPath, enabled: enabled)
                StartupItems.recordToggle(item, enabled)
            } else {
                try await Task.detached { try StartupItems.setEnabled(item, enabled) }.value
            }
        } catch {
            message = "\(error)"
        }
        await reload()
    }

    func remove(_ item: StartupItem) async {
        message = nil
        do {
            let report = try await Task.detached { try StartupItems.remove(item) }.value
            if let f = report.failures.first { message = f.message }
        } catch {
            message = "\(error)"
        }
        await reload()
    }

    private func reload() async {
        loading = false
        refreshing = false
        await load(forceRefresh: true)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func icon(for item: StartupItem) -> NSImage {
        if let p = item.ownerPath { return NSWorkspace.shared.icon(forFile: p) }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }

    func openLoginItems() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}
