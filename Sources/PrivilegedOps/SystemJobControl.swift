import Darwin
import Foundation

/// Rules for switching third-party launchd jobs in `/Library/LaunchAgents` and
/// `/Library/LaunchDaemons` on or off. Only enable/disable: plists are never edited, moved or
/// deleted. The root Helper validates every daemon request with this before calling launchctl;
/// the app uses the same check for agents.
public enum SystemJobControl {
    public enum Kind: String, Codable, Sendable {
        case agent, daemon

        public var directory: String {
            switch self {
            case .agent: "/Library/LaunchAgents"
            case .daemon: "/Library/LaunchDaemons"
            }
        }
    }

    public enum ValidationError: Error, CustomStringConvertible, Equatable {
        case notInDirectory(String)
        case badFileName(String)
        case notRegularFile(String)
        case notOwnedByRoot(String)
        case unreadable(String)
        case badLabel(String)
        case protectedLabel(String)

        public var description: String {
            switch self {
            case .notInDirectory(let p): "\(p) is not directly inside an allowed launchd folder"
            case .badFileName(let p): "\(p) is not a .plist file name"
            case .notRegularFile(let p): "\(p) is not a regular file (symbolic links are refused)"
            case .notOwnedByRoot(let p): "\(p) is not owned by root"
            case .unreadable(let p): "\(p) could not be read as a launchd property list"
            case .badLabel(let l): "label \(l) contains unexpected characters"
            case .protectedLabel(let l): "\(l) is an Apple or MacHelper job and can't be changed"
            }
        }
    }

    /// Jobs that must never be switched off from MacHelper.
    public static let protectedLabelPrefixes = ["com.apple.", "com.machelper."]

    public static func isProtected(_ label: String) -> Bool {
        protectedLabelPrefixes.contains { label.hasPrefix($0) }
    }

    static func isValidLabel(_ label: String) -> Bool {
        label.count <= 200 && label.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    /// Checks a plist path and returns the job's label.
    ///
    /// - Parameters:
    ///   - directory: the allowed folder (fixed per kind; overridable only for tests).
    ///   - requireRootOwner: launchd only loads root-owned plists from these folders; tests turn it off.
    public static func validate(plistPath: String, kind: Kind, directory: String? = nil,
                                requireRootOwner: Bool = true) throws -> String {
        let dir = directory ?? kind.directory
        let name = (plistPath as NSString).lastPathComponent
        guard plistPath == dir + "/" + name, !name.isEmpty else { throw ValidationError.notInDirectory(plistPath) }
        guard name.hasSuffix(".plist"), !name.hasPrefix("."), name.count <= 255, !name.contains("/") else {
            throw ValidationError.badFileName(plistPath)
        }
        // The folder itself must be a real folder, not a link to somewhere else.
        var dirStat = stat()
        guard lstat(dir, &dirStat) == 0, dirStat.st_mode & S_IFMT == S_IFDIR else { throw ValidationError.notInDirectory(plistPath) }

        let fd = open(plistPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw errno == ELOOP ? ValidationError.notRegularFile(plistPath) : ValidationError.unreadable(plistPath)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw ValidationError.notRegularFile(plistPath) }
        if requireRootOwner && st.st_uid != 0 { throw ValidationError.notOwnedByRoot(plistPath) }
        guard st.st_size < 1_000_000, let data = try? handle.readToEnd(),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String
        else { throw ValidationError.unreadable(plistPath) }
        guard isValidLabel(label) else { throw ValidationError.badLabel(label) }
        guard !isProtected(label) else { throw ValidationError.protectedLabel(label) }
        return label
    }

    /// launchctl argument lists that switch a validated job. Disabling persists across restarts
    /// (launchd's disabled database), then stops the running instance; enabling clears that and
    /// loads it again. `domain` is `system` for daemons, `gui/<uid>` for agents.
    public static func commands(label: String, plistPath: String, domain: String, enabled: Bool) -> (required: [String], bestEffort: [String]) {
        enabled
            ? (["enable", "\(domain)/\(label)"], ["bootstrap", domain, plistPath])
            : (["disable", "\(domain)/\(label)"], ["bootout", "\(domain)/\(label)"])
    }
}
