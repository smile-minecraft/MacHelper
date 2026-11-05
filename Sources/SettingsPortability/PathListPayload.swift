import CleanEngine
import Foundation

/// A flat list of absolute path patterns: the cleaning whitelist, extra purge roots, and artifact
/// scan roots all use this shape. Comments and blank lines belong to the files on disk, not to the
/// value, so a payload carries only the patterns.
public struct PathListPayload: Codable, Equatable, Sendable {
    public var paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }

    /// Trims entries, drops duplicates, and rejects anything that is not an absolute pattern after
    /// `~` expansion. A relative entry would protect or scan nothing, so it is reported instead of
    /// being written.
    public static func validated(_ data: Data) -> SectionValidation {
        let incoming: PathListPayload
        do {
            incoming = try JSONDecoder().decode(PathListPayload.self, from: data)
        } catch {
            return .invalid(String(describing: error))
        }
        var seen = Set<String>()
        var paths: [String] = []
        for rawEntry in incoming.paths {
            let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seen.contains(entry) else { continue }
            if entry.hasPrefix("#") {
                return .invalid("Path entries are values, not comments.")
            }
            if entry.contains("\n") || entry.contains("\0") {
                return .invalid("Path entries cannot contain line breaks or NUL.")
            }
            guard (entry as NSString).expandingTildeInPath.hasPrefix("/") else {
                return .invalid("'\(entry)' is not an absolute path after expanding ~.")
            }
            seen.insert(entry)
            paths.append(entry)
        }
        let bytes: Data
        do { bytes = try CanonicalJSON.encode(PathListPayload(paths: paths)) }
        catch { return .invalid(String(describing: error)) }
        return .valid(SettingsPayload(data: bytes, summary: "\(paths.count) path patterns"))
    }
}
