import Foundation

/// An app installed with Homebrew (a cask) that has a newer version.
public struct OutdatedCask: Codable, Sendable, Identifiable, Hashable {
    public var id: String { token }
    public let token: String
    /// The app's display name ("OBS"), or the token when Homebrew has none.
    public let name: String
    public let installedVersion: String
    public let currentVersion: String
    public let pinned: Bool
    /// The app updates itself (Homebrew's `auto_updates`).
    public let autoUpdates: Bool
    /// App bundles the cask installs ("OBS.app").
    public let appNames: [String]
    /// Installing it runs a package installer or removes system files, which needs an administrator
    /// password that only Terminal can ask for.
    public let needsAdmin: Bool

    public init(token: String, name: String, installedVersion: String, currentVersion: String, pinned: Bool,
                autoUpdates: Bool, appNames: [String], needsAdmin: Bool) {
        self.token = token
        self.name = name
        self.installedVersion = installedVersion
        self.currentVersion = currentVersion
        self.pinned = pinned
        self.autoUpdates = autoUpdates
        self.appNames = appNames
        self.needsAdmin = needsAdmin
    }

    /// What to type in Terminal to update it by hand.
    public var terminalCommand: String { "brew upgrade --cask \(token)" }
}

/// Lists and updates Homebrew casks. Only fixed `brew` subcommands run, with tokens that Homebrew
/// itself reported and that pass `isValidToken`, never through a shell.
public enum HomebrewUpdates {
    public enum Failure: Error, Equatable, Sendable {
        case notInstalled
        case failed(String)
    }

    public struct UpgradeOutcome: Sendable, Equatable {
        public let token: String
        public let ok: Bool
        /// Homebrew needed an administrator password (sudo without a terminal).
        public let neededPassword: Bool
        /// The last part of Homebrew's output.
        public let output: String

        public init(token: String, ok: Bool, neededPassword: Bool, output: String) {
            self.token = token
            self.ok = ok
            self.neededPassword = neededPassword
            self.output = output
        }
    }

    public static var brew: String? {
        #if DEBUG
        // Debug builds and UI automation can point this at a fake Homebrew. Release builds have no
        // such entry: they only use the standard Homebrew install locations below.
        if let override = ProcessInfo.processInfo.environment["MACHELPER_BREW"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        #endif
        return Homebrew.brew
    }

    /// Homebrew's own auto-update window: `brew outdated` refreshes the catalog after this long.
    public static let autoUpdateInterval: TimeInterval = 24 * 60 * 60

    /// MacHelper 自身安裝用的 cask token。App 與 CLI 共用這個常數來把自己從更新清單中排除；
    /// cask 改名時這裡與 scripts/release.sh 的 `cask "machelper" do` 都要同步更新，否則
    /// CleanFlowTests.appCaskTokenMatchesReleaseScript 會失敗。
    public static let appCaskToken = "machelper"

    /// A list read from Homebrew's catalog, with the catalog's age so the UI can say how fresh it is.
    struct OutdatedCheck: Sendable, Equatable {
        public let casks: [OutdatedCask]
        /// Tokens whose cask definition details Homebrew could not return. They are listed with the
        /// data `brew outdated` gave, but must not be updated from the app or treated as safe.
        public let unconfirmedTokens: Set<String>
        /// Why `brew info` failed, when it did.
        public let detailsFailure: String?
        /// When Homebrew last fetched its repository. See `indexUpdatedAt(repository:)`.
        public let indexUpdatedAt: Date?
        /// True when `brew update` ran and succeeded before this list was read.
        public let refreshed: Bool
        /// Why `brew update` failed, when it did; the list is still from the existing catalog.
        public let refreshFailure: String?
        /// A warning Homebrew printed while the update still succeeded, such as falling back to a
        /// cached API file. The result is usable, but it is not proof that every cask definition
        /// came from a fresh download.
        public let refreshWarning: String?
        public let checkedAt: Date
    }

    /// The raw result of one `brew outdated` run, before cask details are read.
    struct OutdatedList: Sendable, Equatable {
        let rows: [OutdatedRow]
        let indexUpdatedAt: Date?
        let checkedAt: Date
    }

    struct RefreshResult: Sendable, Equatable {
        let ok: Bool
        let message: String?
        let warning: String?
    }

    /// A resolved Homebrew executable, or the explicit absence of one. `.missing` has no path and
    /// cannot start a process, so tests can cover the not-installed decision without a fallback.
    enum BrewDependency: Equatable, Sendable {
        case installed(String)
        case missing
    }

    /// Cask tokens are lowercase names like `visual-studio-code` or `font-sf-pro@2`; never an option.
    public static func isValidToken(_ t: String) -> Bool {
        !t.isEmpty && t.count <= 100 && !t.hasPrefix("-")
            && t.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.@+/").contains($0) }
    }

    /// Reads the outdated casks and their cask definition details from Homebrew's existing catalog.
    /// `brew info` runs on every check: a token alone does not prove that the cask definition is
    /// unchanged, and the version in `brew outdated` can stay the same while its artifacts change.
    /// `autoUpdate` lets Homebrew refresh its catalog first, as the CLI did before; the app reads the
    /// existing catalog with `HOMEBREW_NO_AUTO_UPDATE=1` and decides about a refresh itself.
    /// Casks that installed the asking app itself are left out: name its App bundle and, as a
    /// fallback, its cask token.
    static func check(greedy: Bool, autoUpdate: Bool = false,
                      excludingAppBundleNames: Set<String> = [],
                      excludingTokens: Set<String> = [],
                      brew: String, repository: URL? = nil,
                      runner: HomebrewCommandRunner = .system) -> Result<OutdatedCheck, Failure> {
        switch list(greedy: greedy, autoUpdate: autoUpdate, brew: brew, repository: repository, runner: runner) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let list):
            let tokens = list.rows.map(\.token).filter(isValidToken)
            let (details, detailsFailure) = details(for: tokens, brew: brew, runner: runner)
            return .success(makeCheck(list, details: details, detailsFailure: detailsFailure,
                                      refreshed: false, refreshFailure: nil, refreshWarning: nil,
                                      excludingAppBundleNames: excludingAppBundleNames,
                                      excludingTokens: excludingTokens))
        }
    }

    /// One `brew outdated` run. Never updates the catalog unless `autoUpdate` is true.
    static func list(greedy: Bool, autoUpdate: Bool, brew: String, repository: URL?,
                     runner: HomebrewCommandRunner = .system)
        -> Result<OutdatedList, Failure> {
        let result = runner.run(brew, ["outdated", "--cask", "--json=v2"] + (greedy ? ["--greedy"] : []),
                                180, autoUpdate)
        guard result.status == 0, let rows = parseOutdated(Data(result.stdout.utf8)) else {
            return .failure(.failed(result.failureMessage("brew outdated --cask --json=v2")))
        }
        let indexUpdatedAt = (repository ?? repositoryPath(for: brew, runner: runner))
            .flatMap(Self.indexUpdatedAt(repository:))
        return .success(OutdatedList(rows: rows, indexUpdatedAt: indexUpdatedAt, checkedAt: Date()))
    }

    /// `brew info` for every listed token. A failure returns no details and the reason, so the
    /// caller can mark the rows as unconfirmed instead of assuming they need no administrator.
    static func details(for tokens: [String], brew: String,
                        runner: HomebrewCommandRunner = .system) -> (details: [String: Details], failure: String?) {
        guard !tokens.isEmpty else { return ([:], nil) }
        let info = runner.run(brew, ["info", "--cask", "--json=v2"] + tokens, 60, false)
        guard info.status == 0 else {
            return ([:], info.failureMessage("brew info --cask --json=v2"))
        }
        return (parseInfo(Data(info.stdout.utf8)).filter { tokens.contains($0.key) }, nil)
    }

    /// Joins `brew outdated` rows with the details `brew info` returned. Rows without details stay
    /// listed but are reported in `unconfirmedTokens`.
    static func makeCheck(_ list: OutdatedList, details: [String: Details], detailsFailure: String?,
                          refreshed: Bool, refreshFailure: String?, refreshWarning: String?,
                          excludingAppBundleNames: Set<String>, excludingTokens: Set<String>) -> OutdatedCheck {
        let valid = list.rows.filter { isValidToken($0.token) }
        let unconfirmed = Set(valid.map(\.token).filter { details[$0] == nil })
        let listed = valid.filter { row in
            !isSelfInstalled(row, details: details,
                             excludingAppBundleNames: excludingAppBundleNames,
                             excludingTokens: excludingTokens)
        }
        let casks = listed.map { row -> OutdatedCask in
            let d = details[row.token]
            return OutdatedCask(token: row.token, name: d?.name ?? row.token, installedVersion: row.installed,
                                currentVersion: row.current, pinned: row.pinned, autoUpdates: d?.autoUpdates ?? false,
                                appNames: d?.apps ?? [], needsAdmin: d?.needsAdmin ?? false)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return OutdatedCheck(casks: casks,
                             unconfirmedTokens: unconfirmed.intersection(listed.map(\.token)),
                             detailsFailure: detailsFailure, indexUpdatedAt: list.indexUpdatedAt,
                             refreshed: refreshed, refreshFailure: refreshFailure,
                             refreshWarning: refreshWarning, checkedAt: list.checkedAt)
    }

    /// The blocking list used by the CLI. `refresh` runs `brew update` first and turns its failure
    /// into an error; without it Homebrew may auto-update its catalog as before.
    public static func outdated(greedy: Bool, refresh: Bool = false,
                                excludingAppBundleNames: Set<String> = [],
                                excludingTokens: Set<String> = []) -> Result<[OutdatedCask], Failure> {
        outdated(greedy: greedy, refresh: refresh, excludingAppBundleNames: excludingAppBundleNames,
                 excludingTokens: excludingTokens,
                 dependency: brew.map(BrewDependency.installed) ?? .missing)
    }

    /// The same decision with the Homebrew dependency named explicitly. `.missing` is rejected
    /// before anything can run: tests cover the not-installed path here without a fallback that
    /// could execute the machine's Homebrew.
    static func outdated(greedy: Bool, refresh: Bool,
                         excludingAppBundleNames: Set<String>, excludingTokens: Set<String>,
                         dependency: BrewDependency,
                         runner: HomebrewCommandRunner = .system) -> Result<[OutdatedCask], Failure> {
        guard case .installed(let brew) = dependency else { return .failure(.notInstalled) }
        if refresh {
            let update = refreshIndex(brew: brew, runner: runner)
            if !update.ok { return .failure(.failed(update.message ?? "")) }
        }
        return check(greedy: greedy, autoUpdate: !refresh,
                     excludingAppBundleNames: excludingAppBundleNames, excludingTokens: excludingTokens,
                     brew: brew, repository: nil, runner: runner).map(\.casks)
    }

    /// Runs `brew update --quiet` and reports success or failure; never throws. The executable is
    /// required: a nil fallback here once ran the user's real Homebrew during a test.
    static func refreshIndex(brew: String, runner: HomebrewCommandRunner = .system) -> RefreshResult {
        let result = runner.run(brew, ["update", "--quiet"], 180, true)
        let ok = result.status == 0
        // Homebrew exits 0 after falling back to a cached API file and warns about it. That warning
        // means the catalog is usable but not fully re-downloaded, so it is kept separate from both
        // success and failure. Other warnings (an outdated Xcode, a branch migration) do not change
        // what the list means and must not suppress a clean "all up to date".
        return RefreshResult(ok: ok, message: ok ? nil : result.failureMessage("brew update --quiet"),
                             warning: ok ? cachedFallbackWarning(result.stderr) : nil)
    }

    /// Homebrew's warning when a JSON API download failed and it reused the cached file:
    /// `Warning: <file>: update failed, falling back to cached version.` (Library/Homebrew/api.rb).
    static func cachedFallbackWarning(_ stderr: String) -> String? {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.localizedCaseInsensitiveContains("falling back to cached version") }
        return lines.isEmpty ? nil : tail(lines.joined(separator: "\n"))
    }

    /// The repository whose FETCH_HEAD Homebrew's own auto-update uses for `brew outdated`. The two
    /// standard install locations are known without another process; a test or custom brew answers
    /// `--repository`.
    static func repositoryPath(for brew: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               runner: HomebrewCommandRunner = .system) -> URL? {
        if let env = environment["HOMEBREW_REPOSITORY"], !env.isEmpty {
            return URL(filePath: env)
        }
        if brew.hasPrefix("/opt/homebrew/") { return URL(filePath: "/opt/homebrew") }
        if brew.hasPrefix("/usr/local/") { return URL(filePath: "/usr/local/Homebrew") }
        let result = runner.run(brew, ["--repository"], 10, false)
        guard result.status == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(filePath: path)
    }

    /// Homebrew's auto-update freshness marker for `brew outdated`: the brew repository's
    /// FETCH_HEAD. It proves only when that repository was fetched. Tap checkouts and Homebrew's
    /// downloaded JSON API cache have their own times, and Homebrew falls back to a cached API file
    /// when a download fails, so this is a reason to refresh, not proof that every cask definition
    /// is current.
    static func indexUpdatedAt(repository: URL) -> Date? {
        let fetchHead = repository.appending(path: ".git/FETCH_HEAD")
        return (try? FileManager.default.attributesOfItem(atPath: fetchHead.path))?[.modificationDate] as? Date
    }

    /// True when the cask belongs to the App that is listing updates: it installs an App bundle the
    /// caller excluded, or its token is one the caller excluded. The installed App bundle decides;
    /// the token is the fallback for a run outside the .app (the bundled CLI resolves through a
    /// symlink, so only its install location identifies it).
    static func isSelfInstalled(_ row: OutdatedRow, details: [String: Details],
                                excludingAppBundleNames: Set<String>, excludingTokens: Set<String>) -> Bool {
        if excludingTokens.contains(row.token) { return true }
        guard let apps = details[row.token]?.apps else { return false }
        return apps.contains { excludingAppBundleNames.contains($0) }
    }

    /// `brew upgrade --cask <token>`, non-interactive: if it needs a password, it fails instead of waiting.
    public static func upgrade(_ token: String, timeout: TimeInterval = 1800) -> UpgradeOutcome {
        guard let brew, isValidToken(token) else {
            return UpgradeOutcome(token: token, ok: false, neededPassword: false, output: "Homebrew not found or invalid name")
        }
        let r = run(brew, ["upgrade", "--cask", token], timeout: timeout, autoUpdate: false)
        let text = r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr)
        let sudo = ["a terminal is required", "a password is required", "sudo:", "no tty present"].contains { text.localizedCaseInsensitiveContains($0) }
        let outcome = UpgradeOutcome(token: token, ok: r.status == 0, neededPassword: r.status != 0 && sudo, output: tail(text))
        OperationLog.shared.append([.init(time: Date(), command: "brew-upgrade", path: "", source: token, bytes: 0,
                                          result: outcome.ok ? "ok" : "failed", message: outcome.ok ? nil : String(outcome.output.suffix(300)))])
        return outcome
    }

    // MARK: Parsing (internal for tests)

    struct OutdatedRow: Equatable {
        let token: String
        let installed: String
        let current: String
        let pinned: Bool
    }

    static func parseOutdated(_ data: Data) -> [OutdatedRow]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return nil }
        return casks.compactMap { c in
            guard let token = c["name"] as? String else { return nil }
            let installed = (c["installed_versions"] as? [String])?.last ?? (c["installed_versions"] as? String) ?? "?"
            return OutdatedRow(token: token, installed: installed, current: c["current_version"] as? String ?? "?",
                               pinned: c["pinned"] as? Bool ?? false)
        }
    }

    struct Details: Equatable, Sendable {
        let name: String
        let autoUpdates: Bool
        let apps: [String]
        let needsAdmin: Bool
    }

    static func parseInfo(_ data: Data) -> [String: Details] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return [:] }
        var out: [String: Details] = [:]
        for c in casks {
            guard let token = c["token"] as? String else { continue }
            let artifacts = c["artifacts"] as? [[String: Any]] ?? []
            let apps = artifacts.compactMap { $0["app"] as? [Any] }.flatMap { $0 }.compactMap { $0 as? String }
                .map { ($0 as NSString).lastPathComponent }
            out[token] = Details(name: (c["name"] as? [String])?.first ?? token, autoUpdates: c["auto_updates"] as? Bool ?? false,
                                 apps: apps, needsAdmin: needsAdmin(artifacts))
        }
        return out
    }

    /// Package installers and kernel extensions always run with sudo. (Casks that only remove a file
    /// outside the home folder may or may not; those are tried, and a password failure is reported.)
    static func needsAdmin(_ artifacts: [[String: Any]]) -> Bool {
        for a in artifacts {
            if a["pkg"] != nil || a["installer"] != nil { return true }
            for key in ["uninstall", "uninstall_preflight"] {
                for stanza in a[key] as? [[String: Any]] ?? [] where stanza["pkgutil"] != nil || stanza["kext"] != nil {
                    return true
                }
            }
        }
        return false
    }

    static func tail(_ s: String, lines: Int = 20) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Running brew

    /// Runs one Homebrew command. Production starts the executable and reads its pipes; a test
    /// supplies a closure, so a check never starts a process, waits on a pipe, or races a clock.
    struct HomebrewCommandRunner: Sendable {
        typealias Run = @Sendable (_ tool: String, _ args: [String], _ timeout: TimeInterval,
                                   _ autoUpdate: Bool) -> RunResult
        let run: Run

        static let system = HomebrewCommandRunner { tool, args, timeout, autoUpdate in
            HomebrewUpdates.run(tool, args, timeout: timeout, autoUpdate: autoUpdate)
        }

        init(_ run: @escaping Run) {
            self.run = run
        }
    }

    struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        /// The signal that killed the command, when it did not exit on its own.
        let signal: Int32?
        /// The timeout that expired and ended the command, when one did.
        let timedOut: TimeInterval?

        /// Why the command failed, in the words of its own output when it has any. A command that
        /// dies without printing a byte (killed, crashed on start, or a shell that never reached
        /// its script) explains itself with how it ended instead of leaving an empty message.
        func failureMessage(_ command: String) -> String {
            let text = HomebrewUpdates.tail(stderr.isEmpty ? stdout : stderr)
            if !text.isEmpty { return text }
            if let timedOut { return "\(command) timed out after \(Int(timedOut.rounded())) s" }
            if let signal { return "\(command) was terminated by signal \(signal)" }
            return "\(command) exited with status \(status) and printed nothing"
        }
    }

    /// Set once the command has been reaped. The pipe reads consult it so they never keep waiting
    /// for an EOF that may never come (see `read(_:until:)`).
    private final class ChildExit: @unchecked Sendable {
        private let lock = NSLock()
        private var exited = false

        func markExited() {
            lock.lock()
            exited = true
            lock.unlock()
        }

        var hasExited: Bool {
            lock.lock()
            defer { lock.unlock() }
            return exited
        }
    }

    /// Marks the command as having run past its timeout, so a failure can say it timed out instead
    /// of reporting a bare signal.
    private final class Timeout: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: TimeInterval
        private var expired = false

        init(seconds: TimeInterval) { limit = seconds }

        func markExpired() {
            lock.lock()
            expired = true
            lock.unlock()
        }

        var seconds: TimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            return expired ? limit : nil
        }
    }

    static func run(_ tool: String, _ args: [String], timeout: TimeInterval, autoUpdate: Bool) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if autoUpdate { env["HOMEBREW_NO_AUTO_UPDATE"] = nil } else { env["HOMEBREW_NO_AUTO_UPDATE"] = "1" }
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["NONINTERACTIVE"] = "1"
        // The app has no PATH of a login shell; Homebrew and the tools casks call need these.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else {
            return RunResult(status: -1, stdout: "", stderr: "Couldn’t start \(tool)", signal: nil, timedOut: nil)
        }
        // Reap the command on its own thread: its exit is what tells the pipe reads below that it
        // cannot write any more, so they must see it without waiting for the timeout.
        //
        // Dedicated threads, not the shared global queue. Several checks can be in flight at once,
        // and a queue whose threads are all busy must not be able to hold a command's exit or its
        // pipe read hostage: a starved queue once turned a command that ends in milliseconds into a
        // reported 180 s timeout.
        let exit = ChildExit()
        let expired = Timeout(seconds: timeout)
        let deadline = DispatchTime.now() + timeout
        let reaped = DispatchGroup()
        reaped.enter()
        let reaper = Thread {
            p.waitUntilExit()
            exit.markExited()
            reaped.leave()
        }
        reaper.name = "brew exit"
        reaper.start()
        // Read both pipes at once so a full buffer in either one cannot block the command, and stop
        // at the command's own end rather than at an EOF that a helper it left behind may hold open
        // for its whole lifetime.
        nonisolated(unsafe) var errData = Data()
        let readers = DispatchGroup()
        readers.enter()
        let errReader = Thread {
            errData = read(err.fileHandleForReading, hasExited: { exit.hasExited }, deadline: deadline,
                           onDeadline: {
                               expired.markExpired()
                               p.terminate()
                           })
            readers.leave()
        }
        errReader.name = "brew stderr"
        errReader.start()
        let outData = read(out.fileHandleForReading, hasExited: { exit.hasExited }, deadline: deadline,
                           onDeadline: {
                               expired.markExpired()
                               p.terminate()
                           })
        readers.wait()
        reaped.wait()
        return RunResult(status: p.terminationStatus,
                         stdout: String(decoding: outData, as: UTF8.self),
                         stderr: String(decoding: errData, as: UTF8.self),
                         signal: p.terminationReason == .uncaughtSignal ? p.terminationStatus : nil,
                         timedOut: expired.seconds)
    }

    /// Reads a pipe until EOF, or until the command that writes it has exited and nothing is left
    /// in the pipe. Waiting for EOF alone is not enough: a command that dies before writing, or a
    /// helper that inherits the write end, leaves a pipe that EOF never reports here, and a check
    /// once stalled for its entire timeout on exactly that. Polling slices bound the read by the
    /// command's lifetime instead, and `onDeadline` ends the command when its own timeout passes
    /// so a reader can never outlive it. Both callbacks are supplied by the caller, so the loop
    /// itself can be exercised without a process.
    static func read(_ handle: FileHandle, hasExited: () -> Bool, deadline: DispatchTime,
                     onDeadline: () -> Void) -> Data {
        let fd = handle.fileDescriptor
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var cutOff = deadline
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                // Nothing arrived for 100 ms. Keep waiting while the command can still write; once
                // it is gone, everything it wrote has already been read and its helpers no longer
                // matter for the result.
                if hasExited() { break }
                if DispatchTime.now() >= cutOff {
                    onDeadline()
                    cutOff = .distantFuture
                }
                continue
            }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 { break }                                       // EOF: every writer is gone
            if errno == EINTR || errno == EAGAIN { continue }
            break
        }
        return data
    }
}

/// What the Updates page should say above the list. The view only renders it; the decision lives
/// here so the app and its tests share one implementation.
public enum UpdatesHeadline: Equatable, Sendable {
    /// No check has produced a usable list yet.
    case notChecked
    case allUpToDate
    /// A successful check found nothing, but the catalog it read may be old.
    case noUpdates(indexUpdatedAt: Date?)
    case updates(Int)

    public static func make(hasResult: Bool, casks: [OutdatedCask], indexRefreshed: Bool,
                            isIndexStale: Bool, refreshFailure: String?, refreshWarning: String?,
                            checkFailed: Bool, indexUpdatedAt: Date?) -> UpdatesHeadline {
        guard hasResult else { return .notChecked }
        guard casks.isEmpty else { return .updates(casks.count) }
        // A fresh FETCH_HEAD only proves the brew repository was fetched. Homebrew's JSON API cache
        // has its own age and falls back to a cached file when a download fails, so "all up to date"
        // is only justified after this check ran a clean `brew update` and the index is still fresh.
        if !checkFailed, indexRefreshed, !isIndexStale, refreshFailure == nil, refreshWarning == nil {
            return .allUpToDate
        }
        return .noUpdates(indexUpdatedAt: indexUpdatedAt)
    }
}

/// Runs one Homebrew update check at a time. The first snapshot comes from `brew outdated` alone;
/// a second snapshot adds the details from `brew info`. When the catalog is older than Homebrew's
/// own auto-update window, a refresh runs between them and a third snapshot reports the refreshed
/// list (or why refreshing failed). A repeated check while one is running returns nil; the caller
/// can wait with `waitUntilIdle()` and ask again.
public actor HomebrewUpdateSession {
    public struct Snapshot: Sendable, Equatable {
        public let casks: [OutdatedCask]
        public let checkedAt: Date
        public let indexUpdatedAt: Date?
        public let indexRefreshed: Bool
        /// `brew update` ran, even if it failed. A failed update can still have written part of the
        /// catalog, so old rows must not be trusted if the following list read also fails.
        public let refreshAttempted: Bool
        public let refreshFailure: String?
        public let refreshWarning: String?
        /// The list came from `brew outdated` and `brew info` has not answered yet. Names, App
        /// bundles and the administrator flag are not confirmed.
        public let detailsPending: Bool
        /// A catalog refresh will run after this first result.
        public let willRefresh: Bool
        public let detailsFailure: String?
        public let unconfirmedTokens: Set<String>
        public let failure: String?
        public let brewMissing: Bool
        /// False for a first result that later details or a background refresh will replace.
        public let isFinal: Bool

        init(casks: [OutdatedCask], checkedAt: Date, indexUpdatedAt: Date?, indexRefreshed: Bool,
             refreshAttempted: Bool, refreshFailure: String?, refreshWarning: String?,
             detailsPending: Bool, willRefresh: Bool,
             detailsFailure: String?, unconfirmedTokens: Set<String>, failure: String?,
             brewMissing: Bool, isFinal: Bool) {
            self.casks = casks
            self.checkedAt = checkedAt
            self.indexUpdatedAt = indexUpdatedAt
            self.indexRefreshed = indexRefreshed
            self.refreshAttempted = refreshAttempted
            self.refreshFailure = refreshFailure
            self.refreshWarning = refreshWarning
            self.detailsPending = detailsPending
            self.willRefresh = willRefresh
            self.detailsFailure = detailsFailure
            self.unconfirmedTokens = unconfirmedTokens
            self.failure = failure
            self.brewMissing = brewMissing
            self.isFinal = isFinal
        }

        init(_ check: HomebrewUpdates.OutdatedCheck, detailsPending: Bool, willRefresh: Bool,
             isFinal: Bool, refreshAttempted: Bool) {
            self.init(casks: check.casks, checkedAt: check.checkedAt, indexUpdatedAt: check.indexUpdatedAt,
                      indexRefreshed: check.refreshed, refreshAttempted: refreshAttempted,
                      refreshFailure: check.refreshFailure,
                      refreshWarning: check.refreshWarning, detailsPending: detailsPending,
                      willRefresh: willRefresh, detailsFailure: check.detailsFailure,
                      unconfirmedTokens: check.unconfirmedTokens,
                      failure: nil, brewMissing: false, isFinal: isFinal)
        }
    }

    private let brew: String?
    private let repository: URL?
    private let runner: HomebrewUpdates.HomebrewCommandRunner
    private var isRunning = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {
        self.brew = nil
        self.repository = nil
        self.runner = .system
    }

    init(brew: String?, repository: URL?, runner: HomebrewUpdates.HomebrewCommandRunner = .system) {
        self.brew = brew
        self.repository = repository
        self.runner = runner
    }

    #if DEBUG
    /// Test and UI-automation entry point. Release builds have no way to name a different
    /// executable; they always use `HomebrewUpdates.brew`.
    public static func testing(brew: String, repository: URL?) -> HomebrewUpdateSession {
        HomebrewUpdateSession(brew: brew, repository: repository)
    }
    #endif

    public func check(greedy: Bool, refresh: Bool,
                      excludingAppBundleNames: Set<String> = [],
                      excludingTokens: Set<String> = []) -> AsyncStream<Snapshot>? {
        guard !isRunning else { return nil }
        isRunning = true
        let repository = self.repository
        let runner = self.runner
        let dependency = brew.map(HomebrewUpdates.BrewDependency.installed)
            ?? HomebrewUpdates.brew.map(HomebrewUpdates.BrewDependency.installed)
            ?? .missing
        let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self)
        let task = Task.detached(priority: .userInitiated) {
            Self.produce(greedy: greedy, refresh: refresh,
                         excludingAppBundleNames: excludingAppBundleNames,
                         excludingTokens: excludingTokens,
                         dependency: dependency, repository: repository, runner: runner,
                         continuation: continuation)
            await self.finish()
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Waits for the check that currently owns the session. A caller that got nil from `check`
    /// uses this before asking again, instead of dropping the follow-up.
    public func waitUntilIdle() async {
        guard isRunning else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func finish() {
        isRunning = false
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private static func produce(greedy: Bool, refresh: Bool,
                                excludingAppBundleNames: Set<String>, excludingTokens: Set<String>,
                                dependency: HomebrewUpdates.BrewDependency, repository: URL?,
                                runner: HomebrewUpdates.HomebrewCommandRunner,
                                continuation: AsyncStream<Snapshot>.Continuation) {
        // The dependency is resolved once by `check`. Every path below either uses this exact
        // executable or reports that it is missing; there is no second lookup to fall back to.
        guard case .installed(let brew) = dependency else {
            continuation.yield(Snapshot(casks: [], checkedAt: Date(), indexUpdatedAt: nil,
                                        indexRefreshed: false, refreshAttempted: false,
                                        refreshFailure: nil, refreshWarning: nil,
                                        detailsPending: false, willRefresh: false, detailsFailure: nil,
                                        unconfirmedTokens: [], failure: nil, brewMissing: true, isFinal: true))
            return
        }

        func currentIndexUpdatedAt() -> Date? {
            (repository ?? HomebrewUpdates.repositoryPath(for: brew, runner: runner))
                .flatMap(HomebrewUpdates.indexUpdatedAt(repository:))
        }

        func readList() -> Result<HomebrewUpdates.OutdatedList, HomebrewUpdates.Failure> {
            HomebrewUpdates.list(greedy: greedy, autoUpdate: false, brew: brew, repository: repository,
                                 runner: runner)
        }

        func emit(_ list: HomebrewUpdates.OutdatedList, refreshed: Bool, refreshAttempted: Bool,
                  refreshFailure: String?, refreshWarning: String?, detailsPending: Bool,
                  willRefresh: Bool = false, isFinal: Bool) {
            let tokens = list.rows.map(\.token).filter(HomebrewUpdates.isValidToken)
            let (details, detailsFailure) = detailsPending
                ? ([:], nil)
                : HomebrewUpdates.details(for: tokens, brew: brew, runner: runner)
            let check = HomebrewUpdates.makeCheck(list, details: details, detailsFailure: detailsFailure,
                                                  refreshed: refreshed, refreshFailure: refreshFailure,
                                                  refreshWarning: refreshWarning,
                                                  excludingAppBundleNames: excludingAppBundleNames,
                                                  excludingTokens: excludingTokens)
            continuation.yield(Snapshot(check, detailsPending: detailsPending, willRefresh: willRefresh,
                                        isFinal: isFinal, refreshAttempted: refreshAttempted))
        }

        func emitFailure(_ failure: HomebrewUpdates.Failure, refreshed: Bool = false,
                         refreshAttempted: Bool = false, refreshFailure: String? = nil,
                         refreshWarning: String? = nil) {
            switch failure {
            case .notInstalled:
                continuation.yield(Snapshot(casks: [], checkedAt: Date(), indexUpdatedAt: nil,
                                            indexRefreshed: refreshed, refreshAttempted: refreshAttempted,
                                            refreshFailure: refreshFailure,
                                            refreshWarning: refreshWarning, detailsPending: false,
                                            willRefresh: false, detailsFailure: nil, unconfirmedTokens: [],
                                            failure: nil, brewMissing: true, isFinal: true))
            case .failed(let message):
                continuation.yield(Snapshot(casks: [], checkedAt: Date(), indexUpdatedAt: currentIndexUpdatedAt(),
                                            indexRefreshed: refreshed, refreshAttempted: refreshAttempted,
                                            refreshFailure: refreshFailure,
                                            refreshWarning: refreshWarning, detailsPending: false,
                                            willRefresh: false, detailsFailure: nil, unconfirmedTokens: [],
                                            failure: message, brewMissing: false, isFinal: true))
            }
        }

        var refreshFailure: String?
        var refreshWarning: String?
        var refreshed = false
        var refreshAttempted = false
        if refresh {
            refreshAttempted = true
            let update = HomebrewUpdates.refreshIndex(brew: brew, runner: runner)
            refreshFailure = update.message
            refreshWarning = update.warning
            refreshed = update.ok
        }

        let first: HomebrewUpdates.OutdatedList
        switch readList() {
        case .failure(let failure):
            emitFailure(failure, refreshed: refreshed, refreshAttempted: refreshAttempted,
                        refreshFailure: refreshFailure, refreshWarning: refreshWarning)
            return
        case .success(let list):
            first = list
        }
        var list = first

        let stale = list.indexUpdatedAt.map {
            Date().timeIntervalSince($0) > HomebrewUpdates.autoUpdateInterval
        } ?? true

        if refresh {
            emit(list, refreshed: refreshed, refreshAttempted: true, refreshFailure: refreshFailure,
                 refreshWarning: refreshWarning, detailsPending: true, isFinal: false)
            guard !Task.isCancelled else { return }
            emit(list, refreshed: refreshed, refreshAttempted: true, refreshFailure: refreshFailure,
                 refreshWarning: refreshWarning, detailsPending: false, isFinal: true)
            return
        }

        if !stale {
            if list.rows.isEmpty {
                emit(list, refreshed: false, refreshAttempted: false, refreshFailure: nil,
                     refreshWarning: nil, detailsPending: false, isFinal: true)
            } else {
                // The catalog looks fresh, but FETCH_HEAD only covers the brew repository. Show the
                // list at once as unconfirmed, then read the cask definitions before allowing any
                // update.
                emit(list, refreshed: false, refreshAttempted: false, refreshFailure: nil,
                     refreshWarning: nil, detailsPending: true, willRefresh: false, isFinal: false)
                guard !Task.isCancelled else { return }
                emit(list, refreshed: false, refreshAttempted: false, refreshFailure: nil,
                     refreshWarning: nil, detailsPending: false, isFinal: true)
            }
            return
        }

        // Show the existing catalog's list first, then update the index and verify the details of
        // the newest catalog. Details are fetched once, from the freshest catalog available.
        emit(list, refreshed: false, refreshAttempted: false, refreshFailure: nil,
             refreshWarning: nil, detailsPending: true, willRefresh: true, isFinal: false)
        guard !Task.isCancelled else { return }
        refreshAttempted = true
        let update = HomebrewUpdates.refreshIndex(brew: brew, runner: runner)
        guard !Task.isCancelled else { return }
        refreshFailure = update.message
        refreshWarning = update.warning
        if update.ok {
            switch readList() {
            case .failure(let failure):
                // The catalog changed under the old list, so the failure snapshot must say the
                // refresh happened. The caller keeps the old rows visible but cannot treat them as
                // confirmed any more.
                emitFailure(failure, refreshed: true, refreshAttempted: true, refreshFailure: nil,
                            refreshWarning: update.warning)
                return
            case .success(let refreshedList):
                list = refreshedList
                refreshed = true
            }
        } else {
            // A failed `brew update` can still have written part of the catalog. If the following
            // list also fails, the caller must not keep using the old rows. `indexRefreshed` stays
            // false: this is "may have changed", not "refreshed".
            switch readList() {
            case .failure(let failure):
                emitFailure(failure, refreshed: false, refreshAttempted: true,
                            refreshFailure: update.message, refreshWarning: update.warning)
                return
            case .success(let currentList):
                list = currentList
            }
        }
        emit(list, refreshed: refreshed, refreshAttempted: true, refreshFailure: refreshFailure,
             refreshWarning: refreshWarning, detailsPending: false, isFinal: true)
    }
}
