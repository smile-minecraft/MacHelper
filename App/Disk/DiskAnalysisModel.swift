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
    /// `volumeUUIDString`; nil when the volume has none. Used to decide whether a scan and these
    /// figures describe the same volume.
    let identifier: String?
    /// Mount point from `statfs`, e.g. "/" or "/System/Volumes/Data".
    let mountPath: String?
    let snapshots: LocalSnapshots

    var used: Int64 { total - available }
    /// Space macOS can reclaim on demand (mostly Time Machine local caches and system caches).
    var purgeable: Int64 { max(availableForImportant - available, 0) }

    var spaceVolume: SpaceAccounting.Volume? {
        guard let identifier else { return nil }
        return SpaceAccounting.Volume(identifier: identifier, total: total, available: available,
                                      availableForImportantUsage: availableForImportant)
    }

    static func load(for url: URL) -> VolumeSummary? {
        // Read through a new URL object every time. FileManager keeps the capacity it read on a
        // URL value, so a long-lived URL would keep reporting the free space from when it was
        // created and the figures would never rise after cleaning.
        let fresh = URL(fileURLWithPath: url.path)
        guard let v = try? fresh.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                          .volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeUUIDStringKey]),
              let total = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacity
        else { return nil }
        return VolumeSummary(total: Int64(total), available: Int64(avail),
                             availableForImportant: v.volumeAvailableCapacityForImportantUsage ?? Int64(avail),
                             identifier: v.volumeUUIDString,
                             mountPath: mountPath(of: fresh),
                             snapshots: LocalSnapshots.query(for: fresh))
    }

    /// The volume's mount point. Comparing it with a scan root's canonical path tells whether the
    /// scan covered that whole volume.
    static func mountPath(of url: URL) -> String? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
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
    /// Volume the current live scan ran on, and whether its root was that volume's mount point.
    /// Kept beside the scan result so the summary can say why its total is or isn't comparable.
    private(set) var scanVolumeIdentifier: String?
    private(set) var scanCoversVolume = false
    /// False when the live scan was stopped before it finished.
    private(set) var scanIsComplete = false
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
    // Filters for the largest-files list; the charts use the same conditions to point out matches.
    var kindFilter: FileKind?
    var olderThanDays: Int?
    var searchText: String = ""
    /// Minimum allocated size for a file to match; 0 = any size.
    var minFileBytes: UInt64 = 0
    var lastMessage: String?
    var previewURL: URL?

    @ObservationIgnored private var scanner: DiskScanner?
    @ObservationIgnored private let cache = ScanResultCache()
    @ObservationIgnored private var restoreGeneration = 0
    @ObservationIgnored private var isLoadingSavedScan = false

    /// Restoring a saved scan parses a multi-megabyte JSON tree and rebuilds every node. Keep
    /// the last two restored trees for this session so switching back to a location is instant;
    /// the tree is still labelled with its scan date and can be replaced by a rescan.
    private struct CachedTree {
        let scannedAt: Date
        let elapsed: TimeInterval
        let progress: ScanProgress
        let tree: DiskNode
        let insights: SpaceInsights?
    }
    @ObservationIgnored private var treeCache: [String: CachedTree] = [:]
    @ObservationIgnored private let fileFilterCache = FileFilterCache()
    private struct CachedVolume {
        let summary: VolumeSummary
        let at: Date
    }
    @ObservationIgnored private var volumeCache: [String: CachedVolume] = [:]
    @ObservationIgnored private var volumeOrder: [String] = []
    /// Distinguishes volume reads so a slow, older read can't replace a newer one (the scan
    /// completion reads the volume again and must win over the read taken when the scan started).
    @ObservationIgnored private var volumeReadGeneration = 0
    /// The volume figures are cheap to read but `tmutil` starts a process; reuse a recent read.
    static let volumeMaxAge: TimeInterval = 60
    /// Only a handful of mounted volumes are shown at once; this also keeps a removable
    /// volume from being remembered forever.
    private static let volumeCacheLimit = 8

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

    /// What the screen may say about the scan's total against the volume's usage.
    var spaceAccounting: SpaceAccounting {
        guard let root else { return .evaluate(scan: nil, volume: volume?.spaceVolume) }
        let isLive = restoredAt == nil
        let scan = SpaceAccounting.Scan(
            rootPath: root.path,
            volumeIdentifier: isLive ? scanVolumeIdentifier : nil,
            coversVolume: isLive && scanCoversVolume,
            bytes: root.size,
            limits: SpaceAccounting.Limits(progress: progress),
            isLive: isLive,
            isComplete: isLive ? scanIsComplete : true)
        return .evaluate(scan: scan, volume: volume?.spaceVolume)
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
        let key = cacheKey(for: target.url)
        do {
            try cache.clear(rootPath: key)
        } catch {
            lastMessage = String(localized: "The saved scan could not be cleared: \(error.localizedDescription)")
            return
        }
        treeCache.removeValue(forKey: key)
        resetDisplay()
        isLoadingSavedScan = false
        revision += 1
    }

    private func loadSavedScan() {
        // The synthetic `--snapshot-demo` run never opens this Mac's saved scans.
        guard !DemoData.snapshot else { return }
        let key = cacheKey(for: target.url)
        if let cached = treeCache[key] {
            restoreGeneration += 1
            isLoadingSavedScan = false
            applySavedScan(cached)
            PageLoadProbe.mark(.disk, "cache")
            PageLoadProbe.mark(.disk, "content")
            loadVolume()
            return
        }
        restoreGeneration += 1
        let generation = restoreGeneration
        isLoadingSavedScan = true
        let cache = cache
        Task { [weak self] in
            // Return only the restored tree and its small metadata. Keeping the decoded
            // `ScanResultSnapshot` alive until the main actor receives it doubles the peak
            // memory of a large saved scan for no benefit.
            let loaded = await Task.detached(priority: .userInitiated) {
                () -> (Date, TimeInterval, ScanProgress, DiskNode, SpaceInsights)? in
                guard let snapshot = cache.load(rootPath: key), let tree = snapshot.rebuildTree() else { return nil }
                // A saved scan is a record: nothing under its root is looked up, so only folder findings.
                var options = SpaceInsights.Options()
                options.minFileSize = .max
                let insights = SpaceInsights.find(in: tree, options: options, lastUse: { _ in nil })
                return (snapshot.scannedAt, snapshot.elapsed, snapshot.progress, tree, insights)
            }.value
            guard let self, self.restoreGeneration == generation else { return }
            self.isLoadingSavedScan = false
            guard let (scannedAt, elapsed, progress, tree, insights) = loaded else {
                PageLoadProbe.mark(.disk, "empty")
                return
            }
            let restored = CachedTree(scannedAt: scannedAt, elapsed: elapsed, progress: progress,
                                      tree: tree, insights: insights)
            self.treeCache[key] = restored
            self.evictTreeCache(keeping: key)
            self.applySavedScan(restored)
            PageLoadProbe.mark(.disk, "content")
            self.loadVolume()
        }
    }

    private func applySavedScan(_ cached: CachedTree) {
        setInsights(cached.insights, root: cached.tree)
        scanVolumeIdentifier = nil
        scanCoversVolume = false
        scanIsComplete = true
        root = cached.tree
        focus = cached.tree
        progress = cached.progress
        elapsed = cached.elapsed
        restoredAt = cached.scannedAt
        phase = .done
        revision += 1
    }

    /// Two restored trees cover switching back and forth between the usual locations without
    /// keeping every scanned tree in memory.
    private func evictTreeCache(keeping key: String) {
        guard treeCache.count > 2 else { return }
        for old in Array(treeCache.keys) where old != key {
            treeCache.removeValue(forKey: old)
            if treeCache.count <= 2 { break }
        }
    }

    /// Drops restored trees for locations other than the one on screen. The page calls this
    /// when it closes, so a large scan tree is not kept for a location nobody is looking at.
    func trimCachedTrees() {
        let current = cacheKey(for: target.url)
        treeCache = treeCache.filter { $0.key == current }
        let volumeKey = target.url.path
        volumeCache = volumeCache.filter { $0.key == volumeKey }
        volumeOrder = volumeCache.isEmpty ? [] : [volumeKey]
    }

    /// The cache key for a scan location: the same resolved path the scanner records.
    private func cacheKey(for url: URL) -> String {
        DiskScanner.canonicalPath(url)
    }

    private func loadVolume(force: Bool = false) {
        guard !DemoData.snapshot else { return }
        let url = target.url
        let key = url.path
        if let cached = volumeCache[key] {
            volume = cached.summary
            PageLoadProbe.mark(.disk, "volume")
            if !force, Date().timeIntervalSince(cached.at) < Self.volumeMaxAge {
                return
            }
        } else {
            volume = nil
        }
        volumeReadGeneration += 1
        let generation = volumeReadGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let summary = VolumeSummary.load(for: url)
            await MainActor.run {
                guard let self, self.volumeReadGeneration == generation, self.target.url == url else { return }
                guard let summary else { return }
                self.volume = summary
                self.storeVolume(summary, for: key)
                PageLoadProbe.mark(.disk, "volume")
                PageLoadProbe.mark(.disk, "volume-refresh")
            }
        }
    }

    private func storeVolume(_ summary: VolumeSummary, for key: String) {
        if volumeCache[key] == nil { volumeOrder.append(key) }
        volumeCache[key] = CachedVolume(summary: summary, at: Date())
        while volumeOrder.count > Self.volumeCacheLimit {
            let old = volumeOrder.removeFirst()
            volumeCache.removeValue(forKey: old)
        }
    }

    private func resetDisplay() {
        restoredAt = nil
        scanVolumeIdentifier = nil
        scanCoversVolume = false
        scanIsComplete = false
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
        let treeKey = cacheKey(for: url)
        scanVolumeIdentifier = nil
        scanCoversVolume = false
        scanIsComplete = false
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
                var restored: CachedTree?
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
                    restored = CachedTree(scannedAt: scannedAt, elapsed: result.elapsed,
                                          progress: result.progress, tree: result.root, insights: insights)
                }
                // Read the volume after the scan rather than reusing the figures from its start,
                // so the comparison describes the disk as the scan left it. A process launch, so
                // it stays off the main actor.
                let volumeInfo = VolumeSummary.load(for: url)
                await MainActor.run {
                    guard let self, self.scanner === scanner else { return }
                    if let restored {
                        self.treeCache[treeKey] = restored
                        self.evictTreeCache(keeping: treeKey)
                    }
                    if let volumeInfo {
                        self.volumeReadGeneration += 1
                        self.volume = volumeInfo
                        self.storeVolume(volumeInfo, for: url.path)
                    }
                    self.scanVolumeIdentifier = volumeInfo?.identifier
                    self.scanCoversVolume = volumeInfo?.mountPath == result.root.path
                    self.scanIsComplete = !result.cancelled
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
                        PageLoadProbe.mark(.disk, "content")
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

    /// The conditions currently set for the largest-files list and the charts.
    var fileFilter: FileFilter {
        FileFilter(text: searchText, minBytes: minFileBytes, kind: kindFilter, olderThanDays: olderThanDays)
    }

    var isFileFilterActive: Bool { fileFilter.isActive }

    func clearFileFilters() {
        searchText = ""
        minFileBytes = 0
        kindFilter = nil
        olderThanDays = nil
    }

    /// Filter outcome for `node`, memoized on (tree, revision, filter) so the charts can ask on
    /// every frame without walking the tree again. The age bound is fixed when an entry is
    /// computed; the cache drops stale entries as soon as the tree or any condition changes.
    func fileFilterResult(in node: DiskNode) -> FileFilterResult {
        fileFilterCache.result(for: node, revision: revision, filter: fileFilter)
    }

    /// Largest files under `node`. The filter is applied before ranking, so a matching file is
    /// never dropped just because many larger files fail the filter.
    func largestFiles(in node: DiskNode, limit: Int = 100) -> [DiskNode] {
        let filter = fileFilter
        guard filter.isActive else { return node.largestFiles(limit: limit) }
        return Array(fileFilterResult(in: node).files.prefix(limit))
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

    #if DEBUG
    /// Shows a synthetic tree as if a scan had just finished (`--snapshot-demo`). Nothing on
    /// disk is scanned, restored or measured; the volume figures are the demo's too.
    func showDemo(root: DiskNode, volume: VolumeSummary, files: Int, elapsed: TimeInterval) {
        cancel()
        // The picker shows the home folder whatever location this Mac scanned last.
        if let home = targets.first(where: { $0.id == "home" }) { target = home }
        self.root = root
        focus = root
        self.volume = volume
        progress = ScanProgress(files: files, directories: files / 9, bytes: root.size, unreadableDirectories: 0)
        self.elapsed = elapsed
        restoredAt = nil
        scanVolumeIdentifier = volume.identifier
        scanCoversVolume = false
        scanIsComplete = true
        phase = .done
        revision += 1
        // Spotlight is never asked about the made-up paths.
        setInsights(SpaceInsights.find(in: root, lastUse: { _ in nil }), root: root)
    }
    #endif

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

    /// Whether the last zoom went into a folder (true) or back up (false): the charts' zoom
    /// transition grows in or shrinks back accordingly.
    @ObservationIgnored private(set) var zoomedIn = true

    func zoom(to node: DiskNode) {
        guard node.isDirectory else { return }
        if let old = focus { zoomedIn = node.path.hasPrefix(old.path + "/") }
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

    /// Folders of the current scan that couldn't be read for the given reason, sorted by path.
    func unreadableFolders(_ kind: ReadFailure) -> [String] {
        guard let root else { return [] }
        var out: [String] = []
        var stack = [root]
        while let n = stack.popLast() {
            if n.isDirectory, n.readError != 0, !n.skippedCloudOnly,
               ReadFailure.classify(path: n.path, code: n.readError) == kind { out.append(n.path) }
            stack.append(contentsOf: n.children)
        }
        return out.sorted()
    }

    func openFullDiskAccessSettings() {
        SystemSettingsPane.fullDiskAccess.open()
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
