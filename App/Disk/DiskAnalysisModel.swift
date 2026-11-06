import AppKit
import CleanEngine
import DiskScan
import Foundation
import Observation

struct ScanTarget: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
    let symbol: String

    static func available() -> [ScanTarget] {
        var targets = [
            ScanTarget(id: "home", title: String(localized: "Home Folder"), url: FileManager.default.homeDirectoryForCurrentUser, symbol: "house"),
            // The writable data volume; "/" itself is the sealed system snapshot.
            ScanTarget(id: "data", title: String(localized: "Macintosh HD (Data)"), url: URL(fileURLWithPath: "/System/Volumes/Data"), symbol: "internaldrive"),
        ]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                            options: [.skipHiddenVolumes]) ?? []
        for v in volumes where v.path.hasPrefix("/Volumes/") {
            let name = (try? v.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? v.lastPathComponent
            targets.append(ScanTarget(id: v.path, title: name, url: v, symbol: "externaldrive"))
        }
        return targets
    }
}

struct VolumeSummary {
    let total: Int64
    let available: Int64
    /// Free space including purgeable (what Finder shows).
    let availableForImportant: Int64
    let localSnapshots: Int

    var used: Int64 { total - available }
    /// Space macOS can reclaim on demand (mostly Time Machine local snapshots and caches).
    var purgeable: Int64 { max(availableForImportant - available, 0) }

    static func load(for url: URL) -> VolumeSummary? {
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                        .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacity
        else { return nil }
        return VolumeSummary(total: Int64(total), available: Int64(avail),
                             availableForImportant: v.volumeAvailableCapacityForImportantUsage ?? Int64(avail),
                             localSnapshots: countSnapshots(url))
    }

    private static func countSnapshots(_ url: URL) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 0 }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").filter { $0.contains("com.apple") }.count
    }
}

/// What the pointer is over: a real node or an aggregated "other" segment.
struct HoverInfo: Equatable {
    let title: String
    let size: UInt64
    let path: String?
    let detail: String
    /// Why the item is marked (bloated folder or unused file), if it is.
    let flag: String?
}

@MainActor
@Observable
final class DiskAnalysisModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case done
        case failed(String)
    }

    enum ChartMode: String, CaseIterable, Identifiable {
        case sunburst, treemap
        var id: String { rawValue }
    }

    var targets: [ScanTarget]
    var target: ScanTarget {
        didSet {
            guard target != oldValue else { return }
            cancel()
            resetDisplay()
            isLoadingSavedScan = false
            revision += 1
            loadVolume()
            loadSavedScan()
        }
    }
    private(set) var phase: Phase = .idle
    private(set) var progress = ScanProgress(files: 0, directories: 0, bytes: 0, unreadableDirectories: 0)
    private(set) var root: DiskNode?
    private(set) var focus: DiskNode?
    private(set) var elapsed: TimeInterval = 0
    private(set) var volume: VolumeSummary?
    /// When the tree on screen came from a saved scan, the time that scan was taken. Nil for a live scan.
    private(set) var restoredAt: Date?
    /// Bumped whenever the tree changes, so charts rebuild their layout.
    private(set) var revision = 0
    var hover: HoverInfo?
    var mode: ChartMode = .sunburst
    var collector: [DiskNode] = []
    // Changes since the previous scan of the same location.
    private(set) var changes: [ScanSnapshot.Change] = []
    /// Unused-looking big files and bloated folders of the current tree.
    private(set) var insights: SpaceInsights?
    /// Flagged nodes → a short reason, for marking them in the charts and the lists.
    private(set) var flagged: [ObjectIdentifier: String] = [:]
    /// Folders with a flagged item somewhere inside.
    private(set) var flaggedAncestors: Set<ObjectIdentifier> = []
    private(set) var changesSince: Date?
    // Duplicate files (found on request).
    private(set) var duplicates: [DuplicateGroup]?
    private(set) var findingDuplicates = false
    /// Why the duplicate list is empty or incomplete: cloud-only files skipped, unreadable files,
    /// or the search not running at all.
    private(set) var duplicatesMessage: String?
    // Filters for the largest-files list.
    var kindFilter: FileKind?
    var olderThanDays: Int?
    var lastMessage: String?
    var previewURL: URL?

    @ObservationIgnored private var scanner: DiskScanner?
    @ObservationIgnored private let cache = ScanResultCache()
    @ObservationIgnored private var restoreGeneration = 0
    @ObservationIgnored private var isLoadingSavedScan = false

    init() {
        let available = ScanTarget.available()
        targets = available
        let saved = UserDefaults.standard.string(forKey: Self.lastScanTargetKey)
        target = available.first { $0.id == saved } ?? available[0]
    }

    /// The location of the last completed scan, so reopening the screen shows that location's result.
    private static let lastScanTargetKey = "diskAnalysis.lastScanTarget"

    var collectorSize: UInt64 { collector.reduce(0) { $0 + $1.size } }
    var breadcrumbs: [DiskNode] { focus?.lineage ?? [] }
    /// True while the tree on screen came from a saved scan: it can be browsed, but collecting,
    /// moving to the Trash, and hashing file contents all need a live scan.
    var isShowingSavedScan: Bool {
        guard let root else { return false }
        return !ScanCacheSafety.isLiveScan(root)
    }

    // MARK: Saved scans

    /// Loads the saved result for `target` when the screen has nothing to show. Only the snapshot
    /// file is read; nothing under the saved root is opened or listed.
    func restoreSavedScanIfNeeded() {
        guard root == nil, phase == .idle, !isLoadingSavedScan else { return }
        loadSavedScan()
    }

    /// Removes the saved result of the current location and returns to the empty state.
    func clearSavedScan() {
        guard isShowingSavedScan else { return }
        do {
            try cache.clear(rootPath: cacheKey(for: target.url))
        } catch {
            lastMessage = String(localized: "The saved scan could not be cleared: \(error.localizedDescription)")
            return
        }
        resetDisplay()
        isLoadingSavedScan = false
        revision += 1
    }

    private func loadSavedScan() {
        restoreGeneration += 1
        let generation = restoreGeneration
        isLoadingSavedScan = true
        let key = cacheKey(for: target.url)
        let cache = cache
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> (ScanResultSnapshot, DiskNode, SpaceInsights)? in
                guard let snapshot = cache.load(rootPath: key), let tree = snapshot.rebuildTree() else { return nil }
                // A saved scan is a record: nothing under its root is looked up, so only folder findings.
                var options = SpaceInsights.Options()
                options.minFileSize = .max
                return (snapshot, tree, SpaceInsights.find(in: tree, options: options, lastUse: { _ in nil }))
            }.value
            guard let self, self.restoreGeneration == generation else { return }
            self.isLoadingSavedScan = false
            guard let (snapshot, tree, insights) = loaded else { return }
            self.setInsights(insights, root: tree)
            self.root = tree
            self.focus = tree
            self.progress = snapshot.progress
            self.elapsed = snapshot.elapsed
            self.restoredAt = snapshot.scannedAt
            self.phase = .done
            self.revision += 1
            self.loadVolume()
        }
    }

    /// The cache key for a scan location: the same resolved path the scanner records.
    private func cacheKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func loadVolume() {
        volume = nil
        let url = target.url
        Task.detached(priority: .userInitiated) { [weak self] in
            let summary = VolumeSummary.load(for: url)
            await MainActor.run {
                guard let self, self.target.url == url else { return }
                self.volume = summary
            }
        }
    }

    private func resetDisplay() {
        restoredAt = nil
        root = nil
        focus = nil
        progress = ScanProgress(files: 0, directories: 0, bytes: 0, unreadableDirectories: 0)
        elapsed = 0
        collector = []
        duplicates = nil
        duplicatesMessage = nil
        changes = []
        changesSince = nil
        insights = nil
        flagged = [:]
        flaggedAncestors = []
        hover = nil
        lastMessage = nil
        phase = .idle
    }

    // MARK: Scanning

    func scan() {
        cancel()
        restoreGeneration += 1
        isLoadingSavedScan = false
        let scanner = DiskScanner()
        self.scanner = scanner
        phase = .scanning
        restoredAt = nil
        root = nil
        focus = nil
        collector = []
        duplicates = nil
        duplicatesMessage = nil
        changes = []
        changesSince = nil
        insights = nil
        flagged = [:]
        flaggedAncestors = []
        let url = target.url
        let targetID = target.id
        loadVolume()
        let cache = cache

        // Progress poll.
        Task { [weak self] in
            while let self, self.phase == .scanning {
                self.progress = scanner.progress
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try scanner.scan(url)
                var changes: [ScanSnapshot.Change] = []
                var since: Date?
                var insights: SpaceInsights?
                if !result.cancelled {
                    // The saved scan is only replaced by a completed one; a cancelled scan keeps
                    // whatever was saved before it.
                    let scannedAt = Date()
                    let snapshot = ScanSnapshot(root: result.root, date: scannedAt)
                    let previous = ScanSnapshot.load(root: snapshot.root)
                    if let previous {
                        changes = snapshot.changes(since: previous)
                        since = previous.date
                    }
                    insights = SpaceInsights.find(in: result.root, previous: previous, now: scannedAt)
                    try? snapshot.save()
                    try? cache.save(result: result, scannedAt: scannedAt)
                }
                await MainActor.run {
                    guard let self, self.scanner === scanner else { return }
                    self.root = result.root
                    self.focus = result.root
                    self.progress = result.progress
                    self.elapsed = result.elapsed
                    self.phase = result.cancelled ? .idle : .done
                    self.changes = changes
                    self.changesSince = since
                    self.setInsights(insights, root: result.root)
                    self.revision += 1
                    if !result.cancelled {
                        UserDefaults.standard.set(targetID, forKey: Self.lastScanTargetKey)
                    }
                }
            } catch is MaterializeProtectionError {
                await MainActor.run {
                    guard let self, self.scanner === scanner else { return }
                    self.phase = .failed(String(localized: "Scanning did not run because macOS would not stop automatic downloads of cloud-only files."))
                }
            } catch {
                await MainActor.run {
                    guard let self, self.scanner === scanner else { return }
                    self.phase = .failed("\(error)")
                }
            }
        }
    }

    /// Largest files under `node`, filtered by kind and age.
    func largestFiles(in node: DiskNode, limit: Int = 100) -> [DiskNode] {
        let cutoff = olderThanDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        let candidates = (kindFilter == nil && cutoff == nil) ? node.largestFiles(limit: limit) : node.largestFiles(limit: 5000)
        return Array(candidates.filter { f in
            (kindFilter == nil || FileKind.of(f.name) == kindFilter) && (cutoff == nil || f.modified < cutoff!)
        }.prefix(limit))
    }

    func findDuplicates() async {
        guard let root, ScanCacheSafety.isLiveScan(root), !findingDuplicates else { return }
        findingDuplicates = true
        defer { findingDuplicates = false }
        var paths: [String] = []
        root.forEach { if !$0.isDirectory { paths.append($0.path) } }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try DuplicateFinder.findChecked(paths: paths, minSize: 1 << 20)
            }.value
            guard self.root === root else { return }
            duplicates = result.groups
            var notes: [String] = []
            if result.cloudOnlyFiles > 0 {
                notes.append(String(localized: "\(result.cloudOnlyFiles) cloud-only files were skipped and not downloaded."))
            }
            if result.unreadableFiles > 0 {
                notes.append(String(localized: "\(result.unreadableFiles) files could not be read."))
            }
            duplicatesMessage = notes.isEmpty ? nil : notes.joined(separator: " ")
        } catch is MaterializeProtectionError {
            guard self.root === root else { return }
            duplicates = nil
            duplicatesMessage = String(localized: "Duplicate search did not run because macOS would not stop automatic downloads of cloud-only files.")
        } catch {
            guard self.root === root else { return }
            duplicates = nil
            duplicatesMessage = String(localized: "Duplicate search failed: \(error.localizedDescription)")
        }
    }

    /// Puts every copy except the oldest into the collector.
    func collectDuplicates(_ group: DuplicateGroup) {
        guard let root, ScanCacheSafety.isLiveScan(root) else { return }
        for f in group.files.dropFirst() { addToCollector(path: f.path) }
    }

    func node(atPath path: String) -> DiskNode? { root?.descendant(atPath: path) }

    func setInsights(_ i: SpaceInsights?, root: DiskNode) {
        insights = i
        var f: [ObjectIdentifier: String] = [:]
        for b in i?.bloatedFolders ?? [] {
            if let n = root.descendant(atPath: b.path) { f[ObjectIdentifier(n)] = Self.reasonText(b) }
        }
        for u in i?.unusedFiles ?? [] {
            if let n = root.descendant(atPath: u.path) { f[ObjectIdentifier(n)] = Self.reasonText(u) }
        }
        flagged = f
        var a = Set<ObjectIdentifier>()
        for b in i?.bloatedFolders ?? [] { root.descendant(atPath: b.path)?.lineage.dropLast().forEach { a.insert(ObjectIdentifier($0)) } }
        for u in i?.unusedFiles ?? [] { root.descendant(atPath: u.path)?.lineage.dropLast().forEach { a.insert(ObjectIdentifier($0)) } }
        flaggedAncestors = a
    }

    func containsFlagged(_ node: DiskNode?) -> Bool { node.map { flaggedAncestors.contains(ObjectIdentifier($0)) } ?? false }

    func flag(_ node: DiskNode?) -> String? { node.flatMap { flagged[ObjectIdentifier($0)] } }

    static func reasonText(_ b: SpaceInsights.BloatedFolder) -> String {
        b.reasons.map { r -> String in
            switch r {
            case .grew:
                let by = Fmt.bytes(Int64(clamping: b.grownBy ?? 0))
                return b.since.map { String(localized: "Grew \(by) since \($0.formatted(date: .abbreviated, time: .omitted))") } ?? String(localized: "Grew \(by)")
            case .largeCache: return String(localized: "Unusually large cache")
            case .largeLogs: return String(localized: "Unusually large logs")
            case .manyFiles: return String(localized: "\((b.directFiles ?? 0).formatted()) files directly inside")
            }
        }.joined(separator: ", ")
    }

    static func reasonText(_ u: SpaceInsights.UnusedFile) -> String {
        String(localized: "Not used since \(u.lastUsed.formatted(date: .abbreviated, time: .omitted))")
    }

    func cancel() {
        scanner?.cancel()
        scanner = nil
        if phase == .scanning { phase = .idle }
    }

    // MARK: Navigation

    func zoom(to node: DiskNode) {
        guard node.isDirectory else { return }
        focus = node
        revision += 1
    }

    func zoomOut() {
        if let parent = focus?.parent { zoom(to: parent) }
    }

    // MARK: Collector

    func addToCollector(_ node: DiskNode) {
        guard ScanCacheSafety.isLiveScan(node) else { return }
        // Adding a folder supersedes anything already collected inside it, and vice versa.
        guard !collector.contains(where: { $0 === node || node.path.hasPrefix($0.path + "/") }) else { return }
        collector.removeAll { $0.path.hasPrefix(node.path + "/") }
        collector.append(node)
    }

    func addToCollector(path: String) {
        if let node = root?.descendant(atPath: path) { addToCollector(node) }
    }

    func removeFromCollector(_ node: DiskNode) {
        collector.removeAll { $0 === node }
    }

    /// Moves everything in the collector to the Trash (with the safety checks and operation log).
    func trashCollector() async {
        guard !collector.isEmpty, collector.allSatisfy(ScanCacheSafety.isLiveScan) else { return }
        let items = collector.map { RemovalItem(path: $0.path, source: "analyzer", bytes: $0.size, action: .trash) }
        let report = await Task.detached {
            CleanExecutor(safety: .forAnalysis()).execute(items, dryRun: false, command: "analyze")
        }.value
        let done = Set(report.items.filter { $0.result == .trashed }.map(\.path))
        for node in collector where done.contains(node.path) { node.detachFromTree() }
        collector.removeAll { done.contains($0.path) }
        let failed = report.items.filter { $0.result != .trashed }
        lastMessage = failed.isEmpty
            ? String(localized: "Moved \(Fmt.bytes(Int64(clamping: report.trashedBytes))) to the Trash. The space is freed when you empty the Trash.")
            : String(localized: "Removed \(done.count) items; \(failed.count) not processed: \(failed.first?.message ?? "")")
        revision += 1
    }

    // MARK: Finder

    func revealInFinder(_ node: DiskNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func quickLook(_ node: DiskNode) {
        previewURL = node.url
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func hoverInfo(for node: DiskNode?, otherSize: UInt64 = 0, otherCount: Int = 0) -> HoverInfo? {
        if let node {
            let detail: String
            if node.skippedCloudOnly {
                detail = String(localized: "Only in the cloud; contents were not downloaded")
            } else if node.isDirectory {
                detail = String(localized: "\(node.fileCount.formatted()) files")
            } else {
                detail = node.modified.formatted(date: .abbreviated, time: .omitted)
            }
            return HoverInfo(title: node.name, size: node.size, path: node.path, detail: detail, flag: flag(node))
        }
        guard otherSize > 0 else { return nil }
        return HoverInfo(title: String(localized: "Other smaller items"), size: otherSize, path: nil, detail: String(localized: "\(otherCount.formatted()) items"), flag: nil)
    }
}
