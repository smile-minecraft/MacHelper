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

    public static var brew: String? { Homebrew.brew }

    /// Cask tokens are lowercase names like `visual-studio-code` or `font-sf-pro@2`; never an option.
    public static func isValidToken(_ t: String) -> Bool {
        !t.isEmpty && t.count <= 100 && !t.hasPrefix("-")
            && t.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.@+/").contains($0) }
    }

    /// Outdated casks. Homebrew refreshes its catalog first when it is older than a day (its own rule);
    /// `refresh` forces `brew update`. `greedy` adds apps that update themselves.
    public static func outdated(greedy: Bool, refresh: Bool = false) -> Result<[OutdatedCask], Failure> {
        guard let brew else { return .failure(.notInstalled) }
        if refresh {
            let u = run(brew, ["update", "--quiet"], timeout: 180, autoUpdate: true)
            if u.status != 0 { return .failure(.failed(tail(u.stderr.isEmpty ? u.stdout : u.stderr))) }
        }
        let r = run(brew, ["outdated", "--cask", "--json=v2"] + (greedy ? ["--greedy"] : []), timeout: 180, autoUpdate: !refresh)
        guard r.status == 0, let rows = parseOutdated(Data(r.stdout.utf8)) else {
            return .failure(.failed(tail(r.stderr.isEmpty ? r.stdout : r.stderr)))
        }
        let tokens = rows.map(\.token).filter(isValidToken)
        guard !tokens.isEmpty else { return .success([]) }
        let info = run(brew, ["info", "--cask", "--json=v2"] + tokens, timeout: 60, autoUpdate: false)
        let details = info.status == 0 ? parseInfo(Data(info.stdout.utf8)) : [:]
        return .success(rows.filter { isValidToken($0.token) }.map { row in
            let d = details[row.token]
            return OutdatedCask(token: row.token, name: d?.name ?? row.token, installedVersion: row.installed,
                                currentVersion: row.current, pinned: row.pinned, autoUpdates: d?.autoUpdates ?? false,
                                appNames: d?.apps ?? [], needsAdmin: d?.needsAdmin ?? false)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
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

    struct Details: Equatable {
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

    struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
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
        guard (try? p.run()) != nil else { return RunResult(status: -1, stdout: "", stderr: "Couldn’t start \(tool)") }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Read both pipes concurrently so a full stderr buffer can't block the process.
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        timer.cancel()
        return RunResult(status: p.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                         stderr: String(decoding: errData, as: UTF8.self))
    }
}
