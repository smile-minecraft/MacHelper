import Darwin
import Foundation

/// Moving an uninstalled app's leftovers out of system folders, done by the root Helper.
///
/// The app decides which leftovers belong to the app being removed; the Helper only checks that
/// each path sits directly in one of the fixed folders below (one level deeper for
/// `/Library/Application Support/<Vendor>/<Product>`), isn't hidden or an Apple / MacHelper item,
/// and then moves it into the caller's Trash. Nothing is deleted, so everything can be put back.
///
/// Every step goes through directory file descriptors opened with `O_NOFOLLOW`, so a folder
/// swapped for a symbolic link can't redirect the move. The caller's `.Trash` must be a real
/// folder they own. Moved items are handed to the caller (so emptying the Trash needs no
/// password), again through descriptors; hard-linked files and device nodes are left as they are.
public enum SystemLeftovers {
    public struct Area: Sendable, Equatable {
        public let dir: String
        public let maxDepth: Int
        /// Only symbolic links may be moved (command-line links into an app bundle).
        public let symlinksOnly: Bool
        /// Allowed file name endings; nil = any.
        public let suffixes: [String]?

        init(_ dir: String, maxDepth: Int = 1, symlinksOnly: Bool = false, suffixes: [String]? = nil) {
            self.dir = dir
            self.maxDepth = maxDepth
            self.symlinksOnly = symlinksOnly
            self.suffixes = suffixes
        }
    }

    /// The same system areas the leftover finder searches, and nothing else.
    public static let areas: [Area] = [
        Area("/Library/Application Support", maxDepth: 2),
        Area("/Library/Caches"),
        Area("/Library/Logs"),
        Area("/Library/Preferences", suffixes: [".plist"]),
        Area("/Library/LaunchAgents", suffixes: [".plist"]),
        Area("/Library/LaunchDaemons", suffixes: [".plist"]),
        Area("/Library/PrivilegedHelperTools"),
        Area("/Library/Extensions", suffixes: [".kext"]),
        Area("/Library/Internet Plug-Ins"),
        Area("/Library/PreferencePanes", suffixes: [".prefPane"]),
        Area("/Library/Screen Savers"),
        Area("/Library/Audio/Plug-Ins/Components"),
        Area("/Library/Audio/Plug-Ins/HAL"),
        Area("/Library/Audio/Plug-Ins/VST"),
        Area("/Library/Audio/Plug-Ins/VST3"),
        Area("/Users/Shared"),
        Area("/private/var/db/receipts", suffixes: [".bom", ".plist"]),
        Area("/usr/local/bin", symlinksOnly: true),
        Area("/opt/homebrew/bin", symlinksOnly: true),
    ]

    /// Names that are never one app's leftovers.
    static let protectedPrefixes = ["com.apple.", "apple", "com.machelper.", "machelper"]
    /// Shared folders directly in /Library/Application Support that several apps or macOS use.
    static let sharedFolders: Set<String> = ["crashreporter", "script editor", "ilifemediabrowser", "mobilesync",
                                             "applepushservice", "dirservices", "mobiledevice", "audio", "fonts", "keychains"]
    public static let maxPaths = 200

    public enum ValidationError: Error, CustomStringConvertible, Equatable {
        case notAllowed(String)
        case protectedName(String)
        case notASymlinkIntoAnApp(String)

        public var description: String {
            switch self {
            case .notAllowed(let p): "\(p) is not inside a system folder MacHelper may clean"
            case .protectedName(let p): "\(p) belongs to macOS, several apps or MacHelper"
            case .notASymlinkIntoAnApp(let p): "\(p) is not a link into an app bundle"
            }
        }
    }

    /// The area and the path components below it.
    public static func validate(_ path: String, areas: [Area] = areas) throws -> (area: Area, components: [String]) {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("//") else { throw ValidationError.notAllowed(path) }
        // Longest matching area first (/Library/Audio/Plug-Ins/HAL before nothing shorter matches anyway).
        guard let area = areas.filter({ path.hasPrefix($0.dir + "/") }).max(by: { $0.dir.count < $1.dir.count }) else {
            throw ValidationError.notAllowed(path)
        }
        let components = path.dropFirst(area.dir.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...area.maxDepth).contains(components.count),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") && $0.utf8.count <= 255 })
        else { throw ValidationError.notAllowed(path) }
        for c in components {
            let lower = c.lowercased()
            if protectedPrefixes.contains(where: { lower.hasPrefix($0) }) { throw ValidationError.protectedName(path) }
        }
        if area.dir == "/Library/Application Support", sharedFolders.contains(components[0].lowercased()) {
            throw ValidationError.protectedName(path)
        }
        if let suffixes = area.suffixes, !suffixes.contains(where: { components.last!.hasSuffix($0) }) {
            throw ValidationError.notAllowed(path)
        }
        return (area, components)
    }

    public struct Request: Codable, Sendable, Equatable {
        public var paths: [String]
        public init(paths: [String]) { self.paths = paths }
    }

    public struct Result: Codable, Sendable, Equatable {
        public struct Item: Codable, Sendable, Equatable {
            public let path: String
            /// Name inside the Trash (it differs when the Trash already had that name).
            public let trashedAs: String?
            public let error: String?

            public init(path: String, trashedAs: String?, error: String?) {
                self.path = path
                self.trashedAs = trashedAs
                self.error = error
            }
        }

        public var items: [Item]
        public init(items: [Item]) { self.items = items }
    }

    public struct Owner: Sendable {
        public let uid: uid_t
        public let gid: gid_t
        public init(uid: uid_t, gid: gid_t) {
            self.uid = uid
            self.gid = gid
        }
    }

    /// Moves one validated path into `trash`.
    ///
    /// - Parameters:
    ///   - owner: who must own `trash`, and who the moved item is handed to. Nil (tests only)
    ///     skips both.
    ///   - beforeMove: called with the validated area just before the move (the Helper stops
    ///     launchd jobs here); throwing cancels the move.
    public static func moveToTrash(_ path: String, trash: String, owner: Owner?, areas: [Area] = areas,
                                   now: Date = Date(), beforeMove: (Area) throws -> Void = { _ in }) -> Result.Item {
        func fail(_ message: String) -> Result.Item { Result.Item(path: path, trashedAs: nil, error: message) }
        let area: Area, components: [String]
        do { (area, components) = try validate(path, areas: areas) } catch { return fail("\(error)") }

        var parent = open(area.dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return fail("\(area.dir): \(String(cString: strerror(errno)))") }
        defer { close(parent) }
        for c in components.dropLast() {
            let next = openat(parent, c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return fail("\(c): \(String(cString: strerror(errno)))") }
            close(parent)
            parent = next
        }
        let leaf = components.last!
        var st = stat()
        guard fstatat(parent, leaf, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return fail(String(cString: strerror(errno))) }
        if area.symlinksOnly {
            guard st.st_mode & S_IFMT == S_IFLNK else { return fail("\(ValidationError.notASymlinkIntoAnApp(path))") }
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            let n = readlinkat(parent, leaf, &buf, buf.count - 1)
            let target = n > 0 ? String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            guard target.contains(".app/") else { return fail("\(ValidationError.notASymlinkIntoAnApp(path))") }
        }

        let trashFD = open(trash, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard trashFD >= 0 else { return fail("Trash \(trash): \(String(cString: strerror(errno)))") }
        defer { close(trashFD) }
        if let owner {
            var ts = stat()
            guard fstat(trashFD, &ts) == 0, ts.st_uid == owner.uid else { return fail("Trash \(trash) isn't owned by the user") }
        }

        do { try beforeMove(area) } catch { return fail("\(error)") }

        let name = freeName(leaf, in: trashFD, now: now)
        guard renameat(parent, leaf, trashFD, name) == 0 else {
            return fail(errno == EXDEV ? "the Trash is on another volume" : String(cString: strerror(errno)))
        }
        if let owner { handOver(trashFD, name, to: owner) }
        return Result.Item(path: path, trashedAs: name, error: nil)
    }

    /// "Foo" → "Foo", or "Foo 2026-11-06 17.46.46" when the Trash already has a "Foo".
    static func freeName(_ name: String, in dirFD: Int32, now: Date) -> String {
        var st = stat()
        guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return name }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for i in 0..<100 {
            let candidate = stem + " " + f.string(from: now) + (i == 0 ? "" : " \(i)") + (ext.isEmpty ? "" : "." + ext)
            if fstatat(dirFD, candidate, &st, AT_SYMLINK_NOFOLLOW) != 0 { return candidate }
        }
        return stem + " " + UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
    }

    /// chown through descriptors, never following links. Hard-linked files (the data has another
    /// name somewhere else) and anything but files, folders and links keep their owner.
    static func handOver(_ dirFD: Int32, _ name: String, to owner: Owner, depth: Int = 0) {
        var st = stat()
        guard depth < 64, fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            fchownat(dirFD, name, owner.uid, owner.gid, AT_SYMLINK_NOFOLLOW)
        case S_IFREG:
            if st.st_nlink == 1 { fchownat(dirFD, name, owner.uid, owner.gid, AT_SYMLINK_NOFOLLOW) }
        case S_IFDIR:
            let child = openat(dirFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return }
            defer { close(child) }
            fchown(child, owner.uid, owner.gid)
            for entry in entries(child) { handOver(child, entry, to: owner, depth: depth + 1) }
        default:
            return
        }
    }

    private static func entries(_ dirFD: Int32) -> [String] {
        let copy = dup(dirFD)
        guard copy >= 0, let dir = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
