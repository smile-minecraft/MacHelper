import AppKit
import CleanEngine
import Foundation
import Observation

/// The only UserDefaults operations this model uses. Tests inject a dictionary-backed value so a
/// model test never creates a preferences file in the user's home folder.
protocol UpdatesDefaults: AnyObject {
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: UpdatesDefaults {}

/// One running copy of an App that a cask installs. Production wraps `NSRunningApplication`; tests
/// create values that hold no real application, so a failed expectation can never quit a user's App.
@MainActor
final class RunningApp {
    let bundleURL: URL?
    private let application: NSRunningApplication?
    private let testTerminated: Bool?

    init(_ application: NSRunningApplication) {
        self.bundleURL = application.bundleURL
        self.application = application
        self.testTerminated = nil
    }

    /// A test-owned value. It has no `NSRunningApplication`, so `terminate()` does nothing real.
    init(bundleURL: URL?, terminated: Bool = true) {
        self.bundleURL = bundleURL
        self.application = nil
        self.testTerminated = terminated
    }

    var isTerminated: Bool { application?.isTerminated ?? testTerminated ?? true }
    func terminate() { application?.terminate() }
}

/// Everything `update()` does outside the model: finding running Apps, quitting and reopening them,
/// and running the upgrade. Tests inject a fake, so even a broken expectation cannot reach the
/// user's Homebrew or a real App.
@MainActor
protocol UpdatesEnvironment {
    func runningApps(_ cask: OutdatedCask) -> [RunningApp]
    func quit(_ apps: [RunningApp]) async -> Bool
    func reopen(_ apps: [RunningApp]) async
    func upgrade(_ token: String) async -> HomebrewUpdates.UpgradeOutcome
}

/// The production behavior. It is file-private so a test cannot construct it by accident and
/// reach the user's Homebrew or running Apps; every test passes its own environment.
@MainActor
private struct LiveUpdatesEnvironment: UpdatesEnvironment {
    func runningApps(_ cask: OutdatedCask) -> [RunningApp] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard let name = app.bundleURL?.lastPathComponent else { return false }
            return cask.appNames.contains(name)
                && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.map(RunningApp.init)
    }

    func quit(_ apps: [RunningApp]) async -> Bool {
        for app in apps { app.terminate() }
        for _ in 0..<40 {
            if apps.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return apps.allSatisfy(\.isTerminated)
    }

    func reopen(_ apps: [RunningApp]) async {
        for url in apps.compactMap(\.bundleURL) where FileManager.default.fileExists(atPath: url.path) {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func upgrade(_ token: String) async -> HomebrewUpdates.UpgradeOutcome {
        await Task.detached(priority: .userInitiated) { HomebrewUpdates.upgrade(token) }.value
    }
}

/// Time-dependent text for the Updates page. `now` is an explicit input so the view can refresh it
/// on a schedule and tests can cross Homebrew's 24-hour window without waiting.
enum UpdatesFreshness {
    static func relative(_ date: Date, to now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Homebrew app updates: check → choose → update one by one → report. Nothing changes before `update`.
@MainActor
@Observable
final class UpdatesModel {
    enum Phase: Equatable { case idle, checking, ready, updating }

    private(set) var phase: Phase = .idle
    private(set) var casks: [OutdatedCask] = []
    private(set) var brewMissing: Bool
    private(set) var failure: String?
    private(set) var lastChecked: Date?
    /// When the index behind the visible list was last fetched, so a quick result is never
    /// presented as fresh. A failed list read keeps the previous list's time.
    private(set) var indexUpdatedAt: Date?
    /// When the successful `brew update` of this check finished. Separate from `indexUpdatedAt`:
    /// after a refresh whose new list could not be read, the index time is new but the list is old.
    private(set) var indexRefreshedAt: Date?
    /// True when the list on screen came after a successful `brew update` in this check.
    private(set) var indexRefreshed = false
    /// A check is still running; the list on screen is the first result.
    private(set) var isRefreshingIndex = false
    /// Why the last catalog refresh failed; the list is still from the existing catalog.
    private(set) var refreshFailure: String?
    /// What Homebrew reported while its update still succeeded (for example, it used a cached API file).
    private(set) var refreshWarning: String?
    /// `brew outdated` answered but `brew info` has not; the list is shown but cannot be updated.
    private(set) var detailsPending = false
    /// A catalog refresh will follow the first result.
    private(set) var willRefresh = false
    /// Why `brew info` failed. The listed rows are unconfirmed and cannot be updated here.
    private(set) var detailsFailure: String?
    /// Tokens whose cask definition details are unknown.
    private(set) var unconfirmed: Set<String> = []
    /// The rows on screen came from before a catalog refresh attempt whose new list could not be
    /// read. They stay visible for reference, but their details were not confirmed against the
    /// changed catalog.
    private var rowsNeedReconfirmation = false

    /// A manual refresh changed the catalog (or reported that it may have), but there is no list on
    /// screen to summarize. The view shows only the freshness line so the refresh result is visible.
    var showsFreshnessWithoutSummary: Bool {
        lastChecked == nil && failure != nil
            && (indexRefreshed || refreshFailure != nil || refreshWarning != nil)
    }
    private(set) var selected: Set<String> = []
    /// Tokens the user cleared; a later check must not select them again.
    private var deselected: Set<String> = []
    /// Outcome of the last update of each cask, kept after the list is checked again.
    private(set) var results: [String: HomebrewUpdates.UpgradeOutcome] = [:]
    /// The cask being updated right now, and how far the batch is.
    private(set) var current: String?
    private(set) var progress: (done: Int, total: Int)?

    /// The App bundle this model belongs to and the cask that installs it, never offered as an
    /// update: Homebrew keeps the version it installed while the app updates itself through
    /// Sparkle, so the row would read like a downgrade.
    private let ownAppBundleName: String
    private let ownCaskToken: String
    private let checks: HomebrewUpdateSession
    private let defaults: any UpdatesDefaults
    private let isBrewAvailable: () -> Bool
    private let environment: any UpdatesEnvironment
    /// One check loop owns Homebrew; triggers that arrive meanwhile are coalesced into one follow-up.
    private var runTask: Task<Void, Never>?
    private var recheckWhenDone = false
    private var pendingRefresh = false
    private var isUpdating = false

    @ObservationIgnored static let greedyKey = "updates.includeSelfUpdating"
    var includeSelfUpdating: Bool {
        didSet {
            defaults.set(includeSelfUpdating, forKey: Self.greedyKey)
            Task { await check(followUp: true) }
        }
    }

    /// The app's model: real sessions, real UserDefaults and the live environment. Every other
    /// caller must name its environment explicitly, so a test cannot accidentally fall back to
    /// `NSWorkspace` or the global Homebrew instance.
    convenience init() {
        self.init(session: HomebrewUpdateSession(),
                  ownAppBundleName: Bundle.main.bundleURL.lastPathComponent,
                  ownCaskToken: HomebrewUpdates.appCaskToken,
                  defaults: UserDefaults.standard,
                  isBrewAvailable: { HomebrewUpdates.brew != nil },
                  environment: LiveUpdatesEnvironment())
    }

    init(session: HomebrewUpdateSession,
         ownAppBundleName: String,
         ownCaskToken: String,
         defaults: any UpdatesDefaults,
         isBrewAvailable: @escaping () -> Bool,
         environment: any UpdatesEnvironment) {
        self.checks = session
        self.ownAppBundleName = ownAppBundleName
        self.ownCaskToken = ownCaskToken
        self.defaults = defaults
        self.isBrewAvailable = isBrewAvailable
        self.environment = environment
        self.brewMissing = !isBrewAvailable()
        self.includeSelfUpdating = defaults.bool(forKey: Self.greedyKey)
    }

    /// Casks that can be updated from here: their details are confirmed, they are not pinned, and
    /// they need no administrator password.
    func canUpdate(_ c: OutdatedCask) -> Bool {
        !c.pinned && !c.needsAdmin && !unconfirmed.contains(c.token)
    }

    /// Why some listed rows cannot be updated from the app, for the view to explain. `nil` when
    /// every listed row is confirmed, and while `brew info` is still reading.
    enum DetailNotice: Equatable {
        case detailsFailed(String)
        case missingDetails([String])
        /// The list predates a refresh attempt whose new list could not be read.
        case notReconfirmedAfterRefresh
    }

    var detailNotice: DetailNotice? {
        guard !detailsPending, !casks.isEmpty else { return nil }
        if let detailsFailure { return .detailsFailed(detailsFailure) }
        guard !unconfirmed.isEmpty else { return nil }
        return rowsNeedReconfirmation ? .notReconfirmedAfterRefresh : .missingDetails(unconfirmed.sorted())
    }

    var selectedCasks: [OutdatedCask] { casks.filter { selected.contains($0.token) && canUpdate($0) } }

    func setSelected(_ token: String, _ on: Bool) {
        if on {
            selected.insert(token)
            deselected.remove(token)
        } else {
            selected.remove(token)
            deselected.insert(token)
        }
    }

    /// Reads the list from Homebrew's existing catalog first. When that catalog is older than
    /// Homebrew's own auto-update window, the index is refreshed in the background and the list is
    /// replaced. `refresh` (Check Again) always runs `brew update` first and reports its result.
    func check(refresh: Bool = false, followUp: Bool = false) async {
        if let runTask {
            // Reopening the page only waits for the result already on its way. A new trigger that
            // changes what is asked (Check Again, the greedy toggle) runs once more afterwards.
            if refresh || followUp {
                recheckWhenDone = true
                pendingRefresh = pendingRefresh || refresh
            }
            await runTask.value
            return
        }
        guard phase != .updating else {
            if refresh || followUp {
                recheckWhenDone = true
                pendingRefresh = pendingRefresh || refresh
            }
            return
        }
        let task = Task { await self.runCheckLoop(initialRefresh: refresh) }
        runTask = task
        await task.value
    }

    private func runCheckLoop(initialRefresh: Bool) async {
        var refresh = initialRefresh || pendingRefresh
        pendingRefresh = false
        while true {
            recheckWhenDone = false
            await performCheck(refresh: refresh)
            guard recheckWhenDone else { break }
            refresh = pendingRefresh
            pendingRefresh = false
        }
        runTask = nil
    }

    private func performCheck(refresh: Bool) async {
        brewMissing = !isBrewAvailable()
        guard !brewMissing else {
            phase = .idle
            return
        }
        let greedy = includeSelfUpdating
        let ownBundles: Set<String> = [ownAppBundleName]
        let ownTokens: Set<String> = [ownCaskToken]
        phase = .checking
        isRefreshingIndex = refresh
        if let stream = await checks.check(greedy: greedy, refresh: refresh,
                                           excludingAppBundleNames: ownBundles,
                                           excludingTokens: ownTokens) {
            for await snapshot in stream {
                apply(snapshot)
                // The first result is usable while the rest of the check continues.
                if !snapshot.isFinal { phase = .ready }
            }
        } else {
            // Another check owns Homebrew. Wait for it, then run this trigger as a follow-up
            // instead of dropping it.
            await checks.waitUntilIdle()
            recheckWhenDone = true
        }
        isRefreshingIndex = false
        phase = .ready
    }

    private func apply(_ snapshot: HomebrewUpdateSession.Snapshot) {
        detailsPending = snapshot.detailsPending
        willRefresh = snapshot.willRefresh
        isRefreshingIndex = !snapshot.isFinal
        brewMissing = snapshot.brewMissing
        refreshFailure = snapshot.refreshFailure
        refreshWarning = snapshot.refreshWarning
        detailsFailure = snapshot.detailsFailure
        if let message = snapshot.failure {
            failure = message
            if snapshot.indexRefreshed || snapshot.refreshAttempted {
                // The catalog may have changed before the new list failed: a successful refresh
                // certainly did, and a failed `brew update` can still have written part of it. Keep
                // the old rows visible but unconfirmed, so no quit, reopen, or upgrade uses their
                // old app names or administrator flag. A later successful check replaces this
                // state with freshly read details. Only `indexRefreshed` claims the update worked.
                unconfirmed = Set(casks.map(\.token))
                selected = []
                indexRefreshed = snapshot.indexRefreshed
                // `indexUpdatedAt` stays the visible list's time; the new fetch is a separate fact.
                indexRefreshedAt = snapshot.indexRefreshed ? snapshot.indexUpdatedAt : nil
                rowsNeedReconfirmation = true
            } else {
                // No update was attempted, so the old rows keep the confirmation state they had.
                indexRefreshed = false
                indexRefreshedAt = nil
            }
            return
        }
        failure = nil
        let previousActionable = Set(casks.filter { canUpdate($0) }.map(\.token))
        casks = snapshot.casks
        unconfirmed = snapshot.unconfirmedTokens
        rowsNeedReconfirmation = false
        // New entries start selected; a user's choice for the others is kept, including a cask
        // that was not actionable before its details were confirmed.
        selected = Set(casks.filter { cask in
            canUpdate(cask) && !deselected.contains(cask.token)
                && (selected.contains(cask.token) || !previousActionable.contains(cask.token))
        }.map(\.token))
        lastChecked = snapshot.checkedAt
        indexUpdatedAt = snapshot.indexUpdatedAt
        indexRefreshedAt = snapshot.indexRefreshed ? snapshot.indexUpdatedAt : nil
        indexRefreshed = snapshot.indexRefreshed
    }

    /// The catalog is older than Homebrew's own auto-update window, or its age is unknown. `now` is
    /// explicit so the view passes the time it is rendering and tests can cross the window.
    func isIndexStale(at now: Date) -> Bool {
        guard let indexUpdatedAt else { return true }
        return now.timeIntervalSince(indexUpdatedAt) > HomebrewUpdates.autoUpdateInterval
    }

    /// What the page should say at `now`. A page left open must stop claiming freshness when the
    /// index crosses Homebrew's window, so the view passes the time it is rendering.
    func headline(at now: Date) -> UpdatesHeadline {
        UpdatesHeadline.make(hasResult: lastChecked != nil, casks: casks,
                             indexRefreshed: indexRefreshed, isIndexStale: isIndexStale(at: now),
                             refreshFailure: refreshFailure, refreshWarning: refreshWarning,
                             checkFailed: failure != nil, indexUpdatedAt: indexUpdatedAt)
    }

    /// Running copies of the cask's apps (they are quit before updating and reopened after).
    func runningApps(_ c: OutdatedCask) -> [RunningApp] { environment.runningApps(c) }

    func appIcon(_ c: OutdatedCask) -> NSImage? {
        for name in c.appNames {
            for dir in ["/Applications", NSHomeDirectory() + "/Applications"] where FileManager.default.fileExists(atPath: dir + "/" + name) {
                return NSWorkspace.shared.icon(forFile: dir + "/" + name)
            }
        }
        return nil
    }

    func update() async {
        guard phase == .ready, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        // A catalog refresh or detail check may still be running. Use the list it settles on, so
        // the upgrade never acts on stale cask details and never starts a second brew process.
        if let runTask { await runTask.value }
        let batch = selectedCasks
        guard !batch.isEmpty, phase == .ready else { return }
        phase = .updating
        for (i, cask) in batch.enumerated() {
            current = cask.token
            progress = (i, batch.count)
            let running = environment.runningApps(cask)
            if !running.isEmpty, !(await environment.quit(running)) {
                results[cask.token] = .init(token: cask.token, ok: false, neededPassword: false,
                                            output: String(localized: "\(cask.name) didn’t quit. Quit it yourself and try again."))
                continue
            }
            let token = cask.token
            let outcome = await environment.upgrade(token)
            results[cask.token] = outcome
            if outcome.ok {
                selected.remove(cask.token)
                deselected.remove(cask.token)
            }
            // Reopen what was running, updated or not (a failed upgrade puts the old version back).
            await environment.reopen(running)
        }
        current = nil
        progress = nil
        phase = .ready
        await check()
    }

    func copyCommand(_ c: OutdatedCask) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.terminalCommand, forType: .string)
    }

    func openTerminal() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
