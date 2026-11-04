import AppKit
import CoreServices
import Foundation

public struct InstalledApp: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let name: String
    public let bundleID: String
    public let version: String?
    public let path: String
    public let size: UInt64
    public let isAppStore: Bool
    public let lastUsed: Date?
    public let isRunning: Bool
    public let teamID: String?
    /// Why this app cannot be uninstalled here (Apple app, MacHelper itself), if so.
    public let protectedReason: String?

    public var canUninstall: Bool { protectedReason == nil }
}

public enum LeftoverKind: String, Codable, Sendable, CaseIterable {
    case appBundle, cache, logs, crashReport, savedState, webData, preferences, launchAgent, command, plugin,
         appData, container, groupContainer, homeData

    /// Personal data may live here, so these are kept unless the user opts in.
    public var mayContainUserData: Bool { [.appData, .container, .groupContainer, .homeData].contains(self) }

    public var title: String {
        switch self {
        case .appBundle: String(localized: "App bundle", bundle: .module)
        case .cache: String(localized: "Caches", bundle: .module)
        case .logs: String(localized: "Logs", bundle: .module)
        case .crashReport: String(localized: "Crash reports", bundle: .module)
        case .savedState: String(localized: "Saved window state", bundle: .module)
        case .webData: String(localized: "Web data", bundle: .module)
        case .preferences: String(localized: "Preferences", bundle: .module)
        case .launchAgent: String(localized: "Background items", bundle: .module)
        case .command: String(localized: "Commands (~/.local/bin)", bundle: .module)
        case .plugin: String(localized: "Plug-ins and extensions", bundle: .module)
        case .appData: String(localized: "App data (Application Support)", bundle: .module)
        case .container: String(localized: "Sandbox containers (Containers)", bundle: .module)
        case .groupContainer: String(localized: "Shared containers (Group Containers)", bundle: .module)
        case .homeData: String(localized: "Data in your home folder (~/.name)", bundle: .module)
        }
    }
}

/// Why a leftover is attributed to the app. Strong evidence is selected by default; name and vendor
/// matches are shown for the user to confirm.
public enum LeftoverEvidence: String, Codable, Sendable {
    case bundleID           // named by the app's bundle identifier
    case embeddedID         // named by a helper, extension or login item inside the app
    case appGroup           // an App Group from the app's entitlements
    case containerMetadata  // a UUID-named container whose metadata names the app
    case program            // a launchd job, command or browser host whose program lives in the app
    case homebrew           // the app's Homebrew cask lists it (zap)
    case rule               // MacHelper's per-app rule
    case family             // the parent bundle ID (com.foo.app.setup → com.foo.app)
    case teamID             // a Team-ID group container, team used by no other installed app
    case reference          // runs something from the app's data folder
    case name               // the app's name
    case vendor             // the developer's folder, developer has no other installed app
    case orphan             // its app is gone (orphan scan)

    public var isStrong: Bool { ![.name, .vendor, .orphan].contains(self) }

    public var title: String {
        switch self {
        case .bundleID: String(localized: "Bundle ID matches", bundle: .module)
        case .embeddedID: String(localized: "Helper or extension inside the app", bundle: .module)
        case .appGroup: String(localized: "App Group declared by the app", bundle: .module)
        case .containerMetadata: String(localized: "Container metadata names the app", bundle: .module)
        case .program: String(localized: "Runs a program inside the app", bundle: .module)
        case .homebrew: String(localized: "Listed by Homebrew", bundle: .module)
        case .rule: String(localized: "MacHelper rule", bundle: .module)
        case .family: String(localized: "Related bundle ID", bundle: .module)
        case .teamID: String(localized: "Same developer team", bundle: .module)
        case .reference: String(localized: "Uses the app’s data", bundle: .module)
        case .name: String(localized: "Matched by app name, please check", bundle: .module)
        case .vendor: String(localized: "Matched by developer name, please check", bundle: .module)
        case .orphan: String(localized: "Its app no longer exists", bundle: .module)
        }
    }
}

public struct UninstallItem: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let kind: LeftoverKind
    public let size: UInt64
    public var selected: Bool
    public let evidence: LeftoverEvidence
    /// Selected together with the app's data (the "remove app data" choice), not on its own.
    public var followsUserData: Bool = false

    public var needsConfirmation: Bool { !evidence.isStrong }
}

/// Found but deliberately left alone, with the reason shown to the user.
public struct KeptLeftover: Codable, Sendable, Hashable {
    public let path: String
    public let reason: String
}

public struct UninstallPlan: Codable, Sendable {
    public let schemaVersion: Int
    public let app: InstalledApp
    public var items: [UninstallItem]
    /// Leftovers in system locations (need an administrator); listed for manual removal.
    public let systemItems: [String]
    public let kept: [KeptLeftover]

    public var selectedSize: UInt64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }
    public var totalSize: UInt64 { items.reduce(0) { $0 + $1.size } }
}

public enum UninstallError: Error, CustomStringConvertible {
    case notFound(String)
    case ambiguous(String, [String])
    case protected(String)
    case running(String)

    public var description: String {
        switch self {
        case .notFound(let q): "No installed app matches \"\(q)\""
        case .ambiguous(let q, let names): "\"\(q)\" matches several apps: \(names.joined(separator: ", "))"
        case .protected(let r): r
        case .running(let n): "\(n) is running; quit it first"
        }
    }
}

/// Finds installed apps and everything they left in the home Library, by bundle identifier.
public enum AppUninstaller {
    static let home = MacHelperPaths.home.path
    public static let appFolders = ["/Applications", home + "/Applications"]

    // MARK: Installed apps

    public static func installedApps(measureSizes: Bool = true) -> [InstalledApp] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var bundles: [String] = []
        for folder in appFolders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                let p = folder + "/" + name
                if name.hasSuffix(".app") {
                    bundles.append(p)
                } else if isDirectory(p) {
                    // One level of grouping folders (/Applications/Utilities, /Applications/Adobe …).
                    for inner in (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? [] where inner.hasSuffix(".app") {
                        bundles.append(p + "/" + inner)
                    }
                }
            }
        }
        let sizes: [String: UInt64] = measureSizes
            ? Dictionary(uniqueKeysWithValues: CleanScanner.measure(bundles).map { ($0.path, $0.size) }) : [:]
        return bundles.compactMap { path -> InstalledApp? in
            guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { return nil }
            let info = bundle.infoDictionary ?? [:]
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let reason: String? = if id.hasPrefix("com.apple.") {
                String(localized: "Built-in Apple app, managed by macOS", bundle: .module)
            } else if id.hasPrefix("com.machelper.") {
                String(localized: "MacHelper itself", bundle: .module)
            } else { nil }
            return InstalledApp(
                name: name, bundleID: id, version: info["CFBundleShortVersionString"] as? String, path: path,
                size: sizes[path] ?? 0,
                isAppStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt"),
                lastUsed: lastUsedDate(path), isRunning: running.contains(id),
                teamID: CodeSignInfo.read(path)?.teamID, protectedReason: reason)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Matches by bundle id, exact name, or path. Throws if none or several match.
    public static func find(_ query: String, in apps: [InstalledApp]) throws -> InstalledApp {
        let q = query.lowercased()
        if let exact = apps.first(where: { $0.bundleID.lowercased() == q || $0.path == query
            || $0.path == expandTilde(query) }) { return exact }
        let byName = apps.filter { $0.name.lowercased() == q
            || (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() == q }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { throw UninstallError.ambiguous(query, byName.map(\.path)) }
        let fuzzy = apps.filter { $0.name.lowercased().contains(q) }
        if fuzzy.count == 1 { return fuzzy[0] }
        if fuzzy.isEmpty { throw UninstallError.notFound(query) }
        throw UninstallError.ambiguous(query, fuzzy.map(\.name))
    }

    // MARK: Leftovers of an installed app

    public static func plan(for app: InstalledApp, includeUserData: Bool = false,
                            otherApps: [InstalledApp] = installedApps(measureSizes: false)) -> UninstallPlan {
        LeftoverFinder(app: app, otherApps: otherApps).plan(includeUserData: includeUserData)
    }

    // MARK: Leftovers of apps that are already gone

    private static let orphanLocations: [(String, LeftoverKind)] = [
        ("Library/Containers", .container), ("Library/Application Scripts", .container),
        ("Library/Saved Application State", .savedState), ("Library/Caches", .cache),
        ("Library/HTTPStorages", .webData), ("Library/WebKit", .webData),
        ("Library/Preferences", .preferences), ("Library/LaunchAgents", .launchAgent),
    ]

    /// Items named after a bundle identifier whose app LaunchServices can no longer find.
    /// Heuristic: never preselected.
    public static func orphans(installed: [InstalledApp] = installedApps(measureSizes: false)) -> [UninstallItem] {
        let installedIDs = Set(installed.map(\.bundleID))
        var cache: [String: Bool] = [:]
        func appExists(_ id: String) -> Bool {
            if let c = cache[id] { return c }
            // An item may belong to an extension/helper of an installed app: com.foo.App.Helper → com.foo.App.
            var parts = id.split(separator: ".").map(String.init)
            var exists = false
            while parts.count >= 2 {
                let candidate = parts.joined(separator: ".")
                if installedIDs.contains(candidate) || NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) != nil {
                    exists = true
                    break
                }
                parts.removeLast()
            }
            cache[id] = exists
            return exists
        }

        var found: [(String, LeftoverKind)] = []
        for (dir, kind) in orphanLocations {
            let full = home + "/" + dir
            for e in (try? FileManager.default.contentsOfDirectory(atPath: full)) ?? [] {
                if kind == .launchAgent {
                    // Agents usually start command-line programs, not apps: orphaned only if the
                    // program they launch is gone.
                    if launchAgentProgramMissing(full + "/" + e) { found.append((full + "/" + e, kind)) }
                    continue
                }
                var id = e
                for ext in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(ext) { id = String(id.dropLast(ext.count)) }
                guard looksLikeBundleID(id), !id.hasPrefix("com.apple."), !id.hasPrefix("com.machelper."),
                      !id.hasPrefix("group."), !appExists(id) else { continue }
                found.append((full + "/" + e, kind))
            }
        }
        return CleanScanner.measure(found.map(\.0)).compactMap { m in
            guard let kind = found.first(where: { $0.0 == m.path })?.1, m.size > 0 else { return nil }
            return UninstallItem(path: m.path, kind: kind, size: m.size, selected: false, evidence: .orphan)
        }
        .sorted { $0.size > $1.size }
    }

    /// True when the agent's Program / ProgramArguments[0] / BundleProgram points at nothing.
    static func launchAgentProgramMissing(_ plistPath: String) -> Bool {
        guard let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else { return false }
        let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
        guard let program, program.hasPrefix("/") else {
            // Relative programs (resolved via PATH) or BundleProgram (relative to an app): can't tell, keep.
            return false
        }
        return !FileManager.default.fileExists(atPath: program)
    }

    static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    // MARK: Execution

    /// Leftovers: anything at least three levels into the home folder (Library/<area>/<item>),
    /// still never inside credentials or personal stores.
    public static var leftoverSafety: PathSafety {
        let keep = PathSafety.protectedInHome.filter {
            !["Library/Preferences", "Library/Group Containers", "Library/Cookies"].contains($0)
        }
        return PathSafety(protectedPaths: PathSafety.systemPaths + (keep + PathSafety.personalFolders).map { home + "/" + $0 },
                          whitelist: PathSafety.loadWhitelist(), allowedRoots: [home], minimumDepth: 3)
    }

    /// Unloads a user launch agent (best effort; not loaded is fine).
    static func bootOut(_ plistPath: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())", plistPath]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// App bundles: directly inside an Applications folder (or one grouping folder below).
    public static var bundleSafety: PathSafety {
        PathSafety(protectedPaths: PathSafety.systemPaths.filter { $0 != "/Applications" } + ["/Applications/Utilities"],
                   whitelist: PathSafety.loadWhitelist(), allowedRoots: appFolders, minimumDepth: 1)
    }

    /// Removes the selected items. `removeBundle` lets the app use NSWorkspace.recycle (which can ask for
    /// an administrator password for root-owned App Store apps); the CLI uses the default.
    public static func execute(_ plan: UninstallPlan, dryRun: Bool, permanent: Bool = false,
                               removeBundle: (@Sendable (URL) throws -> Void)? = nil) throws -> CleanReport {
        if let reason = plan.app.protectedReason { throw UninstallError.protected(reason) }
        if !dryRun, !NSRunningApplication.runningApplications(withBundleIdentifier: plan.app.bundleID).isEmpty {
            throw UninstallError.running(plan.app.name)
        }
        let selected = plan.items.filter(\.selected)
        let source = "uninstall.\(plan.app.bundleID)"
        if !dryRun {
            // A loaded agent keeps running after its plist is gone: stop it first.
            for agent in selected where agent.kind == .launchAgent { bootOut(agent.path) }
        }
        var outcomes: [ItemOutcome] = []
        var buckets: [RemovalArea: [RemovalItem]] = [:]
        for item in selected where item.kind != .appBundle {
            guard let area = RemovalArea(path: item.path) else {
                outcomes.append(ItemOutcome(path: item.path, source: source, bytes: 0, result: .skipped, message: "safety"))
                continue
            }
            buckets[area, default: []].append(RemovalItem(path: item.path, source: source, bytes: item.size, action: .trash))
        }
        for (area, items) in buckets.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            outcomes += CleanExecutor(safety: area.safety, permanent: permanent).execute(items, dryRun: dryRun, command: "uninstall").items
        }

        if let bundle = selected.first(where: { $0.kind == .appBundle }) {
            let item = RemovalItem(path: bundle.path, source: source, bytes: bundle.size, action: .trash)
            if let removeBundle, !dryRun, !permanent {
                // Custom remover still goes through the same safety check first.
                if bundleSafety.check(bundle.path) == .allowed {
                    do {
                        try removeBundle(URL(fileURLWithPath: bundle.path))
                        outcomes.append(ItemOutcome(path: bundle.path, source: item.source, bytes: bundle.size, result: .trashed, message: nil))
                    } catch {
                        outcomes.append(ItemOutcome(path: bundle.path, source: item.source, bytes: 0, result: .failed,
                                                    message: (error as NSError).localizedDescription))
                    }
                    OperationLog.shared.append(command: "uninstall", outcomes: [outcomes.last!])
                } else {
                    outcomes.append(ItemOutcome(path: bundle.path, source: item.source, bytes: 0, result: .skipped, message: "safety"))
                }
            } else {
                outcomes += CleanExecutor(safety: bundleSafety, permanent: permanent)
                    .execute([item], dryRun: dryRun, command: "uninstall").items
            }
        }
        return CleanReport(schemaVersion: 1, dryRun: dryRun, items: outcomes)
    }

    // MARK: Helpers

    static func isDirectory(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return value as? Date
    }
}
