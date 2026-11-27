import Foundation
import Testing
@testable import CleanEngine

private let outdatedFixture = #"{"formulae":[],"casks":[{"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false},{"name":"gstreamer-runtime","installed_versions":["1.28.3"],"current_version":"1.28.6","pinned":true}]}"#

private let infoFixture = #"{"casks":[{"token":"obs","name":["OBS"],"auto_updates":true,"artifacts":[{"app":["OBS.app"]}]},{"token":"gstreamer-runtime","name":["GStreamer runtime package"],"auto_updates":null,"artifacts":[{"pkg":["gstreamer.pkg"]}]}]}"#

private let infoAfterFixture = #"{"casks":[{"token":"obs","name":["OBS Studio"],"auto_updates":false,"artifacts":[{"pkg":["OBS.pkg"]}]},{"token":"gstreamer-runtime","name":["GStreamer runtime package"],"auto_updates":null,"artifacts":[{"pkg":["gstreamer.pkg"]}]}]}"#

/// A fake `brew` that answers from memory and records its arguments. No test starts a process or
/// waits on a pipe, so a check cannot be slowed down or timed out by what else the machine is
/// doing. A gate can hold `outdated` or `info` open while a test observes what the session does.
private final class FakeBrew: @unchecked Sendable {
    let executable = URL(fileURLWithPath: "/fake/homebrew/bin/brew")
    let repository: URL
    /// Signalled when a gated `info` starts waiting.
    private let infoStarted = DispatchSemaphore(value: 0)
    /// Signalled when a gated `update` starts waiting.
    private let updateStarted = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var log: [String] = []
    private var outdatedJSON = ""
    private var infoJSON = ""
    private var outdatedAfterJSON = ""
    private var infoAfterJSON = ""
    private var outdatedError = ""
    private var infoError = ""
    private var updateError = ""
    private var updateWarning = ""
    private var updated = false

    /// When set, `brew outdated` waits for it before answering.
    var outdatedGate: DispatchSemaphore?
    /// When set, `brew info` signals `infoStarted` and then waits for it.
    var infoGate: DispatchSemaphore?
    /// When set, `brew update` signals `updateStarted` and then waits for it.
    var updateGate: DispatchSemaphore?

    var outdatedStatus = 0
    var outdatedAfterStatus = 0
    var infoStatus = 0
    var updateStatus = 0
    /// Simulates a failed `brew update` that already wrote part of the catalog.
    var partialUpdate = false
    /// Kills `brew outdated` with this signal before it prints anything.
    var outdatedSignal: Int32?

    /// The runner to hand to a check or a session. It answers from memory; nothing is executed.
    var runner: HomebrewUpdates.HomebrewCommandRunner {
        HomebrewUpdates.HomebrewCommandRunner { [self] _, args, _, _ in run(args) }
    }

    init(root: URL) throws {
        repository = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"),
                                                withIntermediateDirectories: true)
        try Data().write(to: repository.appending(path: ".git/FETCH_HEAD"))
    }

    func setOutdated(_ json: String) { outdatedJSON = json }
    func setInfo(_ json: String) { infoJSON = json }
    func setOutdatedAfter(_ json: String) { outdatedAfterJSON = json }
    func setInfoAfter(_ json: String) { infoAfterJSON = json }
    func setOutdatedError(_ text: String) { outdatedError = text }
    func setInfoError(_ text: String) { infoError = text }
    func setUpdateError(_ text: String) { updateError = text }
    func setUpdateWarning(_ text: String) { updateWarning = text }

    func resetUpdateMarker() { updated = false }

    /// Waits until a gated `info` has announced that it started and is blocked on the gate.
    func waitForInfoToStart(timeout: TimeInterval = 2) async -> Bool {
        await awaitSignal(infoStarted, timeout: timeout)
    }

    /// Waits until a gated `update` has announced that it started and is blocked on the gate.
    func waitForUpdateToStart(timeout: TimeInterval = 2) async -> Bool {
        await awaitSignal(updateStarted, timeout: timeout)
    }

    private func awaitSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
        // A semaphore cannot be awaited from an async context; the wait itself is short and bounded.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    /// Moves Homebrew's FETCH_HEAD so the catalog looks older (or newer) than its auto-update window.
    func setIndexAge(hours: Double) throws {
        let date = Date().addingTimeInterval(-hours * 3600)
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: repository.appending(path: ".git/FETCH_HEAD").path)
    }

    var invocations: [String] {
        locked { log }
    }

    func count(_ command: String) -> Int {
        invocations.filter { $0 == command || $0.hasPrefix(command + " ") }.count
    }

    private func run(_ args: [String]) -> HomebrewUpdates.RunResult {
        locked { log.append(args.joined(separator: " ")) }
        switch args.first {
        case "--repository":
            return .init(status: 0, stdout: repository.path + "\n", stderr: "", signal: nil, timedOut: nil)
        case "update":
            if let gate = updateGate {
                updateStarted.signal()
                gate.wait()
            }
            let writes = updateStatus == 0 || partialUpdate
            if writes {
                locked { updated = true }
                try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                       ofItemAtPath: repository.appending(path: ".git/FETCH_HEAD").path)
            }
            return .init(status: Int32(updateStatus), stdout: "", stderr: updateWarning + updateError,
                         signal: nil, timedOut: nil)
        case "outdated":
            if let signal = outdatedSignal {
                return .init(status: signal, stdout: "", stderr: "", signal: signal, timedOut: nil)
            }
            outdatedGate?.wait()
            let refreshed = locked { updated } && !outdatedAfterJSON.isEmpty
            return .init(status: Int32(refreshed ? outdatedAfterStatus : outdatedStatus),
                         stdout: refreshed ? outdatedAfterJSON : outdatedJSON,
                         stderr: outdatedError, signal: nil, timedOut: nil)
        case "info":
            if let gate = infoGate {
                infoStarted.signal()
                gate.wait()
            }
            let refreshed = locked { updated } && !infoAfterJSON.isEmpty
            return .init(status: Int32(infoStatus),
                         stdout: refreshed ? infoAfterJSON : infoJSON,
                         stderr: infoError, signal: nil, timedOut: nil)
        case "upgrade":
            return .init(status: 0, stdout: "", stderr: "", signal: nil, timedOut: nil)
        default:
            return .init(status: 64, stdout: "", stderr: "unexpected: \(args.joined(separator: " "))",
                         signal: nil, timedOut: nil)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private func check(_ brew: FakeBrew, greedy: Bool = false, autoUpdate: Bool = false,
                   excludingAppBundleNames: Set<String> = [], excludingTokens: Set<String> = [])
    -> Result<HomebrewUpdates.OutdatedCheck, HomebrewUpdates.Failure> {
    HomebrewUpdates.check(greedy: greedy, autoUpdate: autoUpdate,
                          excludingAppBundleNames: excludingAppBundleNames,
                          excludingTokens: excludingTokens,
                          brew: brew.executable.path, repository: brew.repository,
                          runner: brew.runner)
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
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        try brew.setIndexAge(hours: 1)

        let first = try check(brew).get()
        #expect(first.casks.first { $0.token == "obs" }?.name == "OBS")
        #expect(first.casks.first { $0.token == "obs" }?.needsAdmin == false)
        #expect(first.casks.first { $0.token == "obs" }?.appNames == ["OBS.app"])
        #expect(brew.count("info") == 1)

        // Same token, same versions, changed definition: the app must not reuse the old details.
        brew.setInfo(infoAfterFixture)
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
        brew.setOutdated(outdatedFixture)
        brew.infoStatus = 1
        brew.setInfoError("Could not load cask metadata")

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
        brew.setOutdated("""
        {"formulae":[],"casks":[
          {"name":"\(ownToken)","installed_versions":["0.3.0"],"current_version":"0.3.2","pinned":false},
          {"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false}
        ]}
        """)
        brew.infoStatus = 1
        brew.setInfoError("Could not load cask metadata")

        let result = try check(brew, excludingTokens: [ownToken]).get()
        #expect(result.casks.map(\.token) == ["obs"])
        #expect(result.unconfirmedTokens == ["obs"], "the excluded cask must not stay unconfirmed")
    }

    @Test func outdatedFailureIsReported() throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        brew.outdatedStatus = 1
        brew.setOutdatedError("network is down")

        switch check(brew) {
        case .success:
            Issue.record("a failed brew outdated must not look like a successful check")
        case .failure(.failed(let message)):
            #expect(message == "network is down")
        case .failure(.notInstalled):
            Issue.record("the fake brew is installed")
        }
    }

    @Test func aBrewThatDiesWithoutOutputSaysHowItEnded() throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        // Something stopped `brew outdated` before it printed a single byte. That must reach the
        // caller as a reason, never as an empty failure message.
        brew.outdatedSignal = SIGTERM
        guard case .failure(.failed(let killed)) = check(brew) else {
            Issue.record("a killed brew must not look like a successful check")
            return
        }
        #expect(killed == "brew outdated --cask --json=v2 was terminated by signal 15")

        // A brew that exits successfully but prints nothing is a failure too, and has to say so.
        brew.outdatedSignal = nil
        brew.setOutdated("")
        guard case .failure(.failed(let silent)) = check(brew) else {
            Issue.record("an empty catalogue must not look like a successful check")
            return
        }
        #expect(silent == "brew outdated --cask --json=v2 exited with status 0 and printed nothing")
    }

    /// Live: a real shell starts a real child that keeps the output pipe open after the shell
    /// exits. The reader must return what the shell printed instead of waiting for the child.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACHELPER_LIVE_TESTS"] == "1"))
    func aBackgroundChildOfBrewDoesNotHoldTheCheck() throws {
        let t = try TempDir()
        let bin = try TempDir()
        let script = bin.url.appending(path: "brew")
        // The shell prints the list, leaves a child holding the pipe, and exits.
        try Data("""
        #!/bin/sh
        case "$1" in
        outdated)
          sleep 5 &
          printf '%s' '{"formulae":[],"casks":[]}'
          exit 0
          ;;
        esac
        exit 64
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let repository = t.url.appending(path: "repo")
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"),
                                                withIntermediateDirectories: true)
        try Data().write(to: repository.appending(path: ".git/FETCH_HEAD"))

        let start = Date()
        let result = try HomebrewUpdates.check(greedy: false, brew: script.path, repository: repository).get()
        #expect(Date().timeIntervalSince(start) < 3,
                "a helper left behind must not hold the check for its whole lifetime")
        #expect(result.casks.isEmpty)
    }

    @Test func emptyCatalogIsSuccessAndSkipsInfo() throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        brew.setOutdated(#"{"formulae":[],"casks":[]}"#)
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
        brew.setOutdated("""
        {"formulae":[],"casks":[
          {"name":"\(ownToken)","installed_versions":["0.3.0"],"current_version":"0.3.2","pinned":false},
          {"name":"own-cask","installed_versions":["1.0"],"current_version":"2.0","pinned":false},
          {"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false},
          {"name":"gstreamer-runtime","installed_versions":["1.28.3"],"current_version":"1.28.6","pinned":true},
          {"name":"-rf","installed_versions":["1"],"current_version":"2","pinned":false}
        ]}
        """)
        brew.setInfo("""
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
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        try brew.setIndexAge(hours: 5)

        let result = try check(brew, greedy: true).get()
        #expect(brew.invocations.contains { $0.contains("--greedy") })
        let age = try #require(result.indexUpdatedAt.map { Date().timeIntervalSince($0) })
        #expect(age > 4.9 * 3600 && age < 5.1 * 3600)
    }

    @Test func repositoryPathAsksACustomBrew() throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        #expect(HomebrewUpdates.repositoryPath(for: brew.executable.path, environment: [:],
                                               runner: brew.runner)?.path == brew.repository.path)
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
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        brew.setOutdatedAfter(outdatedFixture)
        brew.setInfoAfter(infoAfterFixture)
        try brew.setIndexAge(hours: 48)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        try #require(all.count == 2)
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
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        brew.updateStatus = 1
        brew.setUpdateError("offline")
        try brew.setIndexAge(hours: 48)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        try #require(all.count == 2)
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
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        brew.setUpdateWarning("update failed, falling back to cached version.")
        try brew.setIndexAge(hours: 48)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        try #require(all.count == 2)
        #expect(all[1].isFinal && all[1].indexRefreshed)
        #expect(all[1].refreshFailure == nil)
        #expect(all[1].refreshWarning?.contains("falling back to cached version") == true)
    }

    @Test func refreshSuccessWithInfoFailureDoesNotAssumeNoAdmin() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        brew.setOutdated(outdatedFixture)
        brew.infoStatus = 1
        brew.setInfoError("Could not load cask metadata")
        try brew.setIndexAge(hours: 48)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        try #require(all.count == 2)
        #expect(all[1].isFinal && all[1].indexRefreshed)
        #expect(all[1].detailsFailure?.contains("Could not load cask metadata") == true)
        #expect(all[1].unconfirmedTokens == ["obs", "gstreamer-runtime"])
        #expect(all[1].casks.allSatisfy { !$0.needsAdmin },
                "the placeholder flag is false, but every row is unconfirmed")
    }

    @Test func refreshedDetailsExcludeTheAppBundleTheCaskNowInstalls() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        brew.setOutdated("""
        {"formulae":[],"casks":[
          {"name":"own-cask","installed_versions":["1.0"],"current_version":"2.0","pinned":false},
          {"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false}
        ]}
        """)
        brew.setInfo("""
        {"casks":[
          {"token":"own-cask","name":["Own"],"artifacts":[{"app":["Other.app"]}]},
          {"token":"obs","name":["OBS"],"artifacts":[{"app":["OBS.app"]}]}
        ]}
        """)
        brew.setOutdatedAfter("""
        {"formulae":[],"casks":[
          {"name":"own-cask","installed_versions":["1.0"],"current_version":"2.0","pinned":false},
          {"name":"obs","installed_versions":["33.0.0"],"current_version":"33.0.1","pinned":false}
        ]}
        """)
        brew.setInfoAfter("""
        {"casks":[
          {"token":"own-cask","name":["Own"],"artifacts":[{"app":["MacHelper.app"]}]},
          {"token":"obs","name":["OBS"],"artifacts":[{"app":["OBS.app"]}]}
        ]}
        """)
        try brew.setIndexAge(hours: 48)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: false,
                                                      excludingAppBundleNames: ["MacHelper.app"]))
        let all = await snapshots(stream)

        try #require(all.count == 2)
        #expect(Set(all[0].casks.map(\.token)) == ["own-cask", "obs"])
        #expect(Set(all[1].casks.map(\.token)) == ["obs"],
                "the refreshed definition installs MacHelper.app, so it must disappear")
    }

    @Test func freshIndexYieldsTheProvisionalListThenTheDetails() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        try brew.setIndexAge(hours: 1)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        try #require(all.count == 2)
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
        brew.setOutdated(#"{"formulae":[],"casks":[]}"#)
        try brew.setIndexAge(hours: 1)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        try #require(all.count == 1)
        #expect(all[0].isFinal && !all[0].detailsPending)
        #expect(all[0].casks.isEmpty)
        #expect(brew.count("info") == 0)
        #expect(brew.count("update") == 0)
    }

    @Test func repeatedTriggerWhileRunningIsIgnored() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        try brew.setIndexAge(hours: 1)
        // Hold the first check inside `brew outdated`: it owns the session until released.
        let gate = DispatchSemaphore(value: 0)
        brew.outdatedGate = gate
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let first = await session.check(greedy: false, refresh: false)
        let second = await session.check(greedy: false, refresh: false)
        #expect(first != nil)
        #expect(second == nil, "a second check must not start another brew process")
        gate.signal()
        brew.outdatedGate = nil
        if let first { for await _ in first {} }

        let third = await session.check(greedy: false, refresh: false)
        #expect(third != nil)
        if let third { for await _ in third {} }
        #expect(brew.count("outdated") == 2)
    }

    @Test func waitUntilIdleWaitsForTheRunningCheck() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        try brew.setIndexAge(hours: 1)
        // The check cannot finish until the gate opens, so `waitUntilIdle` can only return after
        // that: it is a causal wait, not a wait that happens to be long enough.
        let gate = DispatchSemaphore(value: 0)
        brew.outdatedGate = gate
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let first = try #require(await session.check(greedy: false, refresh: false))
        Task.detached { gate.signal() }
        await session.waitUntilIdle()
        // Idle means a new check starts at once; a `waitUntilIdle` that returned early would leave
        // the session busy and this nil.
        brew.outdatedGate = nil
        let next = await session.check(greedy: false, refresh: false)
        #expect(next != nil)
        if let next { for await _ in next {} }
        for await _ in first {}
    }

    @Test func explicitRefreshReportsFailureAndKeepsTheList() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        brew.updateStatus = 1
        brew.setUpdateError("offline")
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: true))
        let all = await snapshots(stream)

        try #require(all.count == 2)
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
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: true))
        let all = await snapshots(stream)

        try #require(all.count == 2)
        #expect(all[0].detailsPending && all[0].indexRefreshed)
        #expect(all[1].isFinal && all[1].indexRefreshed && all[1].refreshFailure == nil)
        #expect(brew.invocations.first == "update --quiet")
        #expect(brew.count("info") == 1)
    }

    @Test func explicitRefreshSuccessThenListFailureReportsTheRefresh() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        brew.outdatedStatus = 1
        brew.setOutdatedError("the list could not be read")
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: true))
        let all = await snapshots(stream)

        try #require(all.count == 1)
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
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        brew.setOutdatedAfter(outdatedFixture)
        try brew.setIndexAge(hours: 48)
        brew.outdatedAfterStatus = 1
        brew.setOutdatedError("network is down")
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        try #require(all.count == 2)
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
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        brew.setOutdatedAfter(outdatedFixture)
        try brew.setIndexAge(hours: 48)
        brew.partialUpdate = true
        brew.updateStatus = 1
        brew.setUpdateError("update failed after writing")
        brew.outdatedAfterStatus = 1
        brew.setOutdatedError("the list could not be read")
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                     runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        let all = await snapshots(stream)

        try #require(all.count == 2)
        #expect(all[0].detailsPending && all[0].willRefresh)
        #expect(all[1].isFinal)
        #expect(all[1].failure == "the list could not be read")
        #expect(all[1].refreshFailure == "update failed after writing")
        #expect(!all[1].indexRefreshed, "a failed update must not be reported as a refresh")
        #expect(all[1].refreshAttempted, "the failed update may still have written data")
        #expect(all[1].casks.isEmpty)
    }
}

/// The provisional list must arrive while the details are still being read, and the final one
/// after them. A gate inside the fake's `info` proves the order causally instead of comparing
/// elapsed times, so a busy machine cannot make it fail.
@Suite(.serialized) struct HomebrewUpdatesFirstResultTests {
    @Test func firstResultArrivesBeforeTheRefreshFinishes() async throws {
        let t = try TempDir()
        let brew = try FakeBrew(root: t.url)
        brew.setOutdated(outdatedFixture)
        brew.setInfo(infoFixture)
        brew.setOutdatedAfter(outdatedFixture)
        brew.setInfoAfter(infoAfterFixture)
        try brew.setIndexAge(hours: 48)
        // Hold the catalog refresh open: the provisional list is only useful if it reaches the
        // caller while `brew update` is still running, not after it finishes.
        let updateGate = DispatchSemaphore(value: 0)
        brew.updateGate = updateGate
        let session = HomebrewUpdateSession(brew: brew.executable.path, repository: brew.repository,
                                            runner: brew.runner)

        let stream = try #require(await session.check(greedy: false, refresh: false))
        var seen: [HomebrewUpdateSession.Snapshot] = []
        for await snapshot in stream {
            seen.append(snapshot)
            if seen.count == 1 {
                // The first result reached us while the refresh had not finished: either it had not
                // started yet or it is blocked on the gate below.
                #expect(snapshot.detailsPending && snapshot.willRefresh && !snapshot.isFinal)
                if brew.count("update") > 0 {
                    #expect(await brew.waitForUpdateToStart(),
                            "a started refresh must be the blocked one, not a finished one")
                }
                updateGate.signal()
            }
        }
        #expect(seen.count == 2)
        #expect(seen[1].isFinal && seen[1].indexRefreshed && !seen[1].detailsPending)
        #expect(seen[1].casks.first { $0.token == "obs" }?.name == "OBS Studio")
        #expect(brew.invocations == ["outdated --cask --json=v2", "update --quiet",
                                     "outdated --cask --json=v2",
                                     "info --cask --json=v2 obs gstreamer-runtime"])
    }
}

/// The pipe reader, exercised with a real pipe but no process: the two conditions that used to
/// make a check wait for its whole timeout are set from the test instead of from the machine.
@Suite struct HomebrewPipeReaderTests {
    /// A writer that never closes its end must not hold the read once the command has exited.
    @Test func readEndsWithTheCommandNotWithALingeringWriter() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("[]".utf8))
        // Keep the write end open, the way a helper a brew leaves behind does.
        defer { try? pipe.fileHandleForWriting.close() }
        let data = HomebrewUpdates.read(pipe.fileHandleForReading, hasExited: { true },
                                        deadline: .now() + 30,
                                        onDeadline: { Issue.record("the read waited for the deadline") })
        #expect(String(decoding: data, as: UTF8.self) == "[]")
    }

    /// Once the deadline passes the reader must end the command and stop, instead of reading a
    /// pipe that keeps looking open.
    @Test func anExpiredDeadlineEndsTheRead() throws {
        let pipe = Pipe()
        var deadlineHit = false
        let data = HomebrewUpdates.read(pipe.fileHandleForReading, hasExited: { false },
                                        deadline: .now() + 0.05,
                                        onDeadline: {
                                            deadlineHit = true
                                            // The real call terminates the command, which closes the
                                            // pipe; this is what its EOF would do here.
                                            try? pipe.fileHandleForWriting.close()
                                        })
        #expect(deadlineHit, "the deadline must be noticed")
        #expect(data.isEmpty)
    }
}
