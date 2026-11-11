import AppKit
import CleanEngine
import Foundation
import Observation

@MainActor
@Observable
final class UninstallModel {
    enum Tab: String, CaseIterable, Identifiable { case apps, orphans; var id: String { rawValue } }
    enum Sort: String, CaseIterable, Identifiable { case name, size, lastUsed; var id: String { rawValue } }

    /// The app list barely changes while the window is open; reuse a recent scan and refresh
    /// it in the background after this age. Reading every bundle's size is the expensive part.
    static let appsMaxAge: TimeInterval = 120

    var tab: Tab = .apps
    var sort: Sort = .name
    var search = ""
    private(set) var apps: [InstalledApp] = []
    private(set) var loadingApps = false
    /// True while the old list stays on screen and a newer one is being read.
    private(set) var refreshingApps = false
    @ObservationIgnored private var appsLoadedAt: Date?
    var selectedAppID: InstalledApp.ID? { didSet { Task { await loadPlan() } } }
    private(set) var plan: UninstallPlan?
    private(set) var loadingPlan = false
    var includeUserData = false { didSet { applyUserDataChoice() } }
    private(set) var message: String?
    /// System-level leftovers to move with the Helper. Starts with the ones named after the bundle ID.
    var systemSelection: Set<String> = []
    private(set) var helperEnabled = false

    private(set) var orphans: [UninstallItem]?
    private(set) var loadingOrphans = false

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedAppID } }

    var visibleApps: [InstalledApp] {
        let filtered = search.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
        switch sort {
        case .name: return filtered
        case .size: return filtered.sorted { $0.size > $1.size }
        case .lastUsed: return filtered.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    // MARK: Loading

    func loadApps(forceRefresh: Bool = false) async {
        guard !loadingApps, !refreshingApps else { return }
        if !forceRefresh, !apps.isEmpty {
            PageLoadProbe.mark(.uninstall, "cache")
            PageLoadProbe.mark(.uninstall, "apps")
            if let at = appsLoadedAt, Date().timeIntervalSince(at) < Self.appsMaxAge { return }
            refreshingApps = true
        } else {
            loadingApps = true
        }
        defer {
            loadingApps = false
            refreshingApps = false
        }
        apps = await Task.detached(priority: .userInitiated) { AppUninstaller.installedApps() }.value
        appsLoadedAt = Date()
        PageLoadProbe.mark(.uninstall, "apps")
        PageLoadProbe.mark(.uninstall, "refresh")
    }

    private func loadPlan() async {
        message = nil
        guard let app = selectedApp else { plan = nil; return }
        loadingPlan = true
        let others = apps
        let withData = includeUserData
        let p = await Task.detached(priority: .userInitiated) {
            AppUninstaller.plan(for: app, includeUserData: withData, otherApps: others)
        }.value
        guard selectedAppID == app.id else { return }
        plan = p
        helperEnabled = HelperClient.shared.status == .enabled
        systemSelection = helperEnabled ? Set(p.systemItems.filter { Self.isStrongSystemMatch($0, bundleID: app.bundleID) }) : []
        loadingPlan = false
    }

    func loadOrphans() async {
        guard !loadingOrphans else { return }
        loadingOrphans = true
        let installed = apps
        orphans = await Task.detached(priority: .userInitiated) {
            AppUninstaller.orphans(installed: installed.isEmpty ? AppUninstaller.installedApps(measureSizes: false) : installed)
        }.value
        loadingOrphans = false
    }

    // MARK: Selection

    func toggle(_ item: UninstallItem) {
        guard let i = plan?.items.firstIndex(of: item) else { return }
        plan!.items[i].selected.toggle()
    }

    func toggleOrphan(_ item: UninstallItem) {
        guard let i = orphans?.firstIndex(of: item) else { return }
        orphans![i].selected.toggle()
    }

    private func applyUserDataChoice() {
        guard plan != nil else { return }
        for i in plan!.items.indices where plan!.items[i].followsUserData {
            plan!.items[i].selected = includeUserData
        }
    }

    /// The bundle ID appears in the item's own name: clearly this app's. Name-only matches stay unchecked.
    nonisolated static func isStrongSystemMatch(_ path: String, bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return (path as NSString).lastPathComponent.lowercased().contains(bundleID.lowercased())
    }

    func toggleSystem(_ path: String) {
        if systemSelection.contains(path) { systemSelection.remove(path) } else { systemSelection.insert(path) }
    }

    var selectedOrphanBytes: UInt64 { orphans?.filter(\.selected).reduce(0) { $0 + $1.size } ?? 0 }

    // MARK: Actions

    func quitApp() async {
        guard let app = selectedApp else { return }
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) { running.terminate() }
        try? await Task.sleep(for: .seconds(2))
        await loadApps(forceRefresh: true)
        await loadPlan()
    }

    func uninstall() async {
        guard let plan else { return }
        let report: CleanReport
        do {
            report = try await Task.detached(priority: .userInitiated) {
                // NSWorkspace.recycle moves the bundle like Finder does, asking for an administrator
                // password when the app is owned by root (App Store apps).
                try AppUninstaller.execute(plan, dryRun: false, removeBundle: { url in
                    let sem = DispatchSemaphore(value: 0)
                    let box = ErrorBox()
                    NSWorkspace.shared.recycle([url]) { _, error in
                        box.error = error
                        sem.signal()
                    }
                    sem.wait()
                    if let error = box.error { throw error }
                })
            }.value
        } catch {
            message = "\(error)"
            return
        }
        var failed = report.items.filter { $0.result == .failed || $0.result == .skipped }.map { $0.message ?? $0.path }
        let systemPaths = plan.systemItems.filter(systemSelection.contains)
        var systemMoved = 0
        if !systemPaths.isEmpty {
            do {
                let result = try await HelperClient.shared.moveSystemLeftovers(systemPaths)
                let source = "uninstall.\(plan.app.bundleID)"
                OperationLog.shared.append(result.items.map {
                    OperationLog.Entry(time: Date(), command: "uninstall", path: $0.path, source: source, bytes: 0,
                                       result: $0.error == nil ? "trashed" : "failed",
                                       message: $0.error ?? $0.trashedAs.map { "Trash: \($0)" })
                })
                systemMoved = result.items.filter { $0.error == nil }.count
                failed += result.items.compactMap(\.error)
            } catch {
                failed.append("\(error)")
            }
        }
        message = failed.isEmpty
            ? String(localized: "Uninstalled \(plan.app.name); \(Fmt.bytes(Int64(clamping: report.trashedBytes))) moved to the Trash.")
                + (systemMoved > 0 ? " " + String(localized: "\(systemMoved) system items moved to the Trash by the Helper.") : "")
            : String(localized: "Some items weren’t processed (\(failed.count)): \(failed.first ?? "")")
        if !report.items.contains(where: { $0.result == .failed && $0.path == plan.app.path }) {
            selectedAppID = nil
            self.plan = nil
            await loadApps(forceRefresh: true)
        }
    }

    func removeSelectedOrphans() async {
        guard let orphans else { return }
        let items = orphans.filter(\.selected).map { RemovalItem(path: $0.path, source: "orphan", bytes: $0.size, action: .trash) }
        let report = await Task.detached {
            CleanExecutor(safety: AppUninstaller.leftoverSafety).execute(items, dryRun: false, command: "uninstall")
        }.value
        message = String(localized: "Moved to the Trash: \(Fmt.bytes(Int64(clamping: report.trashedBytes)))")
        let removed = Set(report.items.filter { $0.result == .trashed }.map(\.path))
        self.orphans = orphans.filter { !removed.contains($0.path) }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func icon(for app: InstalledApp) -> NSImage {
        // NSWorkspace keeps its own icon cache; a second one here would grow with every app
        // ever scrolled into view.
        NSWorkspace.shared.icon(forFile: app.path)
    }
}

private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}
