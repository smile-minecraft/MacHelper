import Darwin
import Foundation

public enum SafetyVerdict: Equatable, Sendable {
    case allowed
    case protected(String)
    case whitelisted(String)
    case outsideAllowedRoots
    case tooShallow
}

/// Last line of defence before anything is removed. Applied at scan time *and* again right before
/// each removal, on the path with its parent directory resolved (the item itself is never followed,
/// so a symlink is removed as a link, not as its target).
public struct PathSafety: Sendable {
    /// Absolute paths that may never be removed, nor contain a removed item, nor be contained by one.
    public let protectedPaths: [String]
    /// User whitelist globs (from clean-whitelist.txt).
    public let whitelist: [String]
    /// Items must live under one of these.
    public let allowedRoots: [String]
    /// Items must be at least this many components below their allowed root.
    public let minimumDepth: Int

    static let systemPaths = ["/System", "/usr", "/bin", "/sbin", "/Applications", "/Library", "/private", "/etc",
                              "/var", "/opt", "/cores", "/Volumes"]

    /// Personal data and system state under the home folder that no cleaning rule may touch.
    static let protectedInHome = [
        "Library/Keychains", "Library/Preferences", "Library/Mobile Documents", "Library/CloudStorage",
        "Library/Messages", "Library/Mail", "Library/Photos", "Library/Calendars", "Library/Safari",
        "Library/Cookies", "Library/Accounts", "Library/IdentityServices", "Library/HomeKit",
        "Library/Group Containers", "Library/Application Support/com.apple.TCC",
        "Library/Application Support/AddressBook", "Library/Application Support/MacHelper",
        "Library/Logs/MacHelper", "Library/Containers/com.apple.mail/Data/Library/Mail",
        "Library/Daemon Containers", "Library/Autosave Information",
        ".ssh", ".gnupg", ".aws", ".kube", ".config", ".docker", ".netrc",
    ]

    /// Extra protection for cleaning rules (not for project artifacts, which often live in Documents).
    static let personalFolders = ["Documents", "Desktop", "Pictures", "Movies", "Music", "Public"]

    public init(protectedPaths: [String], whitelist: [String], allowedRoots: [String], minimumDepth: Int) {
        self.protectedPaths = protectedPaths.map(Self.normalize)
        self.whitelist = whitelist.map(expandTilde)
        self.allowedRoots = allowedRoots.map(Self.normalize)
        self.minimumDepth = minimumDepth
    }

    /// For declarative cleaning rules: home folder only, personal folders protected.
    public static func forCleaning(whitelist: [String] = loadWhitelist()) -> PathSafety {
        let home = MacHelperPaths.home.path
        let inHome = (protectedInHome + personalFolders).map { home + "/" + $0 }
        return PathSafety(protectedPaths: systemPaths + inHome, whitelist: whitelist, allowedRoots: [home], minimumDepth: 2)
    }

    /// For project build artifacts: under the scan roots, personal folders allowed.
    public static func forArtifacts(roots: [String], whitelist: [String] = loadWhitelist()) -> PathSafety {
        let home = MacHelperPaths.home.path
        // Roots are chosen explicitly by the user, so external volumes are fine; system paths are not.
        let system = systemPaths.filter { $0 != "/Volumes" }
        return PathSafety(protectedPaths: system + protectedInHome.map { home + "/" + $0 },
                          whitelist: whitelist, allowedRoots: roots, minimumDepth: 1)
    }

    /// For items the user picks by hand in the disk analyzer (collector basket): anything inside the
    /// home folder, /Users/Shared or a mounted external volume, except protected data and volume roots.
    public static func forAnalysis(whitelist: [String] = loadWhitelist()) -> PathSafety {
        let home = MacHelperPaths.home.path
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .map(\.path).filter { $0.hasPrefix("/Volumes/") }
        let system = systemPaths.filter { $0 != "/Volumes" }
        return PathSafety(protectedPaths: system + protectedInHome.map { home + "/" + $0 },
                          whitelist: whitelist, allowedRoots: [home, "/Users/Shared"] + volumes, minimumDepth: 1)
    }

    public func check(_ path: String) -> SafetyVerdict {
        let p = Self.resolveParent(path)
        for pattern in whitelist where fnmatch(pattern, p, 0) == 0 || p.hasPrefix(pattern.hasSuffix("/") ? pattern : pattern + "/") {
            return .whitelisted(pattern)
        }
        for prot in protectedPaths {
            if p == prot || p.hasPrefix(prot + "/") { return .protected(prot) }
            if prot.hasPrefix(p + "/") { return .protected(prot) }   // would contain protected data
        }
        guard let root = allowedRoots.first(where: { p.hasPrefix($0 + "/") }) else { return .outsideAllowedRoots }
        let depth = p.dropFirst(root.count + 1).split(separator: "/").count
        return depth >= minimumDepth ? .allowed : .tooShallow
    }

    public static func loadWhitelist() -> [String] { CleanExclusions().entries() }

    /// Resolves symlinks in the parent directory only; the last component stays as-is.
    static func resolveParent(_ path: String) -> String {
        let url = URL(fileURLWithPath: expandTilde(path)).standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return normalize(parent == "/" ? "/" + url.lastPathComponent : parent + "/" + url.lastPathComponent)
    }

    static func normalize(_ path: String) -> String {
        var p = URL(fileURLWithPath: expandTilde(path)).standardizedFileURL.path
        // /private/var and /var, /private/tmp and /tmp are the same place.
        for (alias, real) in [("/var/", "/private/var/"), ("/tmp/", "/private/tmp/")] where p.hasPrefix(alias) {
            p = real + p.dropFirst(alias.count)
        }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

public func expandTilde(_ path: String) -> String {
    if path == "~" { return MacHelperPaths.home.path }
    if path.hasPrefix("~/") { return MacHelperPaths.home.path + path.dropFirst(1) }
    return path
}

/// Expands a glob (`*`, `?`, `[...]` per component). Never follows the final component's symlink.
public func expandGlob(_ pattern: String) -> [String] {
    var g = glob_t()
    defer { globfree(&g) }
    guard glob(expandTilde(pattern), 0, nil, &g) == 0 else { return [] }
    return (0..<Int(g.gl_pathc)).compactMap { i in g.gl_pathv[i].map { String(cString: $0) } }
}
