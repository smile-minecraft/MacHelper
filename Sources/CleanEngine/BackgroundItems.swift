import Foundation

/// What macOS's Background Task Management database knows about login items, launch agents
/// and daemons (the list behind System Settings → General → Login Items). Read-only: it comes
/// from `sfltool dumpbtm`, whose text format is undocumented, so parsing is lenient and
/// unknown fields are ignored.
public struct BackgroundItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case app, loginItem, agent, daemon, legacyAgent, legacyDaemon, backgroundTask, developer, other
    }

    public let uid: Int
    public let uuid: String
    public let name: String?
    public let developerName: String?
    public let teamIdentifier: String?
    public let kind: Kind
    /// Raw type text, e.g. "legacy agent (0x10008)".
    public let typeLabel: String
    public let enabled: Bool
    public let allowed: Bool
    public let identifier: String
    public let url: String?
    public let executablePath: String?
    public let bundleIdentifier: String?
    public let parentIdentifier: String?
    public let lastUse: String?
    public var id: String { "\(uid)/\(uuid)" }

    static let genericExecutables = ["sh", "bash", "zsh", "fish", "osascript", "python", "node", "ruby", "perl", "env", "java", "deno", "bun"]

    /// Enabled by the app and allowed by the user (or by policy): it actually runs.
    public var isActive: Bool { enabled && allowed }

    /// Items people think of as "things that run in the background".
    public var isBackgroundWork: Bool {
        switch kind {
        case .loginItem, .agent, .daemon, .legacyAgent, .legacyDaemon, .backgroundTask: true
        case .app, .developer, .other: false
        }
    }

    /// Best label: name, else the last component of the identifier ("8.com.example.agent" → "com.example.agent").
    public var displayName: String {
        // A launchd job running "sh" or "python3.11" says more by its label.
        if let name, !name.isEmpty, !Self.genericExecutables.contains(where: { name == $0 || name.hasPrefix($0 + "3") }) { return name }
        if let dot = identifier.firstIndex(of: "."), identifier[..<dot].allSatisfy(\.isNumber) {
            return String(identifier[identifier.index(after: dot)...])
        }
        return identifier
    }
}

/// A parent (app or developer) and the background work registered under it.
public struct BackgroundItemGroup: Sendable, Identifiable, Hashable {
    public let parent: BackgroundItem?
    public let items: [BackgroundItem]
    public var id: String { parent?.id ?? "orphan/\(items.first?.id ?? "")" }
    public var title: String { parent?.displayName ?? items.first?.displayName ?? "?" }
    /// On when any of its items is enabled and allowed. A developer entry's own disposition does not reflect its items.
    public var enabled: Bool { items.contains(where: \.isActive) }
}

public enum BackgroundItems {
    public enum Failure: Error, Equatable, Sendable { case unavailable(String) }

    /// Runs `sfltool dumpbtm` in this process and returns this user's items plus the system-wide
    /// ones (UID -2 and 0).
    ///
    /// As a normal user sfltool asks for an administrator password on every run (it obtains
    /// `system.privilege.admin`). The app therefore never calls this; it gets the dump from the root
    /// Helper and uses `items(fromDump:)`. Only the CLI's explicit `login-items` command runs it.
    public static func read(uid: Int = Int(getuid()), timeout: TimeInterval = 20) -> Result<[BackgroundItem], Failure> {
        let tool = "/usr/bin/sfltool"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return .failure(.unavailable("sfltool not found")) }
        let (status, text) = MaintenanceRunner.exec([tool, "dumpbtm"], timeout: timeout)
        return items(fromDump: text, uid: uid, failureText: status == 0 ? nil : text)
    }

    /// Parses a `sfltool dumpbtm` dump (for example from the Helper) into this user's and the
    /// system-wide items.
    public static func items(fromDump text: String, uid: Int = Int(getuid()), failureText: String? = nil) -> Result<[BackgroundItem], Failure> {
        let items = parse(text).filter { $0.uid == uid || $0.uid == -2 || $0.uid == 0 }
        if items.isEmpty {
            return .failure(.unavailable(failureText.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)) } ?? "no records"))
        }
        return .success(items)
    }

    /// Active background items, the number the health check reports.
    public static func activeCount(_ items: [BackgroundItem], uid: Int = Int(getuid())) -> Int {
        groups(items, uid: uid).flatMap(\.items).filter(\.isActive).count
    }

    public static func parse(_ text: String) -> [BackgroundItem] {
        var items: [BackgroundItem] = []
        var uid: Int?
        var fields: [String: String] = [:]

        func flush() {
            defer { fields = [:] }
            guard let uid, let uuid = fields["UUID"], let identifier = fields["Identifier"] else { return }
            let type = fields["Type"] ?? ""
            let disposition = fields["Disposition"] ?? ""
            func value(_ key: String) -> String? {
                guard let v = fields[key], v != "(null)", !v.isEmpty else { return nil }
                return v
            }
            items.append(BackgroundItem(
                uid: uid, uuid: uuid, name: value("Name"), developerName: value("Developer Name"),
                teamIdentifier: value("Team Identifier"), kind: kind(type), typeLabel: type,
                enabled: dispositionFlag(disposition, "enabled"), allowed: dispositionFlag(disposition, "allowed"),
                identifier: identifier, url: value("URL"), executablePath: value("Executable Path"),
                bundleIdentifier: value("Bundle Identifier"), parentIdentifier: value("Parent Identifier"),
                lastUse: value("Last Use")))
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID ") {
                flush()
                let rest = line.dropFirst("Records for UID ".count)
                uid = Int(rest.prefix { $0 == "-" || $0.isNumber })
                continue
            }
            if line.hasPrefix("#"), line.hasSuffix(":"), raw.hasPrefix(" #") {
                flush()   // " #12:" starts an item; "    #1: id" (embedded identifiers) is indented deeper
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            guard !key.hasPrefix("#") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        flush()
        return items
    }

    /// Groups background work under its parent app or developer entry, enabled groups first.
    /// The same item can be listed for several UIDs; it is shown once.
    public static func groups(_ items: [BackgroundItem], uid: Int = Int(getuid())) -> [BackgroundItemGroup] {
        // This user's record of a parent wins over the system-wide copy.
        var parents: [String: BackgroundItem] = [:]
        for item in items.sorted(by: { ($0.uid == uid ? 0 : 1) < ($1.uid == uid ? 0 : 1) })
        where item.kind == .app || (item.kind == .developer && item.name != nil) {
            parents[item.identifier] = parents[item.identifier] ?? item
        }
        var seen = Set<String>()
        var grouped: [String: [BackgroundItem]] = [:]
        var order: [String] = []
        for item in items where item.isBackgroundWork {
            guard seen.insert("\(item.identifier)|\(item.url ?? "")|\(item.executablePath ?? "")").inserted else { continue }
            // Items without a named parent ("Unknown Developer") stand alone.
            let key = item.parentIdentifier.flatMap { parents[$0] != nil ? $0 : nil } ?? "orphan/\(item.id)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        return order.map { key in
            BackgroundItemGroup(parent: parents[key], items: grouped[key]!.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending })
        }
        .sorted { a, b in
            if a.enabled != b.enabled { return a.enabled }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    static func kind(_ type: String) -> BackgroundItem.Kind {
        let t = type.lowercased()
        if t.hasPrefix("legacy agent") { return .legacyAgent }
        if t.hasPrefix("legacy daemon") { return .legacyDaemon }
        if t.hasPrefix("login item") { return .loginItem }
        if t.hasPrefix("agent") { return .agent }
        if t.hasPrefix("daemon") { return .daemon }
        if t.hasPrefix("app") { return .app }
        if t.hasPrefix("developer") { return .developer }
        if t.hasPrefix("background") { return .backgroundTask }
        return .other
    }

    /// "[enabled, allowed, notified] (0xb)" → flags; "disabled"/"disallowed" must not match "enabled"/"allowed".
    static func dispositionFlag(_ disposition: String, _ flag: String) -> Bool {
        guard let open = disposition.firstIndex(of: "["), let close = disposition.firstIndex(of: "]"), open < close else { return false }
        return disposition[disposition.index(after: open)..<close]
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(flag)
    }
}
