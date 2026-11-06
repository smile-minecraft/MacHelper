import AppKit
import Darwin
import DiskScan
import Foundation

/// One removable item found by a rule.
public struct CleanCandidate: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let ruleID: String
    public let path: String
    public let size: UInt64
    public let modified: Date?
    public let isDirectory: Bool
    public var selected: Bool
    /// Why it is not preselected, when relevant (e.g. its app is running).
    public var note: String?
}

public struct RuleResult: Codable, Sendable, Identifiable {
    public var id: String { rule.id }
    public let rule: CleanRule
    public var candidates: [CleanCandidate]
    /// Why the whole rule was skipped (app running, …).
    public let skippedReason: String?
    /// Matches that were refused by PathSafety, for transparency.
    public let refused: [String]

    public var totalSize: UInt64 { candidates.reduce(0) { $0 + $1.size } }
    public var selectedSize: UInt64 { candidates.filter(\.selected).reduce(0) { $0 + $1.size } }
}

public struct CleanPlan: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public var results: [RuleResult]

    public var totalSize: UInt64 { results.reduce(0) { $0 + $1.totalSize } }
    public var selectedSize: UInt64 { results.reduce(0) { $0 + $1.selectedSize } }
    public var selectedCandidates: [CleanCandidate] { results.flatMap { $0.candidates.filter(\.selected) } }
}

/// Evaluates rules into a preview plan. Read-only: never removes anything.
public struct CleanScanner: Sendable {
    public let rules: [CleanRule]
    public let safety: PathSafety
    public let now: Date

    public init(rules: [CleanRule], safety: PathSafety = .forCleaning(), now: Date = Date()) {
        self.rules = rules
        self.safety = safety
        self.now = now
    }

    public func scan() -> CleanPlan { scan(progress: { _, _ in }, shouldStop: { false }) }

    /// Scans rule by rule. `progress(done, total)` is called before each rule; when `shouldStop`
    /// returns true the scan ends early and the plan holds only the rules finished so far.
    public func scan(progress: (Int, Int) -> Void, shouldStop: () -> Bool) -> CleanPlan {
        var claimed: [String] = []   // earlier (more specific) rules win overlapping paths
        var results: [RuleResult] = []

        let running = Self.runningBundleIDs()
        let processes = rules.contains { !$0.skipIfProcessRunning.isEmpty } ? Self.runningProcessNames() : []
        for (index, rule) in rules.enumerated() {
            if shouldStop() { break }
            progress(index, rules.count)
            let busy = rule.skipIfRunning.first(where: running.contains)
                ?? rule.skipIfProcessRunning.first { processes.contains(String($0.prefix(Self.processNameLength))) }
            if let app = busy {
                // Reserve the rule's paths so a broader rule (e.g. all of ~/Library/Caches) cannot take them.
                claimed += rule.paths.flatMap(expandGlob).map(PathSafety.normalize)
                results.append(RuleResult(rule: rule, candidates: [], skippedReason: String(localized: "\(app) is running", bundle: .module), refused: []))
                continue
            }
            let excluded = rule.exclude.map(expandTilde)
            var paths: [String] = []
            var refused: [String] = []
            for pattern in rule.paths {
                for path in expandGlob(pattern) {
                    let p = PathSafety.normalize(path)
                    if excluded.contains(where: { fnmatch($0, p, FNM_PATHNAME) == 0 }) { continue }
                    if claimed.contains(where: { p == $0 || p.hasPrefix($0 + "/") || $0.hasPrefix(p + "/") }) { continue }
                    guard safety.check(p) == .allowed else { refused.append(p); continue }
                    paths.append(p)
                }
            }
            let minAge = TimeInterval(rule.minAgeDays) * 86_400
            let candidates = Self.measure(paths).compactMap { item -> CleanCandidate? in
                guard item.size > 0 else { return nil }
                if minAge > 0, let m = item.modified, now.timeIntervalSince(m) < minAge { return nil }
                // Folders named after a running app's bundle id (~/Library/Caches/com.foo.App) are its live data.
                let owner = (item.path as NSString).lastPathComponent
                let ownerRunning = running.contains(owner)
                return CleanCandidate(ruleID: rule.id, path: item.path, size: item.size, modified: item.modified,
                                      isDirectory: item.isDirectory, selected: rule.selectedByDefault && !ownerRunning,
                                      note: ownerRunning ? String(localized: "App is running", bundle: .module) : nil)
            }
            claimed += candidates.map(\.path)
            results.append(RuleResult(rule: rule, candidates: candidates.sorted { $0.size > $1.size },
                                      skippedReason: nil, refused: refused))
        }
        return CleanPlan(schemaVersion: 1, generatedAt: now, results: results)
    }

    struct Measured: Sendable {
        let path: String
        let size: UInt64
        let modified: Date?
        let isDirectory: Bool
    }

    /// Sizes items in parallel (allocated bytes; hard links / clones de-duplicated within an item).
    static func measure(_ paths: [String]) -> [Measured] {
        let results = UnsafeMutableBufferPointer<Measured?>.allocate(capacity: paths.count)
        results.initialize(repeating: nil)
        defer { results.deallocate() }
        let box = UncheckedBox(results)
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            box.value[i] = measure(paths[i])
        }
        return results.compactMap { $0 }
    }

    static func measure(_ path: String) -> Measured? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        if isDir {
            var options = ScanOptions()
            options.threads = 2
            options.keepFilesLargerThan = .max   // only totals needed
            let size = (try? DiskScanner(options: options).scan(URL(fileURLWithPath: path)).root.size) ?? 0
            return Measured(path: path, size: size, modified: modified, isDirectory: true)
        }
        return Measured(path: path, size: UInt64(st.st_blocks) * 512, modified: modified, isDirectory: false)
    }

    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// proc_name returns at most 2 × MAXCOMLEN characters.
    static let processNameLength = 32

    /// Executable names of this user's processes (others are not visible without root anyway).
    static func runningProcessNames() -> Set<String> {
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var names = Set<String>()
        var buffer = [CChar](repeating: 0, count: processNameLength + 1)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
                names.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return names
    }
}

/// Wrapper for handing a buffer to concurrentPerform; each index is written by one iteration only.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
