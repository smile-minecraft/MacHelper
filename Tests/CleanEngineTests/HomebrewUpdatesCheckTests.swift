import Foundation
import Testing
@testable import CleanEngine

private let outdatedFixture = #"{"formulae":[],"casks":[{"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false},{"name":"gstreamer-runtime","installed_versions":["1.28.3"],"current_version":"1.28.6","pinned":true}]}"#

private let infoFixture = #"{"casks":[{"token":"obs","name":["OBS"],"auto_updates":true,"artifacts":[{"app":["OBS.app"]}]},{"token":"gstreamer-runtime","name":["GStreamer runtime package"],"auto_updates":null,"artifacts":[{"pkg":["gstreamer.pkg"]}]}]}"#

private let infoAfterFixture = #"{"casks":[{"token":"obs","name":["OBS Studio"],"auto_updates":false,"artifacts":[{"pkg":["OBS.pkg"]}]},{"token":"gstreamer-runtime","name":["GStreamer runtime package"],"auto_updates":null,"artifacts":[{"pkg":["gstreamer.pkg"]}]}]}"#

/// A fake `brew` that logs its arguments and can be told how long each subcommand takes.
/// The tests never run the user's Homebrew; every command goes through this executable.
/// A successful `update` leaves a marker, after which `outdated` and `info` answer with the
/// "after" files, so a test can simulate a catalog refresh that changed a cask definition.
private final class FakeBrew {
    let executable: URL
    let log: URL
    let repository: URL
    let outdatedJSON: URL
    let infoJSON: URL
    let outdatedAfterJSON: URL
    let infoAfterJSON: URL
    private let outdatedErr: URL
    private let infoErr: URL
    private let updateErr: URL
    private let updateWarning: URL
    private let updatedMarker: URL
    let infoStarted: URL
    let infoRelease: URL

    var outdatedDelay: Double = 0 { didSet { rewrite() } }
    var autoUpdateDelay: Double = 0 { didSet { rewrite() } }
    var infoDelay: Double = 0 { didSet { rewrite() } }
    var updateDelay: Double = 0 { didSet { rewrite() } }
    var outdatedStatus: Int = 0 { didSet { rewrite() } }
    var outdatedAfterStatus: Int = 0 { didSet { rewrite() } }
    var infoStatus: Int = 0 { didSet { rewrite() } }
    var updateStatus: Int = 0 { didSet { rewrite() } }
    /// Simulates a failed `brew update` that already wrote part of the catalog.
    var partialUpdate = false { didSet { rewrite() } }
    /// When true, `brew info` announces that it started and waits for `releaseInfo()`.
    var infoGate = false { didSet { rewrite() } }

    init(root: URL) throws {
        executable = root.appending(path: "bin/brew")
        log = root.appending(path: "brew.log")
        repository = root.appending(path: "repo")
        outdatedJSON = root.appending(path: "outdated.json")
        infoJSON = root.appending(path: "info.json")
        outdatedAfterJSON = root.appending(path: "outdated-after.json")
        infoAfterJSON = root.appending(path: "info-after.json")
        outdatedErr = root.appending(path: "outdated.err")
        infoErr = root.appending(path: "info.err")
        updateErr = root.appending(path: "update.err")
        updateWarning = root.appending(path: "update.warning")
        updatedMarker = root.appending(path: "updated")
        infoStarted = root.appending(path: "info-started")
        infoRelease = root.appending(path: "info-release")

        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"),
                                                withIntermediateDirectories: true)
        for file in [log, outdatedJSON, infoJSON, outdatedErr, infoErr, updateErr, updateWarning] {
            try Data().write(to: file)
        }
        try Data().write(to: repository.appending(path: ".git/FETCH_HEAD"))
        try writeScript()
    }

    func setOutdated(_ json: String) throws { try Data(json.utf8).write(to: outdatedJSON) }
    func setInfo(_ json: String) throws { try Data(json.utf8).write(to: infoJSON) }
    func setOutdatedAfter(_ json: String) throws { try Data(json.utf8).write(to: outdatedAfterJSON) }
    func setInfoAfter(_ json: String) throws { try Data(json.utf8).write(to: infoAfterJSON) }
    func setOutdatedError(_ text: String) throws { try Data(text.utf8).write(to: outdatedErr) }
    func setInfoError(_ text: String) throws { try Data(text.utf8).write(to: infoErr) }
    func setUpdateError(_ text: String) throws { try Data(text.utf8).write(to: updateErr) }
    func setUpdateWarning(_ text: String) throws { try Data(text.utf8).write(to: updateWarning) }

    func resetUpdateMarker() { try? FileManager.default.removeItem(at: updatedMarker) }

    func releaseInfo() { try? Data().write(to: infoRelease) }

    func resetInfoGate() {
        try? FileManager.default.removeItem(at: infoStarted)
        try? FileManager.default.removeItem(at: infoRelease)
    }

    /// Waits until the fake `brew info` has announced that it started and is blocked on the gate.
    func waitForInfoToStart(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: infoStarted.path) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Moves Homebrew's FETCH_HEAD so the catalog looks older (or newer) than its auto-update window.
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

    private func rewrite() {
        try? writeScript()
    }

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
            sleep \(autoUpdateDelay)
            sleep \(outdatedDelay)
          fi
          if [ -f '\(updatedMarker.path)' ] && [ -f '\(outdatedAfterJSON.path)' ]; then
            cat '\(outdatedAfterJSON.path)'
            cat '\(outdatedErr.path)' >&2
            exit \(outdatedAfterStatus)
          else
            cat '\(outdatedJSON.path)'
            cat '\(outdatedErr.path)' >&2
            exit \(outdatedStatus)
          fi
          ;;
        info)
          if [ \(infoGate ? 1 : 0) -eq 1 ]; then
            : > '\(infoStarted.path)'
            i=0
            while [ ! -f '\(infoRelease.path)' ] && [ $i -lt 1000 ]; do
              sleep 0.01
              i=$((i + 1))
            done
          fi
          sleep \(infoDelay)
          if [ -f '\(updatedMarker.path)' ] && [ -f '\(infoAfterJSON.path)' ]; then
            cat '\(infoAfterJSON.path)'
          else
            cat '\(infoJSON.path)'
          fi
          cat '\(infoErr.path)' >&2
          exit \(infoStatus)
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

private func check(_ brew: FakeBrew, greedy: Bool = false, autoUpdate: Bool = false,
                   excludingAppBundleNames: Set<String> = [], excludingTokens: Set<String> = [])
    -> Result<HomebrewUpdates.OutdatedCheck, HomebrewUpdates.Failure> {
    HomebrewUpdates.check(greedy: greedy, autoUpdate: autoUpdate,
                          excludingAppBundleNames: excludingAppBundleNames,
                          excludingTokens: excludingTokens,
                          brew: brew.executable.path, repository: brew.repository)
}

private func snapshots(_ stream: AsyncStream<HomebrewUpdateSession.Snapshot>)
    async -> [HomebrewUpdateSession.Snapshot] {
    var out: [HomebrewUpdateSession.Snapshot] = []
    for await snapshot in stream { out.append(snapshot) }
    return out
}

@Suite(.serialized) struct HomebrewUpdatesCheckTests {
    @Test func detailsAreFetchedOnEveryCheckAndFollowDefinitionChanges() throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        try brew.setIndexAge(hours: 1)

        let first = try check(brew).get()
        #expect(first.casks.first { $0.token == "obs" }?.name == "OBS")
        #expect(first.casks.first { $0.token == "obs" }?.needsAdmin == false)
        #expect(first.casks.first { $0.token == "obs" }?.appNames == ["OBS.app"])
        #expect(brew.count("info") == 1)

        // Same token, same versions, changed definition: the app must not reuse the old details.
        try brew.setInfo(infoAfterFixture)
        let second = try check(brew).get()
        #expect(second.casks.first { $0.token == "obs" }?.name == "OBS Studio")
        #expect(second.casks.first { $0.token == "obs" }?.needsAdmin == true)
        #expect(second.casks.first { $0.token == "obs" }?.appNames == [])
        #expect(brew.count("info") == 2, "details must be read again; a token is not a freshness proof")
        #expect(brew.count("outdated") == 2)
        #expect(brew.count("update") == 0)
    }

    @Test func infoFailureMarksRowsUnconfirmedInsteadOfSafe() throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        brew.infoStatus = 1
        try brew.setInfoError("Could not load cask metadata")

        let result = try check(brew).get()
        #expect(result.unconfirmedTokens == ["obs", "gstreamer-runtime"])
        #expect(result.detailsFailure?.contains("Could not load cask metadata") == true)
        #expect(result.casks.first { $0.token == "obs" }?.name == "obs")
        #expect(result.casks.first { $0.token == "obs" }?.needsAdmin == false,
                "the placeholder flag stays false, but unconfirmedTokens marks it as unknown")
    }

    @Test func tokenExclusionStillWorksWhenDetailsAreUnavailable() throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        let ownToken = HomebrewUpdates.appCaskToken
        try brew.setOutdated("""
        {"formulae":[],"casks":[
          {"name":"\(ownToken)","installed_versions":["0.3.0"],"current_version":"0.3.2","pinned":false},
          {"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false}
        ]}
        """)
        brew.infoStatus = 1
        try brew.setInfoError("Could not load cask metadata")

        let result = try check(brew, excludingTokens: [ownToken]).get()
        #expect(result.casks.map(\.token) == ["obs"])
        #expect(result.unconfirmedTokens == ["obs"], "the excluded cask must not stay unconfirmed")
    }

    @Test func outdatedFailureIsReported() throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        brew.outdatedStatus = 1
        try brew.setOutdatedError("network is down")

        switch check(brew) {
        case .success:
            Issue.record("a failed brew outdated must not look like a successful check")
        case .failure(.failed(let message)):
            #expect(message == "network is down")
        case .failure(.notInstalled):
            Issue.record("the fake brew is installed")
        }
    }

    @Test func emptyCatalogIsSuccessAndSkipsInfo() throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(#"{"formulae":[],"casks":[]}"#)
        let result = try check(brew).get()

        #expect(result.casks.isEmpty)
        #expect(result.unconfirmedTokens.isEmpty)
        #expect(result.detailsFailure == nil)
        #expect(brew.count("info") == 0)
    }

    @Test func selfPinnedAndAdminFlagsArePreserved() throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        let ownToken = HomebrewUpdates.appCaskToken
        try brew.setOutdated("""
        {"formulae":[],"casks":[
          {"name":"\(ownToken)","installed_versions":["0.3.0"],"current_version":"0.3.2","pinned":false},
          {"name":"own-cask","installed_versions":["1.0"],"current_version":"2.0","pinned":false},
          {"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false},
          {"name":"gstreamer-runtime","installed_versions":["1.28.3"],"current_version":"1.28.6","pinned":true},
          {"name":"-rf","installed_versions":["1"],"current_version":"2","pinned":false}
        ]}
        """)
        try brew.setInfo("""
        {"casks":[
          {"token":"\(ownToken)","name":["MacHelper"],"artifacts":[{"app":["MacHelper.app"]}]},
          {"token":"own-cask","name":["MacHelper"],"artifacts":[{"app":["MacHelper.app"]}]},
          {"token":"obs","name":["OBS"],"auto_updates":true,"artifacts":[{"app":["OBS.app"]}]},
          {"token":"gstreamer-runtime","name":["GStreamer runtime package"],"artifacts":[{"pkg":["gstreamer.pkg"]}]}
        ]}
        """)

        let result = try check(brew, excludingAppBundleNames: ["MacHelper.app"],
                               excludingTokens: [ownToken]).get()
        #expect(Set(result.casks.map(\.token)) == ["obs", "gstreamer-runtime"])
        #expect(result.casks.first { $0.token == "obs" }?.autoUpdates == true)
        #expect(result.casks.first { $0.token == "gstreamer-runtime" }?.pinned == true)
        #expect(result.casks.first { $0.token == "gstreamer-runtime" }?.needsAdmin == true)
        #expect(!brew.invocations.contains { $0.contains("-rf") }, "invalid tokens never reach brew")
    }

    @Test func greedyPassesTheFlagAndIndexTimeComesFromFetchHead() throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        try brew.setIndexAge(hours: 5)

        let result = try check(brew, greedy: true).get()
        #expect(brew.invocations.contains { $0.contains("--greedy") })
        let age = try #require(result.indexUpdatedAt.map { Date().timeIntervalSince($0) })
        #expect(age > 4.9 * 3600 && age < 5.1 * 3600)
    }

    @Test func repositoryPathAsksACustomBrew() throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        #expect(HomebrewUpdates.repositoryPath(for: brew.executable.path, environment: [:])?.path
                == brew.repository.path)
        #expect(brew.invocations.contains("--repository"))
    }

    @Test func onlyTheCachedFallbackWarningChangesWhatTheUpdateMeans() {
        #expect(HomebrewUpdates.cachedFallbackWarning("Warning: Your Xcode is outdated.\n") == nil)
        let fallback = "Warning: cask.jws.json: update failed, falling back to cached version."
        #expect(HomebrewUpdates.cachedFallbackWarning("Warning: Xcode\n" + fallback)?
            .contains("falling back to cached version") == true)
    }

    @Test func missingBrewWithRefreshIsRejectedBeforeAnyProcessRuns() {
        // `.missing` has no executable path at all. The decision layer returns before refreshIndex
        // is called, so this cannot fall back to the machine's Homebrew.
        let result = HomebrewUpdates.outdated(greedy: false, refresh: true,
                                              excludingAppBundleNames: [], excludingTokens: [],
                                              dependency: .missing)
        switch result {
        case .failure(.notInstalled):
            break
        case .failure(.failed(let message)):
            Issue.record("a missing brew must not run: \(message)")
        case .success:
            Issue.record("a missing brew cannot produce a list")
        }
    }
}

@Suite struct UpdatesHeadlineTests {
    private let index = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func allUpToDateNeedsACleanRefreshAndAFreshIndex() {
        #expect(UpdatesHeadline.make(hasResult: true, casks: [], indexRefreshed: true,
                                     isIndexStale: false, refreshFailure: nil, refreshWarning: nil,
                                     checkFailed: false, indexUpdatedAt: index) == .allUpToDate)

        // A fresh FETCH_HEAD without an actual refresh is not proof that Homebrew's API cache is
        // fresh; Homebrew falls back to a cached API file when a download fails.
        #expect(UpdatesHeadline.make(hasResult: true, casks: [], indexRefreshed: false,
                                     isIndexStale: false, refreshFailure: nil, refreshWarning: nil,
                                     checkFailed: false, indexUpdatedAt: index)
                == .noUpdates(indexUpdatedAt: index))

        // A successful update that warned about a cached fallback did not fully re-download.
        #expect(UpdatesHeadline.make(hasResult: true, casks: [], indexRefreshed: true,
                                     isIndexStale: false, refreshFailure: nil,
                                     refreshWarning: "Warning: cask.jws.json: update failed, falling back to cached version.",
                                     checkFailed: false, indexUpdatedAt: index)
                == .noUpdates(indexUpdatedAt: index))

        // The app may stay open past the 24-hour window after a refresh.
        #expect(UpdatesHeadline.make(hasResult: true, casks: [], indexRefreshed: true,
                                     isIndexStale: true, refreshFailure: nil, refreshWarning: nil,
                                     checkFailed: false, indexUpdatedAt: index)
                == .noUpdates(indexUpdatedAt: index))

        // A failed list read must not become "all up to date" just because the refresh succeeded.
        #expect(UpdatesHeadline.make(hasResult: true, casks: [], indexRefreshed: true,
                                     isIndexStale: false, refreshFailure: nil, refreshWarning: nil,
                                     checkFailed: true, indexUpdatedAt: index)
                == .noUpdates(indexUpdatedAt: index))
    }

    @Test func aKnownListIsStillShownWhenTheLatestReadFailed() {
        let cask = OutdatedCask(token: "obs", name: "OBS", installedVersion: "1", currentVersion: "2",
                                pinned: false, autoUpdates: false, appNames: ["OBS.app"], needsAdmin: false)
        #expect(UpdatesHeadline.make(hasResult: true, casks: [cask], indexRefreshed: true,
                                     isIndexStale: false, refreshFailure: nil, refreshWarning: nil,
                                     checkFailed: true, indexUpdatedAt: index) == .updates(1))
    }
}

@Suite(.serialized) struct HomebrewUpdateSessionTests {
    @Test func staleIndexYieldsTheFirstListThenVerifiesTheRefreshedDefinition() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        try brew.setOutdatedAfter(outdatedFixture)
        try brew.setInfoAfter(infoAfterFixture)
        try brew.setIndexAge(hours: 48)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        #expect(all.count == 2)
        #expect(all[0].detailsPending && all[0].willRefresh && !all[0].isFinal)
        #expect(all[0].unconfirmedTokens == ["obs", "gstreamer-runtime"])
        #expect(all[0].casks.first { $0.token == "obs" }?.name == "obs")
        #expect(all[1].isFinal && all[1].indexRefreshed && !all[1].detailsPending)
        #expect(all[1].casks.first { $0.token == "obs" }?.name == "OBS Studio")
        #expect(all[1].casks.first { $0.token == "obs" }?.needsAdmin == true)
        #expect(all[1].casks.first { $0.token == "obs" }?.appNames == [])
        #expect(brew.invocations == ["outdated --cask --json=v2", "update --quiet",
                                     "outdated --cask --json=v2", "info --cask --json=v2 obs gstreamer-runtime"])
        #expect(brew.count("info") == 1, "details are read once, from the refreshed catalog")
    }

    @Test func refreshFailureKeepsTheExistingListAndItsDetails() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        brew.updateStatus = 1
        try brew.setUpdateError("offline")
        try brew.setIndexAge(hours: 48)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        #expect(all.count == 2)
        #expect(all[1].isFinal && !all[1].indexRefreshed)
        #expect(all[1].refreshAttempted, "a failed update is still an attempted refresh")
        #expect(all[1].refreshFailure == "offline")
        #expect(all[1].casks.first { $0.token == "obs" }?.name == "OBS")
        #expect(all[1].casks.first { $0.token == "obs" }?.needsAdmin == false)
        #expect(brew.count("info") == 1)
    }

    @Test func refreshWarningIsReportedWithoutFailingTheUpdate() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        try brew.setUpdateWarning("update failed, falling back to cached version.")
        try brew.setIndexAge(hours: 48)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        #expect(all[1].isFinal && all[1].indexRefreshed)
        #expect(all[1].refreshFailure == nil)
        #expect(all[1].refreshWarning?.contains("falling back to cached version") == true)
    }

    @Test func refreshSuccessWithInfoFailureDoesNotAssumeNoAdmin() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        brew.infoStatus = 1
        try brew.setInfoError("Could not load cask metadata")
        try brew.setIndexAge(hours: 48)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        #expect(all.count == 2)
        #expect(all[1].isFinal && all[1].indexRefreshed)
        #expect(all[1].detailsFailure?.contains("Could not load cask metadata") == true)
        #expect(all[1].unconfirmedTokens == ["obs", "gstreamer-runtime"])
        #expect(all[1].casks.allSatisfy { !$0.needsAdmin },
                "the placeholder flag is false, but every row is unconfirmed")
    }

    @Test func refreshedDetailsExcludeTheAppBundleTheCaskNowInstalls() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated("""
        {"formulae":[],"casks":[
          {"name":"own-cask","installed_versions":["1.0"],"current_version":"2.0","pinned":false},
          {"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false}
        ]}
        """)
        try brew.setInfo("""
        {"casks":[
          {"token":"own-cask","name":["Own"],"artifacts":[{"app":["Other.app"]}]},
          {"token":"obs","name":["OBS"],"artifacts":[{"app":["OBS.app"]}]}
        ]}
        """)
        try brew.setOutdatedAfter("""
        {"formulae":[],"casks":[
          {"name":"own-cask","installed_versions":["1.0"],"current_version":"2.0","pinned":false},
          {"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false}
        ]}
        """)
        try brew.setInfoAfter("""
        {"casks":[
          {"token":"own-cask","name":["Own"],"artifacts":[{"app":["MacHelper.app"]}]},
          {"token":"obs","name":["OBS"],"artifacts":[{"app":["OBS.app"]}]}
        ]}
        """)
        try brew.setIndexAge(hours: 48)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let stream = try #require(await session.check(greedy: false, refresh: false,
                                                      excludingAppBundleNames: ["MacHelper.app"]))
        let all = await snapshots(stream)

        #expect(Set(all[0].casks.map(\.token)) == ["own-cask", "obs"])
        #expect(Set(all[1].casks.map(\.token)) == ["obs"],
                "the refreshed definition installs MacHelper.app, so it must disappear")
    }

    @Test func freshIndexYieldsTheProvisionalListThenTheDetails() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        try brew.setIndexAge(hours: 1)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        #expect(all.count == 2)
        #expect(all[0].detailsPending && !all[0].willRefresh && !all[0].isFinal)
        #expect(all[0].unconfirmedTokens == ["obs", "gstreamer-runtime"])
        #expect(all[1].isFinal && !all[1].detailsPending && !all[1].indexRefreshed)
        #expect(all[1].unconfirmedTokens.isEmpty)
        #expect(brew.count("update") == 0)
        #expect(brew.count("outdated") == 1)
        #expect(brew.count("info") == 1)
    }

    @Test func emptyFreshListFinishesWithoutInfo() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(#"{"formulae":[],"casks":[]}"#)
        try brew.setIndexAge(hours: 1)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        #expect(all.count == 1)
        #expect(all[0].isFinal && !all[0].detailsPending)
        #expect(all[0].casks.isEmpty)
        #expect(brew.count("info") == 0)
        #expect(brew.count("update") == 0)
    }

    @Test func repeatedTriggerWhileRunningIsIgnored() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        try brew.setIndexAge(hours: 1)
        brew.outdatedDelay = 0.4
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let first = await session.check(greedy: false, refresh: false)
        let second = await session.check(greedy: false, refresh: false)
        #expect(first != nil)
        #expect(second == nil, "a second check must not start another brew process")
        if let first { for await _ in first {} }

        let third = await session.check(greedy: false, refresh: false)
        #expect(third != nil)
        if let third { for await _ in third {} }
        #expect(brew.count("outdated") == 2)
    }

    @Test func waitUntilIdleWaitsForTheRunningCheck() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        try brew.setIndexAge(hours: 1)
        brew.outdatedDelay = 0.4
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let first = try #require(await session.check(greedy: false, refresh: false))
        let start = Date()
        await session.waitUntilIdle()
        #expect(Date().timeIntervalSince(start) > 0.2)
        for await _ in first {}
        let next = await session.check(greedy: false, refresh: false)
        #expect(next != nil)
        if let next { for await _ in next {} }
    }

    @Test func explicitRefreshReportsFailureAndKeepsTheList() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        brew.updateStatus = 1
        try brew.setUpdateError("offline")
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let stream = try #require(await session.check(greedy: false, refresh: true))
        let all = await snapshots(stream)

        #expect(all.count == 2)
        #expect(all[0].detailsPending && !all[0].willRefresh)
        #expect(all[1].isFinal)
        #expect(all[1].refreshFailure == "offline")
        #expect(!all[1].indexRefreshed)
        #expect(all[1].refreshAttempted)
        #expect(!all[1].casks.isEmpty)
        #expect(brew.invocations.first == "update --quiet")
    }

    @Test func explicitRefreshSuccessMarksTheIndexRefreshed() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let stream = try #require(await session.check(greedy: false, refresh: true))
        let all = await snapshots(stream)

        #expect(all.count == 2)
        #expect(all[0].detailsPending && all[0].indexRefreshed)
        #expect(all[1].isFinal && all[1].indexRefreshed && all[1].refreshFailure == nil)
        #expect(brew.invocations.first == "update --quiet")
        #expect(brew.count("info") == 1)
    }

    @Test func explicitRefreshSuccessThenListFailureReportsTheRefresh() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        brew.outdatedStatus = 1
        try brew.setOutdatedError("the list could not be read")
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let stream = try #require(await session.check(greedy: false, refresh: true))
        let all = await snapshots(stream)

        #expect(all.count == 1)
        #expect(all[0].isFinal)
        #expect(all[0].failure == "the list could not be read")
        #expect(all[0].indexRefreshed,
                "a successful update must still be reported when the new list cannot be read")
        #expect(all[0].indexUpdatedAt != nil, "the refreshed FETCH_HEAD time is available")
        #expect(brew.invocations.first == "update --quiet")
        #expect(brew.count("info") == 0)
    }

    @Test func automaticRefreshSuccessThenListFailureReportsTheRefresh() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        try brew.setOutdatedAfter(outdatedFixture)
        try brew.setIndexAge(hours: 48)
        brew.outdatedAfterStatus = 1
        try brew.setOutdatedError("network is down")
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        #expect(all.count == 2)
        #expect(all[0].detailsPending && all[0].willRefresh)
        #expect(all[1].isFinal)
        #expect(all[1].failure == "network is down")
        #expect(all[1].indexRefreshed,
                "the background refresh succeeded before the second list failed")
        #expect(all[1].casks.isEmpty)
        #expect(brew.count("update") == 1)
        #expect(brew.count("info") == 0, "no details are read for a list that failed")
    }

    @Test func failedUpdateThatMayHaveWrittenDoesNotClaimRefreshOrKeepOldRows() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        try brew.setOutdatedAfter(outdatedFixture)
        try brew.setIndexAge(hours: 48)
        brew.partialUpdate = true
        brew.updateStatus = 1
        try brew.setUpdateError("update failed after writing")
        brew.outdatedAfterStatus = 1
        try brew.setOutdatedError("the list could not be read")
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        #expect(all.count == 2)
        #expect(all[0].detailsPending && all[0].willRefresh)
        #expect(all[1].isFinal)
        #expect(all[1].failure == "the list could not be read")
        #expect(all[1].refreshFailure == "update failed after writing")
        #expect(!all[1].indexRefreshed, "a failed update must not be reported as a refresh")
        #expect(all[1].refreshAttempted, "the failed update may still have written data")
        #expect(all[1].casks.isEmpty)
    }
}

/// Same fake brew and the same synthetic delays for every path. This measures where the time goes,
/// not Homebrew's real speed. `brew info` waits at a gate, so the test proves causally that the
/// provisional list arrives before the details finish instead of relying on a small timing margin.
/// Enabled explicitly:
///   MACHELPER_PERF_TEST=1 swift test --filter firstResultArrivesBeforeTheRefreshFinishes
@Suite struct HomebrewUpdatesPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACHELPER_PERF_TEST"] == "1"))
    func firstResultArrivesBeforeTheRefreshFinishes() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        try brew.setOutdated(outdatedFixture)
        try brew.setInfo(infoFixture)
        try brew.setOutdatedAfter(outdatedFixture)
        try brew.setInfoAfter(infoFixture)
        // Synthetic delays, in seconds. The gate, not these numbers, proves the ordering; the
        // delays only separate the phases for the printed comparison.
        brew.outdatedDelay = 0.3
        brew.autoUpdateDelay = 1.0
        brew.infoDelay = 0.8
        brew.updateDelay = 1.0

        var oldStale: [Double] = []
        var firstStale: [Double] = []
        var completeStale: [Double] = []
        var oldFresh: [Double] = []
        var firstFresh: [Double] = []
        var completeFresh: [Double] = []

        for _ in 0..<3 {
            // Stale index, old blocking path: waits for Homebrew's auto-update, outdated, and info.
            // It runs synchronously; the causal gate is only needed for the new provisional result.
            brew.infoGate = false
            brew.resetUpdateMarker()
            try brew.setIndexAge(hours: 48)
            brew.autoUpdateDelay = 1.0
            let oldStart = Date()
            _ = try check(brew, autoUpdate: true).get()
            oldStale.append(Date().timeIntervalSince(oldStart))

            // Stale index, new path: the first snapshot must arrive while info is still blocked.
            brew.infoGate = true
            brew.resetUpdateMarker()
            brew.resetInfoGate()
            let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)
            let stream = try #require(await session.check(greedy: false, refresh: false))
            let sessionStart = Date()
            var times: [Double] = []
            var released = false
            for await snapshot in stream {
                if times.isEmpty {
                    times.append(Date().timeIntervalSince(sessionStart))
                    #expect(snapshot.detailsPending, "the first snapshot must be provisional")
                    #expect(!released, "the first snapshot must arrive before info is released")
                    let reachedInfo = await brew.waitForInfoToStart()
                    #expect(reachedInfo, "the provisional list must lead to brew info")
                    brew.releaseInfo()
                    released = true
                } else {
                    times.append(Date().timeIntervalSince(sessionStart))
                    #expect(!snapshot.detailsPending, "the final snapshot must have details")
                }
            }
            #expect(times.count == 2)
            firstStale.append(times[0])
            completeStale.append(times[1])

            // Fresh index, old blocking path: Homebrew skips its auto-update, but the old path still
            // waits for outdated and info before it can show anything.
            brew.infoGate = false
            brew.resetUpdateMarker()
            try brew.setIndexAge(hours: 1)
            brew.autoUpdateDelay = 0
            let freshOldStart = Date()
            _ = try check(brew, autoUpdate: true).get()
            oldFresh.append(Date().timeIntervalSince(freshOldStart))

            // Fresh index, new path: the same causal check as the stale case.
            brew.infoGate = true
            brew.resetUpdateMarker()
            brew.resetInfoGate()
            let freshSession = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository)
            let freshStream = try #require(await freshSession.check(greedy: false, refresh: false))
            let freshStart = Date()
            var freshTimes: [Double] = []
            var freshReleased = false
            for await snapshot in freshStream {
                if freshTimes.isEmpty {
                    freshTimes.append(Date().timeIntervalSince(freshStart))
                    #expect(snapshot.detailsPending)
                    #expect(!freshReleased)
                    let reachedInfo = await brew.waitForInfoToStart()
                    #expect(reachedInfo)
                    brew.releaseInfo()
                    freshReleased = true
                } else {
                    freshTimes.append(Date().timeIntervalSince(freshStart))
                    #expect(!snapshot.detailsPending)
                }
            }
            #expect(freshTimes.count == 2)
            firstFresh.append(freshTimes[0])
            completeFresh.append(freshTimes[1])
        }

        let mean = { (v: [Double]) in v.reduce(0, +) / Double(v.count) }
        print("Homebrew update check (fake brew, synthetic delays; not real Homebrew): " +
              "old blocking path, stale index mean \(String(format: "%.2f", mean(oldStale)))s; " +
              "new first result, stale index mean \(String(format: "%.2f", mean(firstStale)))s; " +
              "new complete, stale index mean \(String(format: "%.2f", mean(completeStale)))s; " +
              "old complete, fresh index mean \(String(format: "%.2f", mean(oldFresh)))s; " +
              "new first result, fresh index mean \(String(format: "%.2f", mean(firstFresh)))s; " +
              "new complete, fresh index mean \(String(format: "%.2f", mean(completeFresh)))s")
        // The gate proves the ordering; these means only guard against a future change that stops
        // showing the first result early. The synthetic delays leave at least 0.8s between means.
        #expect(mean(firstStale) < mean(oldStale) - 0.5,
                "the first list must arrive before the old blocking path finishes")
        #expect(mean(completeStale) > mean(firstStale) + 0.5,
                "the complete refreshed result must be later than the first result")
        #expect(mean(firstFresh) < mean(oldFresh) - 0.5,
                "a fresh index must show its unconfirmed list before the old path finishes")
        #expect(mean(firstFresh) < mean(completeFresh) - 0.5,
                "the fresh first result must arrive before the confirmed details")
        #expect(mean(completeFresh) <= mean(oldFresh) + 0.3,
                "a fresh index does the same outdated + info work as before; no material regression")
        #expect(brew.count("update") == 3)
        #expect(brew.count("outdated") == 15)
        #expect(brew.count("info") == 12)
    }
}
