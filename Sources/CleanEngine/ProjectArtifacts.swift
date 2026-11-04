import Darwin
import Foundation

public struct ArtifactDetector: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// File names (or globs like `*.xcodeproj`, or relative paths) whose presence marks a project.
    public let markers: [String]
    /// Rebuildable directories inside such a project.
    public let artifacts: [String]

    public static func loadBuiltIn() throws -> [ArtifactDetector] {
        struct File: Codable { let schemaVersion: Int; let detectors: [ArtifactDetector] }
        guard let url = Bundle.module.url(forResource: "detectors", withExtension: "json", subdirectory: "Artifacts")
        else { return [] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).detectors.map {
            ArtifactDetector(id: $0.id, title: RuleText.localized("detector.\($0.id).title", $0.title), markers: $0.markers, artifacts: $0.artifacts)
        }
    }
}

public struct ProjectArtifact: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let projectPath: String
    public let detector: String
    public let size: UInt64
    public let modified: Date?
    /// Touched within `recentDays`: likely in active use, so not preselected.
    public let recentlyUsed: Bool
    public var selected: Bool
}

public struct ArtifactSkip: Codable, Sendable {
    public let path: String
    public let reason: String
}

public struct ArtifactScanResult: Codable, Sendable {
    public let schemaVersion: Int
    public let roots: [String]
    public var artifacts: [ProjectArtifact]
    public let skipped: [ArtifactSkip]
    public var totalSize: UInt64 { artifacts.reduce(0) { $0 + $1.size } }
    public var selectedSize: UInt64 { artifacts.filter(\.selected).reduce(0) { $0 + $1.size } }
}

/// Finds rebuildable build output (node_modules, target, .build, …) under project roots.
///
/// Safety: never inside protected paths; skips artifacts that contain a `.git` directory (nested repo)
/// or hold git-tracked files (someone committed `vendor/`); recently used ones are found but not preselected.
public struct ArtifactScanner: Sendable {
    public let detectors: [ArtifactDetector]
    public let recentDays: Int
    public let maxDepth: Int

    public init(detectors: [ArtifactDetector], recentDays: Int = 7, maxDepth: Int = 8) {
        self.detectors = detectors
        self.recentDays = recentDays
        self.maxDepth = maxDepth
    }

    /// Existing default roots plus those listed in purge-paths.txt.
    public static func defaultRoots() -> [String] {
        let home = MacHelperPaths.home.path
        var roots = ["Developer", "Projects", "projects", "Code", "code", "src", "dev", "workspace", "repos",
                     "GitHub", "Documents/GitHub", "Documents/Projects"].map { home + "/" + $0 }
        if let text = try? String(contentsOf: MacHelperPaths.purgePathsFile, encoding: .utf8) {
            roots += text.split(whereSeparator: \.isNewline).map { expandTilde($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        var seen = Set<String>()
        return roots.map(PathSafety.normalize).filter { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue && seen.insert(path).inserted
        }
    }

    /// - Parameter safety: defaults to `PathSafety.forArtifacts(roots:)`; injectable for tests.
    public func scan(roots: [String], safety: PathSafety? = nil) -> ArtifactScanResult {
        let roots = roots.map { PathSafety.normalize(expandTilde($0)) }
        let safety = safety ?? PathSafety.forArtifacts(roots: roots)
        // Never descend into dependency trees; other artifact names (build, vendor, bin…) are only
        // skipped where they were actually identified as a project's artifact.
        let neverDescend: Set<String> = ["node_modules"]
        var found: [(path: String, project: String, detector: String)] = []
        var skipped: [ArtifactSkip] = []
        var seen = Set<String>()

        // Breadth-first walk; artifact directories and hidden directories are never descended.
        var queue: [(String, Int)] = roots.map { ($0, 0) }
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            let entrySet = Set(entries)

            for d in detectors where matches(d, dir: dir, entries: entrySet) {
                for name in d.artifacts {
                    let path = dir + "/" + name
                    guard !seen.contains(path), isRealDirectory(path) else { continue }
                    seen.insert(path)
                    if let reason = refusal(path, project: dir, safety: safety) {
                        skipped.append(ArtifactSkip(path: path, reason: reason))
                    } else {
                        found.append((path, dir, d.id))
                    }
                }
            }
            guard depth < maxDepth else { continue }
            // docker-compose projects bind-mount ./volumes and ./data into running containers:
            // anything in there is live service state, not build output.
            let isCompose = Self.composeFiles.contains { entrySet.contains($0) }
            for name in entries where !name.hasPrefix(".") && !neverDescend.contains(name) {
                if isCompose, Self.composeDataDirs.contains(name) { continue }
                let child = dir + "/" + name
                if !seen.contains(child), isRealDirectory(child), !name.hasSuffix(".app"), !name.hasSuffix(".xcodeproj") {
                    queue.append((child, depth + 1))
                }
            }
        }

        let measured = CleanScanner.measure(found.map(\.path))
        let bySize = Dictionary(uniqueKeysWithValues: measured.map { ($0.path, $0) })
        let recentCutoff = Date().addingTimeInterval(-TimeInterval(recentDays) * 86_400)
        let artifacts = found.compactMap { f -> ProjectArtifact? in
            guard let m = bySize[f.path], m.size > 0 else { return nil }
            let recent = (newestModification(f.path) ?? .distantPast) > recentCutoff
            return ProjectArtifact(path: f.path, projectPath: f.project, detector: f.detector, size: m.size,
                                   modified: m.modified, recentlyUsed: recent, selected: !recent)
        }
        return ArtifactScanResult(schemaVersion: 1, roots: roots, artifacts: artifacts.sorted { $0.size > $1.size },
                                  skipped: skipped)
    }

    static let composeFiles = ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"]
    static let composeDataDirs: Set<String> = ["volumes", "data", "db", "storage"]

    private func matches(_ d: ArtifactDetector, dir: String, entries: Set<String>) -> Bool {
        d.markers.contains { marker in
            if marker.contains("*") { return entries.contains { fnmatch(marker, $0, 0) == 0 } }
            if marker.contains("/") { return FileManager.default.fileExists(atPath: dir + "/" + marker) }
            return entries.contains(marker)
        }
    }

    private func refusal(_ path: String, project: String, safety: PathSafety) -> String? {
        let verdict = safety.check(path)
        guard verdict == .allowed else { return "safety: \(verdict)" }
        if FileManager.default.fileExists(atPath: path + "/.git") { return "contains a nested git repository" }
        if gitTracksFiles(in: path, project: project) { return "contains git-tracked files" }
        return nil
    }

    private func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Newest mtime among the artifact and its immediate children (cheap "recently used" signal).
    private func newestModification(_ path: String) -> Date? {
        var newest: Date?
        for p in [path] + ((try? FileManager.default.contentsOfDirectory(atPath: path))?.prefix(200).map { path + "/" + $0 } ?? []) {
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            let d = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if newest == nil || d > newest! { newest = d }
        }
        return newest
    }

    private func gitTracksFiles(in path: String, project: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", project, "ls-files", "--", (path as NSString).lastPathComponent]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && !data.isEmpty
    }
}
