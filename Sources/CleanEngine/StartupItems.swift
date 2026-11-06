import AppKit
import Darwin
import Foundation
import PrivilegedOps

/// A launchd job that starts on its own: a per-user launch agent, an all-users agent or a system
/// daemon. Apple's own jobs are not listed.
public struct StartupItem: Codable, Sendable, Identifiable, Hashable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        case userAgent, systemAgent, systemDaemon

        public var title: String {
            switch self {
            case .userAgent: String(localized: "Your background items", bundle: .module)
            case .systemAgent: String(localized: "Background items for all users", bundle: .module)
            case .systemDaemon: String(localized: "System daemons", bundle: .module)
            }
        }

        /// Only your own items can be removed; system items can only be switched on or off.
        public var canRemove: Bool { self == .userAgent }

        /// System daemons are switched by the root Helper (app only). Agents for all users are
        /// switched for the current user in their own launchd domain, which needs no administrator.
        public var needsHelper: Bool { self == .systemDaemon }

        var jobKind: SystemJobControl.Kind? {
            switch self {
            case .userAgent: nil
            case .systemAgent: .agent
            case .systemDaemon: .daemon
            }
        }
    }

    public var id: String { plistPath }
    public let label: String
    public let plistPath: String
    public let scope: Scope
    public let program: String?
    public let arguments: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    /// Seconds between runs (StartInterval), if scheduled.
    public let interval: Int?
    public let isLoaded: Bool
    public let pid: Int?
    public let isDisabled: Bool
    /// Apple's and MacHelper's own jobs are never switched.
    public var isProtected: Bool { SystemJobControl.isProtected(label) }

    /// The program it starts is missing: a leftover of an app that is gone.
    public let programMissing: Bool
    public let ownerName: String?
    public let ownerPath: String?

    /// What the job runs, shortened for display.
    public var commandLine: String {
        ([program].compactMap { $0 } + arguments.dropFirst()).joined(separator: " ")
    }
}

public enum StartupItemError: Error, CustomStringConvertible {
    case notFound(String)
    case cannotRemove(String)
    case needsHelper(String)
    case protected(String)
    case launchctl(String)

    public var description: String {
        switch self {
        case .notFound(let l): "No startup item with label \(l)"
        case .cannotRemove(let l): "\(l) is a system item; it can be disabled but not removed"
        case .needsHelper(let l): "\(l) is a system daemon; switch it from the MacHelper app (needs the Helper)"
        case .protected(let l): "\(l) is an Apple or MacHelper job and can't be changed"
        case .launchctl(let m): "launchctl: \(m)"
        }
    }
}

public enum StartupItems {
    static var uid: uid_t { getuid() }
    static let home = MacHelperPaths.home.path

    static let directories: [(String, StartupItem.Scope)] = [
        (home + "/Library/LaunchAgents", .userAgent),
        ("/Library/LaunchAgents", .systemAgent),
        ("/Library/LaunchDaemons", .systemDaemon),
    ]

    public static func list(installed: [InstalledApp] = AppUninstaller.installedApps(measureSizes: false)) -> [StartupItem] {
        let userJobs = loadedUserJobs()
        let systemJobs = loadedSystemJobs()
        let userDisabled = disabledLabels(domain: "gui/\(uid)")
        let systemDisabled = disabledLabels(domain: "system")
        var items: [StartupItem] = []
        for (dir, scope) in directories {
            for e in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where e.hasSuffix(".plist") {
                let path = dir + "/" + e
                guard let job = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
                let label = job["Label"] as? String ?? (e as NSString).deletingPathExtension
                if label.hasPrefix("com.apple.") { continue }
                let args = job["ProgramArguments"] as? [String] ?? []
                let program = (job["Program"] as? String) ?? args.first
                let missing = program.map { $0.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0) } ?? false
                // A user agent is listed in the gui domain; agents for all users load there too.
                let state = scope == .systemDaemon ? systemJobs[label] : userJobs[label]
                let disabled = scope == .systemDaemon ? systemDisabled[label] : userDisabled[label]
                let owner = owner(label: label, job: job, program: program, installed: installed)
                items.append(StartupItem(
                    label: label, plistPath: path, scope: scope, program: program, arguments: args,
                    runAtLoad: job["RunAtLoad"] as? Bool ?? false,
                    keepAlive: (job["KeepAlive"] as? Bool) ?? (job["KeepAlive"] is [String: Any]),
                    interval: job["StartInterval"] as? Int,
                    isLoaded: state != nil, pid: state ?? nil, isDisabled: disabled ?? (job["Disabled"] as? Bool ?? false),
                    programMissing: missing, ownerName: owner?.name, ownerPath: owner?.path))
            }
        }
        return items.sorted { ($0.scope.rawValue, $0.label.lowercased()) < ($1.scope.rawValue, $1.label.lowercased()) }
    }

    // MARK: Changes (enable/disable for every scope; remove only your own items)

    /// Stops the job and keeps it from starting again (survives restarts), like the switch in
    /// System Settings → Login Items. The plist stays where it is.
    ///
    /// Your own agents and agents for all users are switched in your gui domain (for agents in
    /// /Library/LaunchAgents that affects only you). System daemons throw `needsHelper`: the app
    /// sends them to the root Helper and then calls `recordToggle`.
    public static func setEnabled(_ item: StartupItem, _ enabled: Bool) throws {
        try checkToggle(item)
        let domain = "gui/\(uid)"
        let (required, bestEffort) = SystemJobControl.commands(label: item.label, plistPath: item.plistPath, domain: domain, enabled: enabled)
        try launchctl(required)
        // Already stopped / already loaded is fine.
        _ = try? launchctl(bestEffort)
        recordToggle(item, enabled)
    }

    /// Throws unless `setEnabled` may switch this item in-process.
    public static func checkToggle(_ item: StartupItem) throws {
        guard !item.isProtected else { throw StartupItemError.protected(item.label) }
        guard !item.scope.needsHelper else { throw StartupItemError.needsHelper(item.label) }
        if let kind = item.scope.jobKind {
            // Same rules as the Helper: directly in the folder, a real root-owned plist, label from the file.
            let label = try SystemJobControl.validate(plistPath: item.plistPath, kind: kind)
            guard label == item.label else { throw StartupItemError.notFound(item.label) }
        }
    }

    public static func recordToggle(_ item: StartupItem, _ enabled: Bool, log: OperationLog = .shared) {
        log.append([OperationLog.Entry(time: Date(), command: "startup", path: item.plistPath,
                                       source: "startup", bytes: 0, result: enabled ? "enabled" : "disabled",
                                       message: item.label)])
    }

    /// Stops the job and moves its plist to the Trash.
    public static func remove(_ item: StartupItem) throws -> CleanReport {
        guard item.scope.canRemove else { throw StartupItemError.cannotRemove(item.label) }
        _ = try? launchctl(["bootout", "gui/\(uid)/\(item.label)"])
        let removal = RemovalItem(path: item.plistPath, source: "startup.remove", bytes: 0, action: .trash)
        return CleanExecutor(safety: AppUninstaller.leftoverSafety).execute([removal], dryRun: false, command: "startup")
    }

    public static func find(_ label: String, in items: [StartupItem]) throws -> StartupItem {
        guard let item = items.first(where: { $0.label == label || $0.plistPath == expandTilde(label) }) else {
            throw StartupItemError.notFound(label)
        }
        return item
    }

    // MARK: launchd state

    /// Label → pid (nil when loaded but not running) for the user's gui domain.
    static func loadedUserJobs() -> [String: Int?] {
        guard let out = try? launchctl(["list"]) else { return [:] }
        var jobs: [String: Int?] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            jobs[String(cols[2])] = Int(cols[0])
        }
        return jobs
    }

    /// Label → pid for the system domain (readable without root).
    static func loadedSystemJobs() -> [String: Int?] {
        guard let out = try? launchctl(["print", "system"]) else { return [:] }
        var jobs: [String: Int?] = [:]
        var inServices = false
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("services = {") { inServices = true; continue }
            if inServices {
                if line == "}" { break }
                let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard cols.count >= 3 else { continue }
                let pid = Int(cols[0]) ?? 0
                jobs[String(cols[2])] = pid > 0 ? pid : nil
            }
        }
        return jobs
    }

    /// Label → disabled, from `launchctl print-disabled`.
    static func disabledLabels(domain: String) -> [String: Bool] {
        guard let out = try? launchctl(["print-disabled", domain]) else { return [:] }
        var result: [String: Bool] = [:]
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let end = line.dropFirst().firstIndex(of: "\"") else { continue }
            let label = String(line[line.index(after: line.startIndex)..<end])
            result[label] = line.hasSuffix("disabled") || line.hasSuffix("true")
        }
        return result
    }

    // MARK: Ownership

    /// The app a job belongs to: the app its program lives in, its AssociatedBundleIdentifiers, or an
    /// installed app whose bundle ID starts the label.
    static func owner(label: String, job: [String: Any], program: String?, installed: [InstalledApp]) -> (name: String, path: String)? {
        if let program, let r = program.range(of: ".app/") {
            let appPath = String(program[..<r.lowerBound]) + ".app"
            let name = installed.first { $0.path == appPath }?.name ?? ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            return (name, appPath)
        }
        if let ids = job["AssociatedBundleIdentifiers"] as? [String] ?? (job["AssociatedBundleIdentifiers"] as? String).map({ [$0] }) {
            for id in ids {
                if let app = installed.first(where: { $0.bundleID == id }) { return (app.name, app.path) }
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    return ((url.lastPathComponent as NSString).deletingPathExtension, url.path)
                }
            }
        }
        let l = label.lowercased()
        let match = installed
            .filter { l == $0.bundleID.lowercased() || l.hasPrefix($0.bundleID.lowercased() + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
        return match.map { ($0.name, $0.path) }
    }

    @discardableResult
    static func launchctl(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw StartupItemError.launchctl(String(decoding: errData.isEmpty ? data : errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
