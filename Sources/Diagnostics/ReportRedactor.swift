import Darwin
import Foundation

/// The identity values a report must not reveal. Defaults to this Mac; tests inject a fixed profile.
public struct RedactionProfile: Sendable, Equatable {
    public let username: String
    public let homeDirectory: String
    public let hostNames: [String]

    public init(username: String, homeDirectory: String, hostNames: [String]) {
        self.username = username
        self.homeDirectory = homeDirectory
        self.hostNames = hostNames
    }

    public static var system: RedactionProfile {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = NSUserName()
        var names: [String] = []
        func add(_ value: String?) {
            guard let value, !value.isEmpty, !names.contains(value) else { return }
            names.append(value)
        }
        let host = Host.current()
        add(host.name)
        add(host.localizedName)
        add(ProcessInfo.processInfo.hostName)
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            add(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        // "name.local" and "name" are the same machine; both must disappear.
        for name in names {
            add(name.split(separator: ".").first.map(String.init))
        }
        return RedactionProfile(username: user, homeDirectory: home, hostNames: names)
    }
}

/// Scrubs personal identity from diagnostic text while leaving the numbers an agent needs alone.
///
/// Every pattern is idempotent: applying the redactor to its own output changes nothing. That makes
/// it safe to redact a value twice (for example once in a section and once in a rendered summary).
public struct ReportRedactor: Sendable {
    public let profile: RedactionProfile

    public init(profile: RedactionProfile = .system) { self.profile = profile }

    public func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = redactHomes(text)
        out = redactVolumes(out)
        out = redactHosts(out)
        out = redactEmails(out)
        out = redactIdentifiers(out)
        out = redactMACs(out)
        out = redactIPv6(out)
        out = redactIPv4(out)
        return redactUsername(out)
    }

    // MARK: - Individual rules

    private func redactHomes(_ text: String) -> String {
        var out = text
        let home = profile.homeDirectory
        if home.count > 1 {
            // The lookahead stops "/Users/jo" from eating the start of "/Users/john".
            let pattern = escaped(home) + #"(?=/|$|[\s"'])"#
            out = out.replacingOccurrences(of: pattern, with: "~", options: .regularExpression)
        }
        // Another account's home is not this user's "~", but it is still personal.
        return mapMatches(#"/Users/([A-Za-z0-9._-]+)"#, in: out) { groups in
            groups[1] == "Shared" ? groups[0] : "/Users/<redacted-user>"
        }
    }

    private func redactVolumes(_ text: String) -> String {
        // A system volume name is not personal; an external volume name usually is. Capture the
        // whole name (spaces included) up to the next separator, quote or end of string, so a name
        // such as "Alice Backup" never leaves a readable fragment behind.
        mapMatches(#"(?i)/Volumes/(?!Macintosh HD(?:/|["']|$))([^/"'<>]+)"#, in: text) { groups in
            groups[1].caseInsensitiveCompare("Macintosh HD") == .orderedSame ? groups[0] : "/Volumes/<redacted-volume>"
        }
    }

    private func redactHosts(_ text: String) -> String {
        var out = text
        for name in profile.hostNames.filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            let pattern = #"(?<![A-Za-z0-9._-])"# + escaped(name) + #"(?![A-Za-z0-9_-])"#
            out = out.replacingOccurrences(of: pattern, with: "<redacted-host>",
                                           options: [.regularExpression, .caseInsensitive])
        }
        // A short host name replaced inside "host.local" leaves a suffix that still identifies it.
        return out.replacingOccurrences(of: #"<redacted-host>\.[A-Za-z0-9.-]+"#,
                                        with: "<redacted-host>", options: .regularExpression)
    }

    private func redactEmails(_ text: String) -> String {
        text.replacingOccurrences(of: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
                                  with: "<redacted-email>", options: [.regularExpression, .caseInsensitive])
    }

    private func redactIdentifiers(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: #"\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b"#,
            with: "<redacted-id>", options: [.regularExpression, .caseInsensitive])
        out = mapMatches(#"(?i)\b(serial(?:[ _-]?number)?|serialNumber|IOPlatformSerialNumber)\b[ \t]*[:=]?[ \t]*([A-Z0-9]{8,16})\b"#,
                         in: out) { groups in "\(groups[1]): <redacted-id>" }
        // Mac serials are 10-12 upper-case letters and digits with no separators. Requiring both
        // a letter and a digit keeps version strings and all-numeric counters untouched.
        return out.replacingOccurrences(
            of: #"\b(?=[A-Z0-9]{10,13}\b)(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*[0-9])[A-Z0-9]{10,13}\b"#,
            with: "<redacted-id>", options: .regularExpression)
    }

    private func redactMACs(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#,
                                            with: "<redacted-mac>", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\b[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\b"#,
                                       with: "<redacted-mac>", options: .regularExpression)
        return out
    }

    private func redactIPv6(_ text: String) -> String {
        // Link-local addresses carry an interface zone (`%en0`) after the address.
        let linkLocal = #"(?<![:0-9A-Za-z])fe80:(?::[0-9A-Fa-f]{0,4}){0,4}%[A-Za-z0-9]+"#
        let general = #"(?<![:0-9A-Za-z])(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,7}:|(?:[0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,5}(?::[0-9A-Fa-f]{1,4}){1,2}|(?:[0-9A-Fa-f]{1,4}:){1,4}(?::[0-9A-Fa-f]{1,4}){1,3}|(?:[0-9A-Fa-f]{1,4}:){1,3}(?::[0-9A-Fa-f]{1,4}){1,4}|(?:[0-9A-Fa-f]{1,4}:){1,2}(?::[0-9A-Fa-f]{1,4}){1,5}|[0-9A-Fa-f]{1,4}:(?:(?::[0-9A-Fa-f]{1,4}){1,6})|:(?:(?::[0-9A-Fa-f]{1,4}){1,7}|:))(?![0-9A-Za-z])"#
        var out = mapMatches(linkLocal, in: text) { _ in "<redacted-ip>" }
        out = mapMatches(general, in: out) { groups in
            let loopbacks = ["::1", "0:0:0:0:0:0:0:1"]
            return loopbacks.contains(groups[0].lowercased()) ? groups[0] : "<redacted-ip>"
        }
        return out
    }

    private func redactIPv4(_ text: String) -> String {
        let pattern = #"(?<![\d.])(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?![\d.])"#
        return mapMatches(pattern, in: text) { groups in
            groups[0] == "127.0.0.1" ? groups[0] : "<redacted-ip>"
        }
    }

    private func redactUsername(_ text: String) -> String {
        guard usernameLengthOK else { return text }
        let pattern = #"(?<![A-Za-z0-9._-])"# + escaped(profile.username) + #"(?![A-Za-z0-9._-])"#
        return text.replacingOccurrences(of: pattern, with: "<redacted-user>",
                                         options: [.regularExpression, .caseInsensitive])
    }

    private var usernameLengthOK: Bool { profile.username.count >= 2 }

    // MARK: - Regex helpers

    private func escaped(_ value: String) -> String {
        var out = ""
        for ch in value {
            if "\\.*+?[](){}^$|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Applies a pattern with a replacement that can inspect the match (needed to keep loopback
    /// addresses and the system volume name). Returns the original text for an invalid pattern.
    private func mapMatches(_ pattern: String, in text: String,
                            _ replacement: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = ""
        var position = 0
        for match in matches {
            let range = match.range
            guard range.location >= position, range.length > 0 else { continue }
            out += ns.substring(with: NSRange(location: position, length: range.location - position))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let r = match.range(at: index)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += replacement(groups)
            position = range.location + range.length
        }
        out += ns.substring(with: NSRange(location: position, length: ns.length - position))
        return out
    }
}
