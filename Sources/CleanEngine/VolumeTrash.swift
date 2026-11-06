import Darwin
import Foundation

/// The Trash of other drives: each mounted volume keeps this user's deleted files in
/// `<volume>/.Trashes/<uid>`. Only items inside those folders can ever be removed.
public enum VolumeTrash {
    public static let ruleID = "user.trash.volumes"

    public static var rule: CleanRule {
        CleanRule(id: ruleID, title: String(localized: "Trash on other drives", bundle: .module),
                  description: String(localized: "Permanently deletes the items in the Trash of connected drives. This can’t be undone.", bundle: .module),
                  category: "trash", risk: .medium, paths: [], selectedByDefault: false, action: .delete)
    }

    /// Writable volumes mounted under /Volumes (external drives, other APFS volumes, disk images).
    public static func mountedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsReadOnlyKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path.hasPrefix("/Volumes/") }
            .filter { (try? $0.resourceValues(forKeys: Set(keys)).volumeIsReadOnly) != true }
    }

    /// `<volume>/.Trashes/<uid>` for each volume where it exists and is a real folder owned by this user.
    public static func trashFolders(volumes: [URL] = mountedVolumes(), uid: uid_t = getuid()) -> [String] {
        volumes.compactMap { v in
            let path = PathSafety.normalize(v.path) + "/.Trashes/\(uid)"
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == uid else { return nil }
            return path
        }
    }

    /// Only items inside the given trash folders; system paths stay protected.
    static let protectedPaths = PathSafety.systemPaths.filter { $0 != "/Volumes" }

    public static func safety(trashFolders: [String], whitelist: [String] = PathSafety.loadWhitelist()) -> PathSafety {
        safety(trashFolders: trashFolders, whitelist: whitelist, protectedPaths: protectedPaths)
    }

    static func safety(trashFolders: [String], whitelist: [String], protectedPaths: [String]) -> PathSafety {
        PathSafety(protectedPaths: protectedPaths, whitelist: whitelist, allowedRoots: trashFolders, minimumDepth: 1)
    }

    /// One result for all drives; each candidate's note names its drive.
    public static func scan(trashFolders: [String] = trashFolders()) -> RuleResult {
        scan(trashFolders: trashFolders, safety: safety(trashFolders: trashFolders))
    }

    static func scan(trashFolders: [String], safety: PathSafety) -> RuleResult {
        var paths: [String] = []
        var drive: [String: String] = [:]
        for folder in trashFolders {
            let name = ((folder as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            for item in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where item != ".DS_Store" {
                let p = folder + "/" + item
                guard safety.check(p) == .allowed else { continue }
                paths.append(p)
                drive[p] = (name as NSString).lastPathComponent
            }
        }
        let candidates = CleanScanner.measure(paths).filter { $0.size > 0 }.map {
            CleanCandidate(ruleID: ruleID, path: $0.path, size: $0.size, modified: $0.modified, isDirectory: $0.isDirectory,
                           selected: false, note: drive[$0.path])
        }
        return RuleResult(rule: rule, candidates: candidates.sorted { $0.size > $1.size }, skippedReason: nil, refused: [])
    }
}
