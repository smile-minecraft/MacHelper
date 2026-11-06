import Foundation

/// `sfltool dumpbtm` run by the root Helper. As a normal user the tool asks for an administrator
/// password on every run (it obtains `system.privilege.admin`); as root it doesn't. The command is
/// fixed here and takes nothing from the caller. Root sees every account's records, so the Helper
/// returns only the caller's and the system-wide ones.
public enum BackgroundTaskDump {
    public static let tool = "/usr/bin/sfltool"
    public static let arguments = ["dumpbtm"]
    /// Records for all users / the system, kept for every caller.
    public static let sharedUIDs: Set<Int> = [-2, 0]

    /// Keeps the text before the first "Records for UID" header and the sections whose UID is
    /// `uid` or one of `sharedUIDs`; every other account's section is dropped.
    public static func filter(_ text: String, uid: Int) -> String {
        let keep = sharedUIDs.union([uid])
        var out: [Substring] = []
        var keeping = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("Records for UID ") {
                let rest = trimmed.dropFirst("Records for UID ".count)
                // A header that doesn't parse is dropped with its section (fail closed).
                keeping = Int(rest.prefix { $0 == "-" || $0.isNumber }).map(keep.contains) ?? false
            }
            if keeping { out.append(line) }
        }
        return out.joined(separator: "\n")
    }
}
