import Darwin
import Foundation
import Security

/// Finds what an installed app left on disk.
///
/// Combines the approaches of Pearcleaner (normalized name / bundle-ID matching across many
/// locations, entitlements, team ID, UUID containers, vendor folders two levels deep) and Mole
/// (strict ownership proofs for launchd jobs and browser hosts, embedded helper IDs, channel and
/// version names with sibling checks, never taking a CLI tool's dot-folder for a same-named app).
/// Each hit records its evidence; only strong evidence is preselected.
struct LeftoverFinder {
    let app: InstalledApp
    let others: [InstalledApp]
    let fm = FileManager.default
    let home = MacHelperPaths.home.path

    // Identity
    let ownIDs: [String]          // lowercased: main bundle ID first, then embedded helpers / extensions
    let familyIDs: [String]
    let appGroups: [String]
    let teamID: String?           // only when no other installed app is signed by the same team
    let otherIDs: [String]
    let names: Set<String>        // normalized name variants (≥ 3 characters)
    let strictNames: Set<String>  // for the home folder and ~/Library root (≥ 4 characters)
    let crashNames: Set<String>   // executable and names, for crash report prefixes
    let vendor: String?           // normalized developer token from the bundle ID
    let vendorUnique: Bool
    let rule: AppRule?

    init(app: InstalledApp, otherApps: [InstalledApp]) {
        self.app = app
        let others = otherApps.filter { $0.bundleID != app.bundleID && $0.path != app.path }
        self.others = others
        let otherIDs = others.map { $0.bundleID.lowercased() }
        self.otherIDs = otherIDs
        let info = Bundle(path: app.path)?.infoDictionary ?? [:]
        let sign = CodeSignInfo.read(app.path)

        let main = app.bundleID.lowercased()
        var own = [main]
        for id in Self.embeddedBundleIDs(in: app.path) where !own.contains(id) && !otherIDs.contains(id) { own.append(id) }
        ownIDs = own

        let parts = main.split(separator: ".").map(String.init)
        if parts.count >= 4, Self.variantSuffixes.contains(parts.last!) {
            let parent = parts.dropLast().joined(separator: ".")
            familyIDs = otherIDs.contains { $0 == parent || $0.hasPrefix(parent + ".") } ? [] : [parent]
        } else {
            familyIDs = []
        }
        appGroups = sign?.appGroups.map { $0.lowercased() } ?? []
        if let team = sign?.teamID, !others.contains(where: { $0.teamID == team }) { teamID = team.lowercased() } else { teamID = nil }

        // Names: display name, CFBundleName, bundle file name, executable, their channel-less /
        // version-less base, and a bundle-ID leaf that extends the display name (AyuGramDesktop).
        var raw = [app.name, ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension]
        if let n = info["CFBundleName"] as? String { raw.append(n) }
        let executable = info["CFBundleExecutable"] as? String
        if let executable { raw.append(executable) }
        var variants: Set<String> = []
        for r in raw {
            variants.insert(Self.normalize(r))
            variants.insert(Self.normalize(Self.baseName(r)))
        }
        let displayNorm = Self.normalize(app.name)
        if let leaf = parts.dropFirst(2).last(where: { !Self.variantSuffixes.contains($0) }) {
            let l = Self.normalize(leaf)
            if l == displayNorm || (l.hasPrefix(displayNorm) && l.count >= 8) { variants.insert(l) }
        }
        // A sibling build (Zed vs Zed Nightly) owns the same name-derived folders: leave those alone.
        let taken = Set(others.flatMap { o in [Self.normalize(o.name), Self.normalize(Self.baseName(o.name)),
                                               Self.normalize(((o.path as NSString).lastPathComponent as NSString).deletingPathExtension)] })
        let usable = variants.subtracting(taken).filter { $0.count >= 3 && !Self.commonNames.contains($0) }
        names = usable
        strictNames = usable.filter { $0.count >= 4 }
        crashNames = usable.union(executable.map { [Self.normalize($0)] } ?? []).filter { $0.count >= 3 }

        if parts.count >= 3 {
            let org = Self.normalize(parts[1])
            let ok = org.count >= 4 && !Self.commonNames.contains(org) && !Self.genericVendors.contains(org)
            vendor = ok ? org : nil
            vendorUnique = ok && !otherIDs.contains { $0.split(separator: ".").dropFirst().first.map { Self.normalize(String($0)) } == org }
        } else {
            vendor = nil
            vendorUnique = false
        }
        rule = AppRules.shared.rule(for: app.bundleID)
    }

    // MARK: Plan

    private struct Hit {
        let path: String
        let kind: LeftoverKind
        let evidence: LeftoverEvidence
        var followsUserData = false
    }

    func plan(includeUserData: Bool) -> UninstallPlan {
        var hits: [Hit] = [Hit(path: app.path, kind: .appBundle, evidence: .bundleID)]
        var system: [String] = []
        var kept: [KeptLeftover] = []
        var seen: Set<String> = [app.path]
        let excluded = (rule?.exclude ?? []).flatMap { expandGlob($0) }
        func add(_ h: Hit) {
            guard !excluded.contains(h.path) else {
                kept.append(KeptLeftover(path: h.path, reason: String(localized: "MacHelper rule: doesn’t belong to this app", bundle: .module)))
                return
            }
            if seen.insert(h.path).inserted { hits.append(h) }
        }
        func addSystem(_ p: String) { if seen.insert(p).inserted { system.append(p) } }

        // 1. ~/Library areas.
        for area in Self.libraryAreas {
            let dir = home + "/" + area.dir
            for e in entries(dir) {
                if let ev = match(e, area.matchers) { add(Hit(path: dir + "/" + e, kind: area.kind, evidence: ev)) }
            }
            if area.matchers.contains(.vendorNested) { vendorNested(in: dir, kind: area.kind).forEach(add) }
        }
        // ~/Library/<Vendor>/<Product> and ~/Library/<Product>.
        let lib = home + "/Library"
        for e in entries(lib) where !Self.standardLibraryFolders.contains(e) && !Self.skipLibraryFolders.contains(e) {
            if strictNames.contains(Self.normalize(e)) { add(Hit(path: lib + "/" + e, kind: .appData, evidence: .name)) }
        }
        vendorNested(in: lib, kind: .appData, skip: Self.standardLibraryFolders.union(Self.skipLibraryFolders)).forEach(add)

        // 2. UUID-named containers whose metadata names the app or one of its extensions.
        let containers = lib + "/Containers"
        for e in entries(containers) where Self.isUUID(e) {
            let meta = containers + "/" + e + "/.com.apple.containermanagerd.metadata.plist"
            if let id = (NSDictionary(contentsOfFile: meta)?["MCMMetadataIdentifier"] as? String)?.lowercased(), ownIDs.contains(id) {
                add(Hit(path: containers + "/" + e, kind: .container, evidence: .containerMetadata))
            }
        }

        // 3. Group containers: App Groups, bundle IDs, and the team prefix.
        let gc = lib + "/Group Containers"
        for e in entries(gc) {
            let l = e.lowercased()
            if appGroups.contains(l) {
                add(Hit(path: gc + "/" + e, kind: .groupContainer, evidence: .appGroup))
            } else if let ev = idEvidence(l) {
                add(Hit(path: gc + "/" + e, kind: .groupContainer, evidence: ev))
            } else if let teamID, l.hasPrefix(teamID + ".") {
                add(Hit(path: gc + "/" + e, kind: .groupContainer, evidence: .teamID))
            }
        }

        // 4. Per-user Darwin cache and temp folders (/var/folders/…/C and T).
        for dir in RemovalArea.darwinUserDirs {
            for e in entries(dir) {
                if let ev = idEvidence(e.lowercased()) { add(Hit(path: dir + "/" + e, kind: .cache, evidence: ev)) }
            }
        }

        // 5. Browser native-messaging hosts that launch a program inside the app.
        for manifest in nativeMessagingManifests() where programIsInsideApp(manifestHostPath(manifest)) {
            add(Hit(path: manifest, kind: .plugin, evidence: .program))
        }

        // 6. Homebrew cask zap list and MacHelper's own per-app rules.
        for p in Homebrew.zapPaths(forAppAt: app.path) {
            if p.hasPrefix(home + "/") { add(Hit(path: p, kind: Self.kind(for: p, home: home), evidence: .homebrew)) } else { addSystem(p) }
        }
        for pattern in rule?.include ?? [] {
            for p in expandGlob(pattern) {
                if p.hasPrefix(home + "/") { add(Hit(path: p, kind: Self.kind(for: p, home: home), evidence: .rule)) } else { addSystem(p) }
            }
        }

        // 7. Command-line style data in the home folder (~/.hermes, ~/.config/hermes …), unless a
        //    separately installed command owns it (Mole #993: Claude.app vs the claude CLI's ~/.claude).
        for parent in Self.homeDataParents {
            let dir = parent.isEmpty ? home : home + "/" + parent
            for e in entries(dir) {
                let bare = parent.isEmpty ? (e.hasPrefix(".") ? String(e.dropFirst()) : "") : e
                guard !bare.isEmpty, strictNames.contains(Self.normalize(bare)) else { continue }
                let path = dir + "/" + e
                guard RemovalArea.isRemovableHomeData(path, home: home) else { continue }
                let ownData = hits.filter { $0.kind.mayContainUserData }.map(\.path)
                if let reason = independentOwner(of: path, name: bare, alsoOwned: ownData) {
                    kept.append(KeptLeftover(path: path, reason: reason))
                } else {
                    add(Hit(path: path, kind: .homeData, evidence: .name))
                }
            }
        }

        // 8. Launch agents and commands: owned when their program lives in the app; tied to the app's
        //    data when they run something from a data folder found above.
        let dataTargets = hits.filter { $0.kind.mayContainUserData }.map(\.path)
        func mentionsData(_ text: String) -> Bool {
            dataTargets.contains { text.contains($0 + "/") || text.hasSuffix($0) || text.contains($0 + "\"") || text.contains($0 + " ") }
        }
        let agents = lib + "/LaunchAgents"
        for e in entries(agents) where e.hasSuffix(".plist") {
            let path = agents + "/" + e
            guard !seen.contains(path), let job = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
            if let assoc = job["AssociatedBundleIdentifiers"] as? [String], assoc.contains(where: { ownIDs.contains($0.lowercased()) }) {
                add(Hit(path: path, kind: .launchAgent, evidence: .bundleID))
            } else if programIsInsideApp(Self.launchProgram(job)) {
                add(Hit(path: path, kind: .launchAgent, evidence: .program))
            } else if mentionsData(Self.launchCommand(job)) {
                add(Hit(path: path, kind: .launchAgent, evidence: .reference, followsUserData: true))
            }
        }
        let bin = home + "/.local/bin"
        for e in entries(bin) {
            let path = bin + "/" + e
            let target = Self.commandTarget(path)
            if programIsInsideApp(target) || target.contains(app.path + "/") {
                add(Hit(path: path, kind: .command, evidence: .program))
            } else if mentionsData(target) {
                add(Hit(path: path, kind: .command, evidence: .reference, followsUserData: true))
            }
        }

        // 9. System locations: listed for manual removal.
        for area in Self.systemAreas {
            for e in entries(area.dir) {
                let path = area.dir + "/" + e
                if match(e, area.matchers) != nil { addSystem(path); continue }
                if area.dir.hasSuffix("LaunchAgents") || area.dir.hasSuffix("LaunchDaemons"),
                   let job = NSDictionary(contentsOfFile: path) as? [String: Any], programIsInsideApp(Self.launchProgram(job)) {
                    addSystem(path)
                }
            }
            if area.matchers.contains(.vendorNested) { vendorNested(in: area.dir, kind: .appData).forEach { addSystem($0.path) } }
        }
        for e in entries("/private/var/db/receipts") where ownIDs.contains(where: { e.lowercased().hasPrefix($0) }) {
            addSystem("/private/var/db/receipts/" + e)
        }
        for dir in ["/usr/local/bin", "/opt/homebrew/bin"] {
            for e in entries(dir) {
                let p = dir + "/" + e
                if let dest = try? fm.destinationOfSymbolicLink(atPath: p), dest.hasPrefix(app.path + "/") { addSystem(p) }
            }
        }

        // Keep the outermost item when one hit contains another.
        let sorted = hits.sorted { $0.path < $1.path }
        var collapsed: [Hit] = []
        for h in sorted where !collapsed.contains(where: { h.path.hasPrefix($0.path + "/") }) { collapsed.append(h) }

        let sizes = Dictionary(CleanScanner.measure(collapsed.map(\.path)).map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        let items = collapsed.compactMap { h -> UninstallItem? in
            guard let size = sizes[h.path] else { return nil }
            let userData = h.followsUserData || h.kind.mayContainUserData
            let select = userData ? includeUserData
                : (h.evidence.isStrong || [.cache, .logs, .crashReport, .savedState].contains(h.kind))
            return UninstallItem(path: h.path, kind: h.kind, size: size, selected: select, evidence: h.evidence,
                                 followsUserData: userData)
        }
        let order = Dictionary(uniqueKeysWithValues: LeftoverKind.allCases.enumerated().map { ($1, $0) })
        return UninstallPlan(schemaVersion: 3, app: app,
                             items: items.sorted { (order[$0.kind]!, $0.path) < (order[$1.kind]!, $1.path) },
                             systemItems: system.sorted(), kept: kept)
    }

    // MARK: Matching

    enum Matcher: Hashable { case id, name, crash, vendorNested, vendorFolder }

    /// Evidence for a directory entry, or nil.
    func match(_ entry: String, _ matchers: Set<Matcher>) -> LeftoverEvidence? {
        let lower = entry.lowercased()
        let stem = Self.stripExtension(lower)
        if matchers.contains(.id), let ev = idEvidence(lower) ?? idEvidence(stem) { return ev }
        if matchers.contains(.name) {
            let n = Self.normalize(stem)
            if names.contains(n) || names.contains(where: { n == $0 + "updater" || n == $0 + "shipit" || Self.isVersioned(n, of: $0) }) {
                return .name
            }
        }
        if matchers.contains(.crash) {
            // "Hermes-2026-10-24-120000.ips", "Hermes_2026….crash", "IINA_<UUID>.plist"
            let head = lower.prefix { $0 != "-" && $0 != "_" && $0 != "." }
            if crashNames.contains(Self.normalize(String(head))) { return .name }
            if let ev = idEvidence(stem) { return ev }
        }
        if matchers.contains(.vendorFolder), vendorUnique, let vendor, Self.normalize(entry) == vendor { return .vendor }
        return nil
    }

    /// Bundle-ID evidence for a lowercased name: equal, or the ID as a dot-separated part of it
    /// (com.foo.app.ShipIt, group.com.foo.app, TEAM.com.foo.app), unless a longer ID of another
    /// installed app is what actually matches (com.foo.app.pro).
    func idEvidence(_ name: String) -> LeftoverEvidence? {
        for (list, ev) in [([ownIDs[0]], LeftoverEvidence.bundleID), (Array(ownIDs.dropFirst()), .embeddedID), (familyIDs, .family)] {
            for id in list where Self.contains(name, id: id) {
                if otherIDs.contains(where: { $0.count > id.count && $0.contains(id) && Self.contains(name, id: $0) }) { continue }
                return ev
            }
        }
        return nil
    }

    static func contains(_ name: String, id: String) -> Bool {
        name == id || name.hasPrefix(id + ".") || name.hasSuffix("." + id) || name.contains("." + id + ".")
    }

    /// <dir>/<Vendor>/<Product>: the product folder when the vendor has other installed apps,
    /// the whole vendor folder when this is its only one.
    private func vendorNested(in dir: String, kind: LeftoverKind, skip: Set<String> = []) -> [Hit] {
        guard let vendor else { return [] }
        var out: [Hit] = []
        for e in entries(dir) where !skip.contains(e) && Self.normalize(e) == vendor {
            let vendorDir = dir + "/" + e
            guard AppUninstaller.isDirectory(vendorDir) else { continue }
            if vendorUnique {
                out.append(Hit(path: vendorDir, kind: kind, evidence: .vendor))
                continue
            }
            for child in entries(vendorDir) {
                let n = Self.normalize(Self.stripExtension(child.lowercased()))
                if names.contains(n) || names.contains(where: { Self.isVersioned(n, of: $0) }) {
                    out.append(Hit(path: vendorDir + "/" + child, kind: kind, evidence: .name))
                } else if let ev = idEvidence(child.lowercased()) {
                    out.append(Hit(path: vendorDir + "/" + child, kind: kind, evidence: ev))
                }
            }
        }
        return out
    }

    /// Why a home-folder candidate belongs to something else, if it does.
    func independentOwner(of path: String, name: String, alsoOwned: [String] = []) -> String? {
        let lname = name.lowercased()
        if AppRules.shared.independentCLIs.contains(lname) {
            return String(localized: "~/\((path as NSString).lastPathComponent) belongs to the separately installed command-line tool \(lname) and isn’t removed with the app", bundle: .module)
        }
        if fm.fileExists(atPath: path + "/.git") {
            return String(localized: "It’s a git repository, possibly your own settings or project", bundle: .module)
        }
        for dir in Self.commandDirs(home: home) {
            let cmd = dir + "/" + lname
            guard fm.fileExists(atPath: cmd) || (try? fm.destinationOfSymbolicLink(atPath: cmd)) != nil else { continue }
            let target = Self.commandTarget(cmd)
            let resolved = URL(fileURLWithPath: cmd).resolvingSymlinksInPath().path
            // The command is part of this install when it runs from the app or from data already found for it.
            let ownedHere = ([path, app.path] + alsoOwned).contains { target.contains($0 + "/") || resolved.hasPrefix($0 + "/") }
            if !ownedHere { return String(localized: "The command \(Fmt.short(cmd, home: home)) also uses it; it may be a separately installed command-line tool", bundle: .module) }
        }
        return nil
    }

    // MARK: Ownership proofs

    func programIsInsideApp(_ program: String?) -> Bool {
        guard let program, program.hasPrefix("/"), !program.contains("/../") else { return false }
        let real = URL(fileURLWithPath: program).resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path
        return real.hasPrefix(root + "/") || program.hasPrefix(app.path + "/")
    }

    private func nativeMessagingManifests() -> [String] {
        let support = home + "/Library/Application Support"
        var dirs: [String] = []
        for e in entries(support) {
            let d = support + "/" + e
            if AppUninstaller.isDirectory(d + "/NativeMessagingHosts") { dirs.append(d + "/NativeMessagingHosts") }
            for inner in entries(d) where AppUninstaller.isDirectory(d + "/" + inner + "/NativeMessagingHosts") {
                dirs.append(d + "/" + inner + "/NativeMessagingHosts")
            }
        }
        return dirs.flatMap { d in entries(d).filter { $0.hasSuffix(".json") }.map { d + "/" + $0 } }
    }

    private func manifestHostPath(_ manifest: String) -> String? {
        guard let attrs = try? fm.attributesOfItem(atPath: manifest), (attrs[.size] as? Int ?? .max) < 65_536,
              let data = fm.contents(atPath: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["path"] as? String
    }

    private func entries(_ dir: String) -> [String] {
        (try? fm.contentsOfDirectory(atPath: dir)) ?? []
    }

    // MARK: Identity helpers

    /// Bundle IDs of helpers, login items, XPC services and extensions inside the app (bounded walk).
    static func embeddedBundleIDs(in appPath: String) -> [String] {
        let contents = URL(fileURLWithPath: appPath + "/Contents")
        guard let walker = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var ids: [String] = []
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 4000 || ids.count >= 128 { break }
            let name = url.lastPathComponent
            if ["Resources", "_CodeSignature", "Headers", "Modules", "node_modules", "MacOS"].contains(name) || name.hasSuffix(".lproj") {
                walker.skipDescendants()
                continue
            }
            if walker.level > 8 { walker.skipDescendants(); continue }
            let ext = url.pathExtension.lowercased()
            let isBundle = ["xpc", "appex", "systemextension"].contains(ext)
                || (ext == "app" && (url.path.contains("/Contents/Library/LoginItems/") || url.path.contains("/Contents/Frameworks/")))
                || ext == "framework"
            guard isBundle else { continue }
            if ext != "framework", let id = Bundle(url: url)?.bundleIdentifier?.lowercased(),
               !id.hasPrefix("com.apple."), !id.hasPrefix("org.sparkle-project."), !ids.contains(id) {
                ids.append(id)
            }
            if ext == "framework" {
                // Frameworks can carry XPC services and helper apps in Versions/A/…; look inside them.
                for sub in ["Versions/A/XPCServices", "XPCServices", "Versions/A/Helpers", "Helpers"] {
                    for e in (try? FileManager.default.contentsOfDirectory(atPath: url.path + "/" + sub)) ?? [] {
                        if let id = Bundle(path: url.path + "/" + sub + "/" + e)?.bundleIdentifier?.lowercased(),
                           !id.hasPrefix("com.apple."), !id.hasPrefix("org.sparkle-project."), !ids.contains(id) { ids.append(id) }
                    }
                }
            }
        }
        return ids
    }

    /// Lowercase letters and digits only: "Hermes Agent", "hermes-agent" and "HermesAgent" all match.
    static func normalize(_ s: String) -> String {
        String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// "Zed Nightly" → "Zed", "Bartender 6" → "Bartender", "Firefox Developer Edition" → "Firefox".
    static func baseName(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespaces)
        for suffix in [" developer edition", " community edition", " nightly", " insiders", " preview", " canary", " beta",
                       " alpha", " dev", " rc", " ce", " lite"] where out.lowercased().hasSuffix(suffix) {
            out = String(out.dropLast(suffix.count))
        }
        return out.replacingOccurrences(of: #"\s+v?\d+(\.\d+)*$"#, with: "", options: .regularExpression)
    }

    static let knownExtensions: Set<String> = ["plist", "savedstate", "binarycookies", "sfl", "sfl2", "sfl3", "sfl4", "json",
                                               "log", "txt", "app", "plugin", "prefpane", "workflow", "qlgenerator", "saver",
                                               "mdimporter", "component", "vst", "vst3", "bundle", "ips", "crash", "hang",
                                               "diag", "spin", "colorpicker", "mailbundle", "appex", "driver", "kext"]

    static func stripExtension(_ s: String) -> String {
        let ext = (s as NSString).pathExtension
        return knownExtensions.contains(ext) ? (s as NSString).deletingPathExtension : s
    }

    /// "anki2" for "anki", "sibelius2024" for "sibelius": a name followed only by a short version number.
    static func isVersioned(_ n: String, of name: String) -> Bool {
        name.count >= 4 && n.hasPrefix(name) && (1...4).contains(n.count - name.count) && n.dropFirst(name.count).allSatisfy(\.isNumber)
    }

    static func isUUID(_ s: String) -> Bool {
        s.count == 36 && s.range(of: #"^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil
    }

    /// Last bundle-ID components that name a variant or helper of a product rather than the product.
    static let variantSuffixes: Set<String> = ["setup", "installer", "uninstaller", "launcher", "helper", "agent", "daemon",
                                               "service", "xpc", "updater", "login", "extension", "plugin", "desktop", "app",
                                               "mac", "macos", "osx", "client", "electron", "main", "gui"]

    /// Names too common to identify one app's folders (Mole's list plus generic folder names).
    static let commonNames: Set<String> = [
        "music", "notes", "photos", "finder", "safari", "preview", "calendar", "contacts", "messages", "reminders", "clock",
        "weather", "stocks", "books", "news", "podcasts", "voice", "files", "store", "system", "helper", "agent", "daemon",
        "service", "update", "sync", "backup", "cloud", "manager", "monitor", "server", "client", "worker", "runner",
        "launcher", "driver", "plugin", "extension", "widget", "utility", "app", "apps", "data", "cache", "caches", "config",
        "local", "share", "state", "bin", "lib", "tmp", "temp", "logs", "node", "python", "java", "ruby", "git", "code",
        "docker", "setup", "desktop", "studio", "editor", "player", "viewer", "tools", "browser", "application", "macos",
        "terminal", "mail", "home", "keychain", "library", "support", "documents", "downloads",
    ]

    /// Bundle-ID organisation parts that are platforms or hosts, not a developer.
    static let genericVendors: Set<String> = ["github", "gitlab", "electron", "electronjs", "apple", "example", "company",
                                              "developer", "unknown", "personal", "mycompany", "yourcompany", "sindresorhus"]

    // MARK: Locations

    struct Area {
        let dir: String
        let kind: LeftoverKind
        let matchers: Set<Matcher>
    }

    static let libraryAreas: [Area] = [
        Area(dir: "Library/Application Support", kind: .appData, matchers: [.id, .name, .vendorNested, .vendorFolder]),
        Area(dir: "Library/Caches", kind: .cache, matchers: [.id, .name, .vendorNested, .vendorFolder]),
        Area(dir: "Library/Logs", kind: .logs, matchers: [.id, .name, .vendorNested, .vendorFolder]),
        Area(dir: "Library/Preferences", kind: .preferences, matchers: [.id, .name]),
        Area(dir: "Library/Preferences/ByHost", kind: .preferences, matchers: [.id]),
        Area(dir: "Library/SyncedPreferences", kind: .preferences, matchers: [.id]),
        Area(dir: "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
             kind: .preferences, matchers: [.id]),
        Area(dir: "Library/Saved Application State", kind: .savedState, matchers: [.id, .name]),
        Area(dir: "Library/HTTPStorages", kind: .webData, matchers: [.id]),
        Area(dir: "Library/WebKit", kind: .webData, matchers: [.id]),
        Area(dir: "Library/Cookies", kind: .webData, matchers: [.id]),
        Area(dir: "Library/LaunchAgents", kind: .launchAgent, matchers: [.id]),
        Area(dir: "Library/Containers", kind: .container, matchers: [.id]),
        Area(dir: "Library/Application Scripts", kind: .container, matchers: [.id]),
        Area(dir: "Library/Logs/DiagnosticReports", kind: .crashReport, matchers: [.crash]),
        Area(dir: "Library/Logs/DiagnosticReports/Retired", kind: .crashReport, matchers: [.crash]),
        Area(dir: "Library/Application Support/CrashReporter", kind: .crashReport, matchers: [.crash]),
        // Crash and analytics frameworks keep one folder per host app.
        Area(dir: "Library/Caches/com.crashlytics.data", kind: .cache, matchers: [.id, .name]),
        Area(dir: "Library/Caches/com.plausiblelabs.crashreporter.data", kind: .cache, matchers: [.id, .name]),
        Area(dir: "Library/Caches/SentryCrash", kind: .cache, matchers: [.id, .name]),
        Area(dir: "Library/Caches/KSCrash", kind: .cache, matchers: [.id, .name]),
        Area(dir: "Library/Application Support/com.bugsnag.Bugsnag", kind: .cache, matchers: [.id]),
        // Plug-ins and extensions installed per user.
        Area(dir: "Library/Internet Plug-Ins", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "Library/PreferencePanes", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "Library/Services", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "Library/QuickLook", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "Library/Screen Savers", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "Library/Spotlight", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "Library/Input Methods", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "Library/ColorPickers", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "Library/Contextual Menu Items", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "Library/Audio/Plug-Ins/Components", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "Library/Audio/Plug-Ins/VST", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "Library/Audio/Plug-Ins/VST3", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "Library/Audio/Plug-Ins/HAL", kind: .plugin, matchers: [.id, .name]),
    ]

    static let systemAreas: [Area] = [
        Area(dir: "/Library/Application Support", kind: .appData, matchers: [.id, .name, .vendorNested, .vendorFolder]),
        Area(dir: "/Library/Caches", kind: .cache, matchers: [.id, .name]),
        Area(dir: "/Library/Logs", kind: .logs, matchers: [.id, .name]),
        Area(dir: "/Library/Preferences", kind: .preferences, matchers: [.id]),
        Area(dir: "/Library/LaunchAgents", kind: .launchAgent, matchers: [.id]),
        Area(dir: "/Library/LaunchDaemons", kind: .launchAgent, matchers: [.id]),
        Area(dir: "/Library/PrivilegedHelperTools", kind: .launchAgent, matchers: [.id]),
        Area(dir: "/Library/Extensions", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "/Library/Internet Plug-Ins", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "/Library/PreferencePanes", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "/Library/Screen Savers", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "/Library/Audio/Plug-Ins/Components", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "/Library/Audio/Plug-Ins/HAL", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "/Library/Audio/Plug-Ins/VST", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "/Library/Audio/Plug-Ins/VST3", kind: .plugin, matchers: [.id, .name]),
        Area(dir: "/Users/Shared", kind: .appData, matchers: [.id, .name]),
    ]

    /// Standard ~/Library folders (never a vendor folder themselves).
    static let standardLibraryFolders: Set<String> = [
        "Application Scripts", "Application Support", "Caches", "Containers", "Group Containers", "HTTPStorages",
        "Internet Plug-Ins", "LaunchAgents", "LaunchDaemons", "Logs", "Preferences", "PreferencePanes",
        "PrivilegedHelperTools", "Saved Application State", "Services", "WebKit", "Extensions", "Frameworks", "Cookies",
        "Audio", "QuickLook", "Screen Savers", "Spotlight", "Input Methods", "ColorPickers", "Contextual Menu Items",
        "SyncedPreferences",
    ]

    /// ~/Library folders that hold system or personal data, never one third-party app's leftovers (from Pearcleaner).
    static let skipLibraryFolders: Set<String> = [
        "Apple", "Bluetooth", "ColorSync", "Components", "CoreAnalytics", "CoreMediaIO", "DirectoryServices", "Filesystems",
        "GPUBundles", "Graphics", "KernelCollections", "OSAnalytics", "OpenDirectory", "Sandbox", "Security",
        "SystemExtensions", "SystemMigration", "SystemProfiler", "StagedDriverExtensions", "StagedExtensions", "StartupItems",
        "Accessibility", "Accounts", "AppleMediaServices", "Assistant", "Assistants", "Autosave Information", "Biome",
        "Calendars", "CallServices", "CloudStorage", "Contacts", "DataAccess", "DataDeliveryServices", "DoNotDisturb",
        "DuetExpertCenter", "Finance", "FinanceBackup", "FrontBoard", "GameKit", "GroupContainersAlias", "HomeKit",
        "IdentityServices", "IntelligencePlatform", "Intents", "KeyboardServices", "LanguageModeling", "LockdownMode",
        "Mail", "MediaAnalysis", "Messages", "Metadata", "Mobile Documents", "MobileDevice", "News", "Passes",
        "PersonalizationPortrait", "Photos", "PrivateCloudCompute", "Reminders", "ResponseKit", "Safari",
        "SafariSafeBrowsing", "SafariSandboxBroker", "ScreenRecordings", "StatusKit", "Suggestions", "Translation",
        "UnifiedAssetFramework", "Weather", "homeenergyd", "studentd", "Developer", "Perl", "Ruby", "Java", "Python",
        "Catacomb", "InstallerSandboxes", "Trial", "Updates", "Staging", "ContainerManager", "Daemon Containers",
        "Colors", "Compositions", "Documentation", "DriverExtensions", "Favorites", "FontCollections", "Fonts",
        "Image Capture", "Keyboard", "Keyboard Layouts", "Keychains", "Managed Preferences", "PDF Services", "Printers",
        "Receipts", "ScriptingAdditions", "Scripts", "Sharing", "Shortcuts", "Sounds", "Speech", "Spelling",
        "User Pictures", "User Template", "Video", "WebServer", "Workflows", "Group Containers", "Mobile Documents",
    ]

    static let homeDataParents = ["", ".config", ".local/share", ".local/state", ".cache"]

    static func commandDirs(home: String) -> [String] {
        [home + "/.local/bin", home + "/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.npm-global/bin",
         home + "/.bun/bin", home + "/.cargo/bin", home + "/go/bin", home + "/.deno/bin"]
    }

    /// Classifies a path given by Homebrew or a rule.
    static func kind(for path: String, home: String) -> LeftoverKind {
        let rel = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        let table: [(String, LeftoverKind)] = [
            ("Library/Caches", .cache), ("Library/Logs/DiagnosticReports", .crashReport), ("Library/Logs", .logs),
            ("Library/Application Support/CrashReporter", .crashReport), ("Library/Preferences", .preferences),
            ("Library/Application Support/com.apple.sharedfilelist", .preferences), ("Library/Saved Application State", .savedState),
            ("Library/HTTPStorages", .webData), ("Library/WebKit", .webData), ("Library/Cookies", .webData),
            ("Library/LaunchAgents", .launchAgent), ("Library/Containers", .container), ("Library/Application Scripts", .container),
            ("Library/Group Containers", .groupContainer), ("Library/Application Support", .appData), (".local/bin", .command),
        ]
        if let k = table.first(where: { rel.hasPrefix($0.0 + "/") }) { return k.1 }
        return rel.hasPrefix(".") ? .homeData : .appData
    }

    // MARK: launchd and command helpers

    /// The program a launchd job runs: Program, else ProgramArguments[0].
    static func launchProgram(_ job: [String: Any]) -> String? {
        (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first
    }

    /// Program and arguments of a launchd job as one string, for spotting data paths in it.
    static func launchCommand(_ job: [String: Any]) -> String {
        var parts: [String] = []
        if let p = job["Program"] as? String { parts.append(p) }
        if let a = job["ProgramArguments"] as? [String] { parts += a }
        return parts.joined(separator: " ")
    }

    /// Where a command leads: a symlink's destination, or a small wrapper script's text.
    static func commandTarget(_ path: String) -> String {
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            return dest.hasPrefix("/") ? dest : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest)
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.size] as? Int ?? .max) < 16_384,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return text
    }
}

private enum Fmt {
    static func short(_ p: String, home: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
}

// MARK: - Removal areas

/// Where an uninstall may remove things, each with its own safety rules.
enum RemovalArea: Int, Hashable, CaseIterable {
    case library, libraryRoot, home, darwin

    static let homePath = MacHelperPaths.home.path

    static let darwinUserDirs: [String] = [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].compactMap { name in
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buf, buf.count) > 0 else { return nil }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return PathSafety.normalize(String(decoding: bytes, as: UTF8.self))
    }

    init?(path: String) {
        let home = Self.homePath
        let p = PathSafety.normalize(path)
        if Self.darwinUserDirs.contains(where: { p.hasPrefix($0 + "/") }) { self = .darwin; return }
        guard p.hasPrefix(home + "/") else { return nil }
        let comps = p.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        if comps.first == "Library" {
            if comps.count >= 3 { self = .library; return }
            if comps.count == 2, !LeftoverFinder.standardLibraryFolders.contains(comps[1]),
               !LeftoverFinder.skipLibraryFolders.contains(comps[1]) { self = .libraryRoot; return }
            return nil
        }
        if Self.isRemovableHomeData(p, home: home) { self = .home; return }
        return nil
    }

    var safety: PathSafety {
        let home = Self.homePath
        switch self {
        case .library: return AppUninstaller.leftoverSafety
        case .libraryRoot:
            let s = AppUninstaller.leftoverSafety
            return PathSafety(protectedPaths: s.protectedPaths, whitelist: s.whitelist, allowedRoots: [home + "/Library"], minimumDepth: 1)
        case .home:
            let keep = ["Library", ".ssh", ".gnupg", ".aws", ".kube", ".docker", ".netrc", ".Trash"] + PathSafety.personalFolders
            return PathSafety(protectedPaths: PathSafety.systemPaths + keep.map { home + "/" + $0 },
                              whitelist: PathSafety.loadWhitelist(), allowedRoots: [home], minimumDepth: 1)
        case .darwin:
            return PathSafety(protectedPaths: [], whitelist: PathSafety.loadWhitelist(), allowedRoots: Self.darwinUserDirs, minimumDepth: 1)
        }
    }

    /// Home entries that are shared infrastructure or credentials, never one app's leftovers.
    static let reservedHomeEntries: Set<String> = [".ssh", ".gnupg", ".aws", ".kube", ".docker", ".netrc", ".Trash",
                                                    ".config", ".local", ".cache", ".npm", ".git", ".zsh_sessions",
                                                    ".CFUserTextEncoding", ".DS_Store", ".zshrc", ".bashrc", ".profile",
                                                    ".zprofile", ".gitconfig", ".bash_profile"]

    /// A "."-folder directly in the home directory (not shared infrastructure), or one entry inside
    /// ~/.config, ~/.local/share, ~/.local/state, ~/.cache or ~/.local/bin.
    static func isRemovableHomeData(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        let comps = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        if comps.count == 1 { return comps[0].hasPrefix(".") && !reservedHomeEntries.contains(comps[0]) }
        let parent = comps.dropLast().joined(separator: "/")
        return (LeftoverFinder.homeDataParents.contains(parent) || parent == ".local/bin") && !comps.last!.hasPrefix(".")
    }
}

// MARK: - Code signature

struct CodeSignInfo {
    let teamID: String?
    let appGroups: [String]

    static func read(_ appPath: String) -> CodeSignInfo? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let ents = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let groups = (ents["com.apple.security.application-groups"] as? [String] ?? [])
        return CodeSignInfo(teamID: dict[kSecCodeInfoTeamIdentifier as String] as? String, appGroups: groups)
    }
}

// MARK: - Per-app rules

struct AppRule: Decodable, Sendable {
    let bundleID: String
    let include: [String]?
    let exclude: [String]?
}

/// Hand-written rules for apps whose data doesn't follow any naming convention
/// (Resources/UninstallRules/apps.json).
struct AppRules: Sendable {
    let apps: [AppRule]
    let independentCLIs: Set<String>

    static let shared: AppRules = {
        struct File: Decodable { let apps: [AppRule]; let independentCLIs: [String] }
        guard let url = Bundle.module.url(forResource: "UninstallRules", withExtension: nil)?.appending(path: "apps.json"),
              let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            return AppRules(apps: [], independentCLIs: ["claude", "codex", "gemini", "opencode"])
        }
        return AppRules(apps: file.apps, independentCLIs: Set(file.independentCLIs.map { $0.lowercased() }))
    }()

    func rule(for bundleID: String) -> AppRule? {
        apps.first { $0.bundleID.lowercased() == bundleID.lowercased() }
    }
}

// MARK: - Homebrew

/// Reads the `zap` stanza of the Homebrew cask that installed an app: a hand-maintained list of the
/// app's leftovers.
enum Homebrew {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (date: Date, zaps: [String: [String]])?

    static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Paths (globs expanded) the cask for this app would zap; empty if not installed by Homebrew.
    static func zapPaths(forAppAt appPath: String) -> [String] {
        let appName = (appPath as NSString).lastPathComponent
        let patterns = zapsByApp()[appName] ?? []
        return patterns.flatMap { expandGlob($0) }
    }

    /// App bundle name → zap patterns, for every installed cask. Cached for 10 minutes.
    static func zapsByApp() -> [String: [String]] {
        lock.lock()
        defer { lock.unlock() }
        if let c = cache, Date().timeIntervalSince(c.date) < 600 { return c.zaps }
        var result: [String: [String]] = [:]
        if let brew, let data = run(brew, ["info", "--cask", "--json=v2", "--installed"], timeout: 20),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let casks = json["casks"] as? [[String: Any]] {
            for cask in casks {
                let artifacts = cask["artifacts"] as? [[String: Any]] ?? []
                let apps = artifacts.compactMap { $0["app"] as? [Any] }.flatMap { $0 }.compactMap { $0 as? String }
                var zap: [String] = []
                for a in artifacts {
                    for stanza in a["zap"] as? [[String: Any]] ?? [] {
                        for key in ["trash", "delete", "rmdir"] {
                            if let s = stanza[key] as? String { zap.append(s) }
                            if let list = stanza[key] as? [String] { zap += list }
                        }
                    }
                }
                for app in apps { result[(app as NSString).lastPathComponent, default: []] += zap }
            }
        }
        cache = (Date(), result)
        return result
    }

    static func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_INSTALL_FROM_API"] = nil
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return p.terminationStatus == 0 ? data : nil
    }
}
