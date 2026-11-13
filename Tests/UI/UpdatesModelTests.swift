import CleanEngine
import Foundation
import Testing
@testable import UpdatesFeature

private final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "updates-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private let oneCaskOutdated = #"{"formulae":[],"casks":[{"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false}]}"#
private let oneCaskInfo = #"{"casks":[{"token":"obs","name":["OBS"],"auto_updates":false,"artifacts":[{"app":["OBS.app"]}]}]}"#
private let oneCaskPkgInfo = #"{"casks":[{"token":"obs","name":["OBS Studio"],"auto_updates":false,"artifacts":[{"pkg":["OBS.pkg"]}]}]}"#
private let oneCaskRenamedInfo = #"{"casks":[{"token":"obs","name":["OBS Studio"],"auto_updates":false,"artifacts":[{"app":["OBS Studio.app"]}]}]}"#
private let twoCasksOutdated = #"{"formulae":[],"casks":[{"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false},{"name":"stats","installed_versions":["2.0"],"current_version":"2.1","pinned":false}]}"#
private let twoCasksInfo = #"{"casks":[{"token":"obs","name":["OBS"],"auto_updates":false,"artifacts":[{"app":["OBS.app"]}]},{"token":"stats","name":["Stats"],"auto_updates":true,"artifacts":[{"app":["Stats.app"]}]}]}"#

/// A fake `brew` for the real `UpdatesModel`. Every command goes through this executable.
private final class FakeBrew {
    let executable: URL
    let log: URL
    let repository: URL
    let outdatedJSON: URL
    let greedyJSON: URL
    let infoJSON: URL
    let outdatedAfterJSON: URL
    let infoAfterJSON: URL
    private let outdatedErr: URL
    private let infoErr: URL
    private let updateErr: URL
    private let updateWarning: URL
    private let updatedMarker: URL

    var outdatedDelay: Double = 0 { didSet { rewrite() } }
    var infoDelay: Double = 0 { didSet { rewrite() } }
    var updateDelay: Double = 0 { didSet { rewrite() } }
    var outdatedStatus: Int = 0 { didSet { rewrite() } }
    var outdatedAfterStatus: Int = 0 { didSet { rewrite() } }
    var infoStatus: Int = 0 { didSet { rewrite() } }
    var updateStatus: Int = 0 { didSet { rewrite() } }
    /// Simulates a failed `brew update` that already wrote part of the catalog.
    var partialUpdate = false { didSet { rewrite() } }

    init(root: URL) throws {
        executable = root.appending(path: "bin/brew")
        log = root.appending(path: "brew.log")
        repository = root.appending(path: "repo")
        outdatedJSON = root.appending(path: "outdated.json")
        greedyJSON = root.appending(path: "outdated-greedy.json")
        infoJSON = root.appending(path: "info.json")
        outdatedAfterJSON = root.appending(path: "outdated-after.json")
        infoAfterJSON = root.appending(path: "info-after.json")
        outdatedErr = root.appending(path: "outdated.err")
        infoErr = root.appending(path: "info.err")
        updateErr = root.appending(path: "update.err")
        updateWarning = root.appending(path: "update.warning")
        updatedMarker = root.appending(path: "updated")

        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"),
                                                withIntermediateDirectories: true)
        for file in [log, outdatedJSON, greedyJSON, infoJSON, outdatedErr, infoErr, updateErr, updateWarning] {
            try Data().write(to: file)
        }
        try Data().write(to: repository.appending(path: ".git/FETCH_HEAD"))
        try writeScript()
    }

    func setOutdated(_ json: String) throws { try Data(json.utf8).write(to: outdatedJSON) }
    func setGreedyOutdated(_ json: String) throws { try Data(json.utf8).write(to: greedyJSON) }
    func setInfo(_ json: String) throws { try Data(json.utf8).write(to: infoJSON) }
    func setOutdatedAfter(_ json: String) throws { try Data(json.utf8).write(to: outdatedAfterJSON) }
    func setInfoAfter(_ json: String) throws { try Data(json.utf8).write(to: infoAfterJSON) }
    func setOutdatedError(_ text: String) throws { try Data(text.utf8).write(to: outdatedErr) }
    func setInfoError(_ text: String) throws { try Data(text.utf8).write(to: infoErr) }
    func setUpdateError(_ text: String) throws { try Data(text.utf8).write(to: updateErr) }
    func setUpdateWarning(_ text: String) throws { try Data(text.utf8).write(to: updateWarning) }

    func resetUpdateMarker() { try? FileManager.default.removeItem(at: updatedMarker) }

    func setIndexAge(hours: Double) throws {
        let date = Date().addingTimeInterval(-hours * 3600)
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: repository.appending(path: ".git/FETCH_HEAD").path)
    }

    var invocations: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func count(_ command: String) -> Int {
        invocations.filter { $0 == command || $0.hasPrefix(command + " ") }.count
    }

    private func rewrite() { try? writeScript() }

    private func writeScript() throws {
        let script = """
        #!/bin/sh
        log='\(log.path)'
        printf '%s\\n' "$*" >> "$log"
        case "$1" in
        --repository)
          printf '%s\\n' '\(repository.path)'
          exit 0
          ;;
        update)
          sleep \(updateDelay)
          if [ \(updateStatus) -eq 0 ] || [ \(partialUpdate ? 1 : 0) -eq 1 ]; then
            : > '\(updatedMarker.path)'
            touch '\(repository.appending(path: ".git/FETCH_HEAD").path)'
          fi
          cat '\(updateWarning.path)' >&2
          cat '\(updateErr.path)' >&2
          exit \(updateStatus)
          ;;
        outdated)
          if [ -n "$HOMEBREW_NO_AUTO_UPDATE" ]; then
            sleep \(outdatedDelay)
          else
            sleep 0.01
          fi
          if [ -f '\(updatedMarker.path)' ] && [ -f '\(outdatedAfterJSON.path)' ]; then
            cat '\(outdatedAfterJSON.path)'
            cat '\(outdatedErr.path)' >&2
            exit \(outdatedAfterStatus)
          fi
          case "$*" in
          *--greedy*) cat '\(greedyJSON.path)' ;;
          *) cat '\(outdatedJSON.path)' ;;
          esac
          cat '\(outdatedErr.path)' >&2
          exit \(outdatedStatus)
          ;;
        info)
          sleep \(infoDelay)
          if [ -f '\(updatedMarker.path)' ] && [ -f '\(infoAfterJSON.path)' ]; then
            cat '\(infoAfterJSON.path)'
          else
            cat '\(infoJSON.path)'
          fi
          cat '\(infoErr.path)' >&2
          exit \(infoStatus)
          ;;
        upgrade)
          exit 0
          ;;
        *)
          printf 'unexpected: %s\\n' "$*" >&2
          exit 64
          ;;
        esac
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
}

/// Dictionary-backed defaults: the model's preference never touches CFPreferences or a plist.
private final class MemoryDefaults: UpdatesDefaults {
    private var storage: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        storage[defaultName] as? Bool ?? false
    }

    func set(_ value: Any?, forKey defaultName: String) {
        if let value { storage[defaultName] = value } else { storage.removeValue(forKey: defaultName) }
    }
}

/// Records every external operation the model would perform. It holds no NSRunningApplication and
/// never calls HomebrewUpdates.upgrade, so a failed expectation cannot touch the user's software.
@MainActor
private final class FakeUpdatesEnvironment: UpdatesEnvironment {
    var runningAppsResult: [RunningApp] = []
    var quitResult = true
    var upgradeOutcome: (String) -> HomebrewUpdates.UpgradeOutcome = {
        HomebrewUpdates.UpgradeOutcome(token: $0, ok: true, neededPassword: false, output: "")
    }
    private(set) var upgraded: [String] = []
    private(set) var quitCalls: [[RunningApp]] = []
    private(set) var reopenCalls: [[RunningApp]] = []

    func runningApps(_ cask: OutdatedCask) -> [RunningApp] { runningAppsResult }

    func quit(_ apps: [RunningApp]) async -> Bool {
        quitCalls.append(apps)
        return quitResult
    }

    func reopen(_ apps: [RunningApp]) async {
        reopenCalls.append(apps)
    }

    func upgrade(_ token: String) async -> HomebrewUpdates.UpgradeOutcome {
        upgraded.append(token)
        return upgradeOutcome(token)
    }
}

@MainActor
private func makeModel(_ brew: FakeBrew,
                       isBrewAvailable: @escaping () -> Bool = { true }) -> (UpdatesModel, FakeUpdatesEnvironment) {
    // The session, the brew path, the environment and the preference store are all injected. The
    // production environment is file-private, so a test cannot construct it and reach the user's
    // Homebrew or running Apps. No process-wide environment variable is left behind either.
    let defaults = MemoryDefaults()
    let environment = FakeUpdatesEnvironment()
    let session = HomebrewUpdateSession.testing(brew: brew.executable.path, repository: brew.repository)
    let model = UpdatesModel(session: session, ownAppBundleName: "MacHelper.app",
                             ownCaskToken: HomebrewUpdates.appCaskToken, defaults: defaults,
                             isBrewAvailable: isBrewAvailable, environment: environment)
    return (model, environment)
}

@Suite(.serialized) @MainActor struct UpdatesModelTests {
    @Test func firstFailureHasNoResultAndIsNotPresentedAsNoUpdates() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        brew.outdatedStatus = 1
        try brew.setOutdatedError("network is down")
        let (model, _) = makeModel(brew)

        await model.check()

        #expect(model.failure == "network is down")
        #expect(model.lastChecked == nil)
        #expect(model.casks.isEmpty)
        #expect(model.headline(at: Date()) == .notChecked,
                "a failed first check has no result; the view shows the error instead of an empty list")
    }

    @Test func successfulEmptyCheckIsAllUpToDate() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(#"{"formulae":[],"casks":[]}"#)
        try brew.setIndexAge(hours: 1)
        let (model, _) = makeModel(brew)

        // "All up to date" is only justified after this check actually refreshed Homebrew's index.
        await model.check(refresh: true)

        #expect(model.failure == nil)
        #expect(model.lastChecked != nil)
        #expect(model.casks.isEmpty)
        #expect(model.indexRefreshed)
        #expect(model.headline(at: Date()) == .allUpToDate)
        #expect(brew.count("info") == 0, "an empty list has no details to read")
    }

    @Test func headlineStopsClaimingFreshnessWhenThePageOutlivesTheIndexWindow() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(#"{"formulae":[],"casks":[]}"#)
        try brew.setIndexAge(hours: 1)
        let (model, _) = makeModel(brew)

        await model.check(refresh: true)
        let index = try #require(model.indexUpdatedAt)
        #expect(model.headline(at: index.addingTimeInterval(23 * 3600)) == .allUpToDate)
        #expect(model.headline(at: index.addingTimeInterval(24 * 3600)) == .allUpToDate,
                "Homebrew's 24-hour window is exclusive")
        guard case .noUpdates(let shown) = model.headline(at: index.addingTimeInterval(24 * 3600 + 1)) else {
            Issue.record("a page left open past the window must stop saying all apps are up to date")
            return
        }
        #expect(shown == index, "the headline still shows the index time, now as an old one")
    }

    @Test func freshEmptyIndexWithoutARefreshIsNotAllUpToDate() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(#"{"formulae":[],"casks":[]}"#)
        try brew.setIndexAge(hours: 1)
        let (model, _) = makeModel(brew)

        await model.check()

        #expect(model.failure == nil)
        #expect(!model.indexRefreshed, "a fresh FETCH_HEAD alone did not run brew update")
        if case .noUpdates(let date) = model.headline(at: Date()) {
            #expect(date != nil)
        } else {
            Issue.record("a fresh FETCH_HEAD without an actual refresh cannot prove the API cache is fresh")
        }
        #expect(brew.count("update") == 0)
    }

    @Test func freshIndexShowsAnUnconfirmedListBeforeDetails() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        try brew.setIndexAge(hours: 1)
        brew.outdatedDelay = 0.1
        brew.infoDelay = 0.6
        let (model, _) = makeModel(brew)

        let task = Task { await model.check() }
        var sawPending = false
        for _ in 0..<100 {
            if model.detailsPending && !model.casks.isEmpty {
                sawPending = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawPending, "the list must appear before brew info finishes")
        #expect(model.unconfirmed == ["obs"])
        #expect(model.detailNotice == nil, "while details are reading the rows say so; no failure notice")
        #expect(!model.canUpdate(model.casks[0]), "unconfirmed details must not enable an update")
        #expect(model.selectedCasks.isEmpty)
        #expect(model.headline(at: Date()) == .updates(1))

        await task.value
        #expect(!model.detailsPending)
        #expect(model.canUpdate(model.casks[0]))
        #expect(model.selectedCasks.map(\.token) == ["obs"])
    }

    @Test func emptyResultFromAStaleIndexIsNotAllUpToDate() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(#"{"formulae":[],"casks":[]}"#)
        try brew.setIndexAge(hours: 48)
        brew.updateStatus = 1
        try brew.setUpdateError("offline")
        let (model, _) = makeModel(brew)

        await model.check()

        #expect(model.casks.isEmpty)
        #expect(model.lastChecked != nil)
        #expect(model.refreshFailure == "offline")
        if case .noUpdates(let date) = model.headline(at: Date()) {
            #expect(date != nil, "the old index time is shown with the empty result")
        } else {
            Issue.record("an empty result from a stale, unrefreshed index must not say all apps are up to date")
        }
    }

    @Test func failureAfterSuccessKeepsTheOldResult() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        try brew.setIndexAge(hours: 1)
        let (model, _) = makeModel(brew)

        await model.check(refresh: true)
        let firstChecked = try #require(model.lastChecked)
        #expect(model.indexRefreshed)
        brew.outdatedStatus = 1
        try brew.setOutdatedError("network is down")
        await model.check()

        #expect(model.failure == "network is down")
        #expect(model.lastChecked == firstChecked)
        #expect(model.casks.map(\.token) == ["obs"])
        #expect(model.headline(at: Date()) == .updates(1))
        #expect(model.detailNotice == nil, "a failed check without a refresh keeps the confirmed rows")
        #expect(!model.indexRefreshed, "the old refreshed marker must not describe the failed check")
    }

    @Test func leavingAndReopeningDuringACheckKeepsItsResult() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        try brew.setIndexAge(hours: 1)
        brew.outdatedDelay = 0.5
        let (model, _) = makeModel(brew)

        let firstView = Task { await model.check() }
        try await Task.sleep(for: .milliseconds(100))
        firstView.cancel()   // the page disappeared while the check was running
        await model.check()  // the page opened again

        #expect(model.failure == nil)
        #expect(model.lastChecked != nil)
        #expect(model.casks.map(\.token) == ["obs"])
        #expect(brew.count("outdated") == 1, "reopening must wait for the running check, not start another")
    }

    @Test func checkAgainDuringRefreshIsNotDropped() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        try brew.setIndexAge(hours: 48)
        brew.outdatedDelay = 0.3
        brew.updateDelay = 0.3
        let (model, _) = makeModel(brew)

        let first = Task { await model.check() }
        try await Task.sleep(for: .milliseconds(100))
        await model.check(refresh: true)

        #expect(model.failure == nil)
        #expect(model.indexRefreshed)
        #expect(model.casks.map(\.token) == ["obs"])
        #expect(brew.count("update") == 2,
                "the explicit check must run as a follow-up after the automatic refresh")
        _ = await first.value
    }

    @Test func greedyChangeDuringCheckUsesTheNewSettingInOneFollowUp() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setGreedyOutdated(twoCasksOutdated)
        try brew.setInfo(twoCasksInfo)
        try brew.setIndexAge(hours: 1)
        brew.outdatedDelay = 0.4
        let (model, _) = makeModel(brew)

        let first = Task { await model.check() }
        try await Task.sleep(for: .milliseconds(100))
        model.includeSelfUpdating = true
        await model.check()

        #expect(model.failure == nil)
        #expect(Set(model.casks.map(\.token)) == ["obs", "stats"],
                "the follow-up must use the new setting and must not be overwritten by the old result")
        #expect(brew.invocations.contains { $0.contains("--greedy") })
        _ = await first.value
    }

    @Test func unconfirmedDetailsCannotBeUpdated() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        brew.infoStatus = 1
        try brew.setInfoError("Could not load cask metadata")
        try brew.setIndexAge(hours: 1)
        let (model, _) = makeModel(brew)

        await model.check()

        #expect(model.casks.map(\.token) == ["obs"])
        #expect(model.unconfirmed == ["obs"])
        #expect(model.detailsFailure?.contains("Could not load cask metadata") == true)
        #expect(model.detailNotice == .detailsFailed("Could not load cask metadata"))
        #expect(!model.canUpdate(model.casks[0]))
        #expect(model.selectedCasks.isEmpty)
        #expect(model.headline(at: Date()) == .updates(1))
    }

    @Test func missingDetailsForSomeTokensAreNamed() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(twoCasksOutdated)
        try brew.setInfo(oneCaskInfo)   // Homebrew answered for obs only
        try brew.setIndexAge(hours: 1)
        let (model, _) = makeModel(brew)

        await model.check()

        #expect(model.detailsFailure == nil)
        #expect(model.unconfirmed == ["stats"])
        #expect(model.detailNotice == .missingDetails(["stats"]))
        let stats = try #require(model.casks.first { $0.token == "stats" })
        #expect(!model.canUpdate(stats))
    }

    @Test func refreshFailureKeepsTheListAndSaysWhy() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        brew.updateStatus = 1
        try brew.setUpdateError("offline")
        let (model, _) = makeModel(brew)

        await model.check(refresh: true)

        #expect(model.failure == nil)
        #expect(model.refreshFailure == "offline")
        #expect(!model.indexRefreshed)
        #expect(model.casks.map(\.token) == ["obs"])
        #expect(model.lastChecked != nil)
    }

    @Test func successfulRefreshWithListFailureClearsTheOldRefreshError() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        brew.updateStatus = 1
        try brew.setUpdateError("offline")
        let (model, _) = makeModel(brew)

        await model.check(refresh: true)
        #expect(model.refreshFailure == "offline")

        brew.updateStatus = 0
        brew.outdatedStatus = 1
        try brew.setOutdatedError("the list could not be read")
        await model.check(refresh: true)

        #expect(model.failure == "the list could not be read")
        #expect(model.refreshFailure == nil,
                "a successful update followed by a failed list read must not keep the old offline error")
    }

    @Test func refreshSuccessThenListFailureMarksOldRowsUnconfirmedAndBlocksUpdate() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        try brew.setIndexAge(hours: 1)
        let (model, env) = makeModel(brew)

        await model.check(refresh: true)
        let firstIndex = try #require(model.indexUpdatedAt)
        #expect(model.canUpdate(model.casks[0]))
        #expect(model.selectedCasks.map(\.token) == ["obs"])
        #expect(brew.count("info") == 1)

        // The refreshed catalog now defines obs as a pkg (administrator password), but the new list
        // cannot be read. The old app/needsAdmin=false data must not stay actionable.
        try brew.setOutdatedAfter(oneCaskOutdated)
        try brew.setInfoAfter(oneCaskPkgInfo)
        brew.outdatedAfterStatus = 1
        try brew.setOutdatedError("the list could not be read")

        await model.check(refresh: true)

        #expect(model.failure == "the list could not be read")
        #expect(model.casks.map(\.token) == ["obs"], "the previous list stays visible")
        #expect(model.indexRefreshed, "the update succeeded before the list failed")
        #expect(model.indexUpdatedAt == firstIndex, "the visible list keeps the index time it was read from")
        #expect(model.indexRefreshedAt != nil, "the successful refresh time is kept separately")
        #expect(model.unconfirmed == ["obs"])
        #expect(model.detailNotice == .notReconfirmedAfterRefresh,
                "the rows are the previous results, not a missing-details answer from brew info")
        #expect(!model.canUpdate(model.casks[0]))
        #expect(model.selectedCasks.isEmpty)
        #expect(brew.count("info") == 1, "details are not read from a list that failed")

        await model.update()
        #expect(brew.count("upgrade") == 0, "an unconfirmed old row must not be upgraded")
        #expect(env.upgraded.isEmpty, "the injected environment must not see an upgrade")
        #expect(env.quitCalls.isEmpty, "no App may be quit for a blocked update")
        #expect(env.reopenCalls.isEmpty, "no App may be reopened for a blocked update")

        // A later successful check reads the new definition: the row is now a pkg that needs an
        // administrator password, so it is confirmed but still not updatable from the app.
        brew.outdatedAfterStatus = 0
        await model.check()
        #expect(model.failure == nil)
        #expect(model.unconfirmed.isEmpty)
        #expect(model.casks.first?.name == "OBS Studio")
        #expect(model.casks.first?.needsAdmin == true)
        #expect(!model.canUpdate(model.casks[0]))
        #expect(brew.count("info") == 2)

        // A definition that is safe again becomes actionable, proving the later check re-confirms
        // the rows instead of keeping the unconfirmed state forever.
        try brew.setInfoAfter(oneCaskRenamedInfo)
        await model.check()
        #expect(model.unconfirmed.isEmpty)
        #expect(model.casks.first?.appNames == ["OBS Studio.app"])
        #expect(model.canUpdate(model.casks[0]))
        #expect(model.selectedCasks.map(\.token) == ["obs"])
        #expect(brew.count("info") == 3)
    }

    @Test func refreshFailureIsVisibleWhileDetailsArePending() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        brew.updateStatus = 1
        try brew.setUpdateError("offline")
        brew.infoDelay = 0.6
        let (model, _) = makeModel(brew)

        let task = Task { await model.check(refresh: true) }
        var sawPendingFailure = false
        for _ in 0..<100 {
            if model.detailsPending && model.refreshFailure == "offline" {
                sawPendingFailure = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawPendingFailure,
                "the view must be able to show the refresh failure before info finishes")
        await task.value
        #expect(!model.detailsPending)
    }

    @Test func cachedFallbackWarningIsShownAndDoesNotClaimAllUpToDate() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(#"{"formulae":[],"casks":[]}"#)
        try brew.setIndexAge(hours: 48)
        try brew.setUpdateWarning("Warning: cask.jws.json: update failed, falling back to cached version.")
        let (model, _) = makeModel(brew)

        await model.check()

        #expect(model.refreshWarning?.contains("falling back to cached version") == true)
        if case .noUpdates = model.headline(at: Date()) {
        } else {
            Issue.record("a cached fallback must not be presented as all up to date")
        }
        #expect(brew.count("info") == 0)
    }

    @Test func harmlessUpdateWarningDoesNotSuppressAllUpToDate() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(#"{"formulae":[],"casks":[]}"#)
        try brew.setIndexAge(hours: 48)
        try brew.setUpdateWarning("Warning: Your Xcode is outdated.")
        let (model, _) = makeModel(brew)

        await model.check()

        #expect(model.refreshWarning == nil)
        #expect(model.indexRefreshed)
        #expect(model.headline(at: Date()) == .allUpToDate)
    }

    @Test func unknownDetailsCannotBeUpdated() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        brew.infoStatus = 1
        try brew.setInfoError("Could not load cask metadata")
        try brew.setIndexAge(hours: 1)
        let (model, env) = makeModel(brew)

        await model.check()
        #expect(model.unconfirmed == ["obs"])
        #expect(model.selectedCasks.isEmpty)

        await model.update()
        #expect(brew.count("upgrade") == 0, "unknown details must never become an upgrade")
        #expect(env.upgraded.isEmpty, "the injected environment must not see an upgrade")
        #expect(env.quitCalls.isEmpty)
        #expect(env.reopenCalls.isEmpty)
        #expect(model.phase == .ready)
    }

    @Test func confirmedUpdateRunsThroughTheInjectedEnvironment() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        try brew.setIndexAge(hours: 1)
        let (model, env) = makeModel(brew)
        let appURL = t.url.appending(path: "OBS.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        env.runningAppsResult = [RunningApp(bundleURL: appURL)]
        env.quitResult = true

        await model.check(refresh: true)
        #expect(model.selectedCasks.map(\.token) == ["obs"])

        await model.update()

        #expect(env.upgraded == ["obs"], "a confirmed row must reach the injected upgrade")
        #expect(env.quitCalls.count == 1)
        #expect(env.reopenCalls.count == 1)
        #expect(env.reopenCalls.first?.first?.bundleURL == appURL)
        #expect(model.results["obs"]?.ok == true)
    }

    @Test func quitFailureStopsBeforeUpgradeAndReopen() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        try brew.setIndexAge(hours: 1)
        let (model, env) = makeModel(brew)
        let appURL = t.url.appending(path: "OBS.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        env.runningAppsResult = [RunningApp(bundleURL: appURL)]
        env.quitResult = false

        await model.check(refresh: true)
        await model.update()

        #expect(env.upgraded.isEmpty, "a failed quit must stop before the upgrade")
        #expect(env.quitCalls.count == 1)
        #expect(env.reopenCalls.isEmpty, "a failed quit must not reopen anything")
        #expect(model.results["obs"]?.ok == false)
    }

    @Test func failedUpdateThatMayHaveWrittenBlocksOldRows() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        try brew.setIndexAge(hours: 1)
        let (model, env) = makeModel(brew)

        await model.check(refresh: true)
        #expect(model.canUpdate(model.casks[0]))
        #expect(model.selectedCasks.map(\.token) == ["obs"])

        // `brew update` writes part of the catalog and then exits nonzero; the new list cannot be
        // read either. The old app/needsAdmin=false data must not stay actionable.
        try brew.setOutdatedAfter(oneCaskOutdated)
        try brew.setInfoAfter(oneCaskPkgInfo)
        brew.partialUpdate = true
        brew.updateStatus = 1
        try brew.setUpdateError("update failed after writing")
        brew.outdatedAfterStatus = 1
        try brew.setOutdatedError("the list could not be read")

        await model.check(refresh: true)

        #expect(model.failure == "the list could not be read")
        #expect(model.refreshFailure == "update failed after writing")
        #expect(!model.indexRefreshed, "a failed update is not a refresh")
        #expect(model.unconfirmed == ["obs"])
        #expect(!model.canUpdate(model.casks[0]))
        #expect(model.selectedCasks.isEmpty)

        await model.update()
        #expect(env.upgraded.isEmpty)
        #expect(env.quitCalls.isEmpty)
        #expect(env.reopenCalls.isEmpty)
    }

    @Test func missingHomebrewDoesNotRunAnything() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        let (model, _) = makeModel(brew, isBrewAvailable: { false })

        await model.check(refresh: true)

        #expect(model.brewMissing)
        #expect(model.phase == .idle)
        #expect(brew.invocations.isEmpty)
    }

    @Test func firstManualRefreshUpdatesIndexButNewListFailsShowsFreshnessWithoutOldList() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        try brew.setOutdatedAfter(oneCaskOutdated)
        try brew.setIndexAge(hours: 1)
        brew.outdatedAfterStatus = 1
        try brew.setOutdatedError("cannot read the new list")
        let (model, _) = makeModel(brew)

        await model.check(refresh: true)

        #expect(model.lastChecked == nil)
        #expect(model.casks.isEmpty)
        #expect(model.failure == "cannot read the new list")
        #expect(model.refreshFailure == nil)
        #expect(model.indexRefreshed)
        #expect(model.indexRefreshedAt != nil)
        #expect(model.selectedCasks.isEmpty)
        #expect(model.showsFreshnessWithoutSummary,
                "a successful index update with no readable list must still show the refresh result")
        #expect(brew.count("info") == 0, "details are not read when the refreshed list failed")
    }

    @Test func firstManualRefreshWithUpdateAndListFailuresShowsErrorState() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setIndexAge(hours: 1)
        brew.updateStatus = 1
        try brew.setUpdateError("offline")
        brew.outdatedStatus = 1
        try brew.setOutdatedError("cannot list")
        let (model, _) = makeModel(brew)

        await model.check(refresh: true)

        #expect(model.lastChecked == nil)
        #expect(model.casks.isEmpty)
        #expect(model.failure == "cannot list")
        #expect(model.refreshFailure == "offline")
        #expect(!model.indexRefreshed)
        #expect(model.showsFreshnessWithoutSummary,
                "the refresh failure must still be visible when the first list cannot be read")
    }

    @Test func ordinaryFirstOutdatedFailureWithoutUpdateShowsNoRefreshIndicator() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setIndexAge(hours: 1)
        brew.outdatedStatus = 1
        try brew.setOutdatedError("network is down")
        let (model, _) = makeModel(brew)

        await model.check()

        #expect(model.lastChecked == nil)
        #expect(model.casks.isEmpty)
        #expect(model.failure == "network is down")
        #expect(!model.indexRefreshed)
        #expect(model.refreshFailure == nil)
        #expect(model.refreshWarning == nil)
        #expect(!model.showsFreshnessWithoutSummary,
                "a plain list failure must not claim that the index was refreshed")
        #expect(brew.count("update") == 0)
    }

    @Test func oldResultWithRefreshThenListFailureDoesNotShowExtraFreshnessBlock() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(oneCaskOutdated)
        try brew.setInfo(oneCaskInfo)
        try brew.setIndexAge(hours: 1)
        let (model, _) = makeModel(brew)

        await model.check(refresh: true)
        #expect(model.lastChecked != nil)
        #expect(model.casks.map(\.token) == ["obs"])

        try brew.setOutdatedAfter(oneCaskOutdated)
        try brew.setInfoAfter(oneCaskPkgInfo)
        brew.outdatedAfterStatus = 1
        try brew.setOutdatedError("the list could not be read")

        await model.check(refresh: true)

        #expect(model.lastChecked != nil, "the previous list remains the summarized result")
        #expect(model.failure == "the list could not be read")
        #expect(model.indexRefreshed)
        #expect(model.indexRefreshedAt != nil)
        #expect(!model.showsFreshnessWithoutSummary,
                "the summary already contains freshness for an existing result")
        #expect(model.detailNotice == .notReconfirmedAfterRefresh)
        #expect(model.unconfirmed == ["obs"])
    }
}

@Suite struct UpdatesFreshnessTests {
    @Test func relativeTextChangesAfterTheIndexWindow() {
        let index = Date(timeIntervalSince1970: 1_700_000_000)
        let english = Locale(identifier: "en_US")
        let atCheck = UpdatesFreshness.relative(index, to: index, locale: english)
        let nextDay = UpdatesFreshness.relative(index, to: index.addingTimeInterval(25 * 3600),
                                                locale: english)
        #expect(atCheck != nextDay, "a fixed string would keep saying 'now' after a day")
        #expect(!nextDay.localizedCaseInsensitiveContains("now"))
        #expect(nextDay.localizedCaseInsensitiveContains("day"),
                "the view must name the old day instead of a fresh time")
    }
}
