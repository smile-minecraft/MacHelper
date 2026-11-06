import Foundation

/// One macOS security setting, read without changing anything.
public struct SecurityCheck: Codable, Sendable, Identifiable, Equatable {
    public enum State: String, Codable, Sendable { case on, off, partial, unknown, info }

    public let id: String
    public let state: State
    /// A short reading such as "Version 5347, installed 18 June 2026" (English; the app shows its own text per id and state).
    public let detail: String?

    public init(id: String, state: State, detail: String? = nil) {
        self.id = id
        self.state = state
        self.detail = detail
    }
}

/// Reads Gatekeeper, FileVault, the firewall, System Integrity Protection, XProtect and automatic
/// security updates with Apple's own read-only status commands. Nothing here needs administrator rights.
public enum SecurityAudit {
    public static let ids = ["gatekeeper", "filevault", "firewall", "sip", "updates", "xprotect"]

    public static func run() -> [SecurityCheck] {
        var out: [SecurityCheck] = []
        let group = DispatchGroup()
        let lock = NSLock()
        func add(_ c: SecurityCheck) { lock.lock(); out.append(c); lock.unlock() }
        let jobs: [() -> SecurityCheck] = [
            { gatekeeper(tool("/usr/sbin/spctl", ["--status"])) },
            { fileVault(tool("/usr/bin/fdesetup", ["status"])) },
            { firewall(tool("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]),
                       stealth: tool("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getstealthmode"])) },
            { sip(tool("/usr/bin/csrutil", ["status"])) },
            { automaticUpdates(plist("/Library/Preferences/com.apple.SoftwareUpdate.plist")) },
            { xprotect(tool("/usr/bin/xprotect", ["version"]),
                       bundleVersion: plist("/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) },
        ]
        for job in jobs {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { add(job()); group.leave() }
        }
        group.wait()
        return ids.compactMap { id in out.first { $0.id == id } }
    }

    // MARK: Parsers (internal for tests)

    static func gatekeeper(_ s: String?) -> SecurityCheck {
        guard let s = s?.lowercased() else { return .init(id: "gatekeeper", state: .unknown) }
        if s.contains("assessments enabled") { return .init(id: "gatekeeper", state: .on) }
        if s.contains("assessments disabled") { return .init(id: "gatekeeper", state: .off) }
        return .init(id: "gatekeeper", state: .unknown, detail: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func fileVault(_ s: String?) -> SecurityCheck {
        guard let s = s?.lowercased() else { return .init(id: "filevault", state: .unknown) }
        if s.contains("encryption in progress") || s.contains("decryption in progress") {
            return .init(id: "filevault", state: .partial, detail: s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if s.contains("filevault is on") { return .init(id: "filevault", state: .on) }
        if s.contains("filevault is off") { return .init(id: "filevault", state: .off) }
        return .init(id: "filevault", state: .unknown)
    }

    static func firewall(_ s: String?, stealth: String?) -> SecurityCheck {
        guard let s = s?.lowercased() else { return .init(id: "firewall", state: .unknown) }
        let stealthOn = stealth?.lowercased().contains("stealth mode is on") == true || stealth?.lowercased().contains("stealth mode enabled") == true
        // "Firewall is enabled. (State = 1)", "(State = 2)" blocks all incoming connections.
        if s.contains("disabled") || s.contains("state = 0") { return .init(id: "firewall", state: .off) }
        if s.contains("enabled") || s.contains("state = 1") || s.contains("state = 2") || s.contains("blocking all") {
            return .init(id: "firewall", state: .on, detail: stealthOn ? "stealth" : nil)
        }
        return .init(id: "firewall", state: .unknown)
    }

    static func sip(_ s: String?) -> SecurityCheck {
        guard let s = s?.lowercased() else { return .init(id: "sip", state: .unknown) }
        if s.contains("status: enabled") {
            // A custom configuration prints "enabled (Custom Configuration)" with some protections off.
            return .init(id: "sip", state: s.contains("custom") ? .partial : .on)
        }
        if s.contains("status: disabled") { return .init(id: "sip", state: .off) }
        return .init(id: "sip", state: .unknown)
    }

    /// Security responses and system data files install by themselves unless turned off; a missing key means on.
    static func automaticUpdates(_ prefs: [String: Any]?) -> SecurityCheck {
        guard let prefs else { return .init(id: "updates", state: .unknown) }
        func flag(_ k: String) -> Bool { (prefs[k] as? Bool) ?? (prefs[k] as? Int).map { $0 != 0 } ?? true }
        let critical = flag("CriticalUpdateInstall"), config = flag("ConfigDataInstall")
        if critical && config { return .init(id: "updates", state: .on) }
        if !critical && !config { return .init(id: "updates", state: .off) }
        return .init(id: "updates", state: .partial, detail: critical ? "config-off" : "critical-off")
    }

    /// "Version: 5347 Installed: 2026-06-18 01:12:21 +0000"; older systems only have the bundle.
    static func xprotect(_ s: String?, bundleVersion: String?) -> SecurityCheck {
        if let s, let r = s.range(of: #"Version:\s*(\S+)"#, options: .regularExpression) {
            let version = s[r].split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            var detail = version
            if let i = s.range(of: #"Installed:\s*\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
                detail += " " + s[i].replacingOccurrences(of: "Installed:", with: "").trimmingCharacters(in: .whitespaces)
            }
            return .init(id: "xprotect", state: .info, detail: detail)
        }
        if let bundleVersion { return .init(id: "xprotect", state: .info, detail: bundleVersion) }
        return .init(id: "xprotect", state: .unknown)
    }

    // MARK: Reading

    static func tool(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    static func plist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
