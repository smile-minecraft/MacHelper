import Foundation
import Metrics
import Observation
import Storage

extension Notification.Name {
    /// Posted after the in-process Settings window successfully deletes the monitoring
    /// history. The SSD page invalidates its displayed points and requeries immediately.
    /// Background or other-process clears do not post this; the page's low-frequency refresh
    /// notices those instead.
    static let monitoringHistoryCleared = Notification.Name("MacHelper.monitoringHistoryCleared")
}

/// What the SSD page shows for the selected disk. The model owns the selection, the mounted
/// volume snapshot, and the seven-day history request; the view only renders its state.
///
/// Sampling and history reads are injected, so tests can use fake volumes and control the order
/// of asynchronous replies. The production reader is created from the shared history database
/// by `historyReader(for:)`; the model never opens a database itself.
@MainActor
@Observable
final class DiskCapacitySelectionModel {
    typealias VolumeSampler = @Sendable () throws -> [DiskVolume]
    typealias HistoryReader = @Sendable (_ volumeID: String,
                                         _ since: Date,
                                         _ until: Date) async throws -> [VolumeCapacityPoint]
    typealias Clock = @Sendable () -> Date

    /// The chart's horizon. Capacity is recorded once an hour.
    static let historyWindow: TimeInterval = 7 * 86_400
    /// The history store's upper bound is exclusive, so the query ends just after `now`.
    static let historyUpperBoundPadding: TimeInterval = 1
    /// The page's timer ticks once a minute. This is slightly shorter so a tick is not lost to
    /// scheduling jitter; it still keeps the history query away from the per-second view updates.
    static let historyRefreshInterval: TimeInterval = 55

    struct VolumeOption: Identifiable, Hashable, Sendable {
        let key: String
        let volume: DiskVolume
        var id: String { key }
    }

    enum VolumesState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum SelectionState: Equatable, Sendable {
        case none
        case available(DiskVolume)
        case unidentifiable(DiskVolume)
        case unmounted(DiskVolume)
    }

    enum HistoryUnavailableReason: Equatable, Sendable {
        case noIdentity
        case notMounted
        case noHistoryStore
    }

    enum HistoryState: Equatable, Sendable {
        case idle
        case loading(volumeID: String)
        case loaded(volumeID: String, points: [VolumeCapacityPoint])
        case failed(volumeID: String, message: String)
        case unavailable(volumeID: String?, reason: HistoryUnavailableReason)
    }

    private enum VolumeSampleOutcome: Sendable {
        case volumes([DiskVolume])
        case failure(String)
    }

    struct Capacity: Equatable, Sendable {
        let totalBytes: Int64
        let availableBytes: Int64

        init?(volume: DiskVolume) {
            guard let total = volume.totalBytes, let available = volume.availableBytes,
                  total > 0, available >= 0 else { return nil }
            self.totalBytes = total
            self.availableBytes = available
        }

        var usedFraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(max(1 - Double(availableBytes) / Double(totalBytes), 0), 1)
        }
    }

    private(set) var volumes: [VolumeOption] = []
    private(set) var volumesState: VolumesState = .idle
    private(set) var selectedKey: String?
    private(set) var selectionState: SelectionState = .none
    private(set) var historyState: HistoryState = .idle
    private(set) var historyQueryNow: Date?

    @ObservationIgnored private let sampleVolumes: VolumeSampler
    @ObservationIgnored private var readHistory: HistoryReader?
    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private var volumesInFlight = false
    @ObservationIgnored private var historyInFlight = false
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var historyGeneration = 0

    init(sampleVolumes: @escaping VolumeSampler = { DiskVolumeSampler().sample() },
         readHistory: HistoryReader? = nil,
         clock: @escaping Clock = { Date() }) {
        self.sampleVolumes = sampleVolumes
        self.readHistory = readHistory
        self.clock = clock
    }

    // MARK: - Presentation state

    var selectedVolume: DiskVolume? {
        switch selectionState {
        case .available(let volume), .unidentifiable(let volume), .unmounted(let volume):
            volume
        case .none:
            nil
        }
    }

    var selectedVolumeID: String? { selectedVolume?.persistentID?.rawValue }

    var isMountedSelection: Bool {
        switch selectionState {
        case .available, .unidentifiable: true
        case .unmounted, .none: false
        }
    }

    var capacity: Capacity? {
        switch selectionState {
        case .available(let volume), .unidentifiable(let volume):
            Capacity(volume: volume)
        case .unmounted, .none:
            nil
        }
    }

    var isSharedCapacity: Bool {
        guard let sharing = selectedVolume?.capacitySharing, case .sharedContainer = sharing else {
            return false
        }
        return true
    }

    var historyPoints: [VolumeCapacityPoint] {
        guard case .loaded(let volumeID, let points) = historyState,
              volumeID == selectedVolumeID else { return [] }
        return points
    }

    var historyVolumeID: String? {
        switch historyState {
        case .loaded(let volumeID, _), .loading(let volumeID), .failed(let volumeID, _):
            volumeID
        case .unavailable(let volumeID, _):
            volumeID
        case .idle:
            selectedVolumeID
        }
    }

    var historyNow: Date { historyQueryNow ?? clock() }

    // MARK: - Actions

    /// Connects the shared history reader and refreshes the page immediately. Calling this
    /// again (the page reappeared or the tab was recreated) must pick up points written since
    /// the last query, so it always refreshes instead of guarding on a first-connect flag.
    func connect(reader: HistoryReader?) {
        readHistory = reader
        refreshAll(forceHistory: true)
    }

    /// Refreshes the mounted volumes and the selected disk's history. The visible page calls
    /// this on a slow timer with `forceHistory: false`, so the chart's time window advances at
    /// most once a minute. Page reappearance and the manual refresh button pass `true` to query
    /// immediately. A clear performed by another process cannot post the in-process event, so
    /// this low-frequency path is also what notices it.
    func refreshAll(forceHistory: Bool) {
        startVolumeSample()
        refreshHistory(force: forceHistory)
    }

    /// The page's regular refresh. It also advances the history window when the low-frequency
    /// interval has passed, so an existing caller that only knew this method still updates the
    /// chart instead of leaving it on the first query forever.
    func refreshVolumes() {
        startVolumeSample()
        refreshHistory(force: false)
    }

    /// Re-reads the mounted volumes. At most one sample is in flight: Disk Arbitration has no
    /// timeout, so a blocked sample must not accumulate one thread per refresh. A later refresh
    /// can start a new sample after the previous one returns.
    private func startVolumeSample() {
        guard !volumesInFlight else { return }
        volumesInFlight = true
        if volumes.isEmpty { volumesState = .loading }
        let sampler = sampleVolumes
        Task { [weak self] in
            let outcome: VolumeSampleOutcome = await Task.detached(priority: .utility) {
                do {
                    return .volumes(try sampler())
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value
            guard let self else { return }
            self.volumesInFlight = false
            guard !Task.isCancelled else { return }
            self.applyVolumes(outcome)
        }
    }

    /// Re-queries the selected disk's history. Without `force`, a query already in flight or one
    /// started less than `historyRefreshInterval` ago is kept, so per-second view updates cannot
    /// start expensive queries. `force` is for explicit actions (page reappearance, manual
    /// refresh, retry, clear) and supersedes an older query through the generation guard.
    func refreshHistory(force: Bool) {
        guard case .available(let volume) = selectionState,
              let volumeID = volume.persistentID?.rawValue else { return }
        guard readHistory != nil else {
            // A query that started before the reader went away must not be able to write its
            // points or error back once this nil-reader branch runs.
            stopHistory(reason: .noHistoryStore, volumeID: volumeID)
            return
        }
        if !force {
            if historyInFlight { return }
            if let last = historyQueryNow,
               clock().timeIntervalSince(last) < Self.historyRefreshInterval { return }
        }
        startHistory(for: volume)
    }

    /// Invalidates every displayed point after an in-process clear succeeded. The generation
    /// advances before the new query starts, so a query that began before the clear can never
    /// write its old points back. If the page is not visible, the next `connect` or the
    /// low-frequency refresh performs the same query path.
    func historyDidClear() {
        historyTask?.cancel()
        historyTask = nil
        historyGeneration += 1
        historyInFlight = false
        historyQueryNow = nil

        switch selectionState {
        case .available(let volume):
            guard let volumeID = volume.persistentID?.rawValue else {
                historyState = .unavailable(volumeID: nil, reason: .noIdentity)
                return
            }
            historyState = .loading(volumeID: volumeID)
            startHistory(for: volume)
        case .unidentifiable:
            historyState = .unavailable(volumeID: nil, reason: .noIdentity)
        case .unmounted:
            historyState = .unavailable(volumeID: selectedVolumeID, reason: .notMounted)
        case .none:
            historyState = .idle
        }
    }

    /// Selects a volume from the last successful sample. A key that is not in the list is
    /// ignored; the view only offers keys from `volumes`.
    func select(_ key: String?) {
        guard let key, let option = volumes.first(where: { $0.key == key }) else { return }
        if key == selectedKey, case .available = selectionState { return }
        applySelection(option)
    }

    /// Retries a failed history read for the current disk without changing the selection.
    func retryHistory() {
        guard case .available(let volume) = selectionState else { return }
        startHistory(for: volume)
    }

    // MARK: - Selection

    private func applyVolumes(_ outcome: VolumeSampleOutcome) {
        switch outcome {
        case .failure(let message):
            volumesState = .failed(message)
            if selectedKey == nil { selectionState = .none }
        case .volumes(let sampled):
            volumes = sampled.map { VolumeOption(key: Self.selectionKey(for: $0), volume: $0) }
            volumesState = .loaded
            if selectedKey == nil {
                selectDefaultVolume()
            } else {
                resolveSelection()
            }
        }
    }

    private func selectDefaultVolume() {
        guard let option = volumes.first(where: { $0.volume.role == .system }) ?? volumes.first else {
            selectedKey = nil
            selectionState = .none
            historyState = .idle
            historyQueryNow = nil
            return
        }
        applySelection(option)
    }

    private func applySelection(_ option: VolumeOption) {
        selectedKey = option.key
        guard option.volume.persistentID != nil else {
            selectionState = .unidentifiable(option.volume)
            stopHistory(reason: .noIdentity, volumeID: nil)
            return
        }
        selectionState = .available(option.volume)
        startHistory(for: option.volume)
    }

    /// Reconciles the current selection with a fresh sample. A selected disk that disappeared
    /// stays selected and is shown as unmounted; it is never replaced by another disk.
    private func resolveSelection() {
        guard let selectedKey else {
            selectionState = .none
            return
        }
        guard let option = volumes.first(where: { $0.key == selectedKey }) else {
            let lastKnown = selectedVolume
            selectionState = lastKnown.map(SelectionState.unmounted) ?? .none
            stopHistory(reason: .notMounted, volumeID: lastKnown?.persistentID?.rawValue)
            return
        }

        let previousID = selectedVolume?.persistentID?.rawValue
        guard option.volume.persistentID != nil else {
            selectionState = .unidentifiable(option.volume)
            stopHistory(reason: .noIdentity, volumeID: nil)
            return
        }
        selectionState = .available(option.volume)
        if previousID != option.volume.persistentID?.rawValue || shouldStartHistory {
            startHistory(for: option.volume)
        }
    }

    private var shouldStartHistory: Bool {
        switch historyState {
        case .idle, .unavailable: true
        case .loading, .loaded, .failed: false
        }
    }

    // MARK: - History

    private func startHistory(for volume: DiskVolume) {
        historyTask?.cancel()
        historyGeneration += 1
        let generation = historyGeneration
        historyInFlight = false

        guard let volumeID = volume.persistentID?.rawValue else {
            historyState = .unavailable(volumeID: nil, reason: .noIdentity)
            historyQueryNow = nil
            return
        }
        guard let reader = readHistory else {
            historyState = .unavailable(volumeID: volumeID, reason: .noHistoryStore)
            historyQueryNow = nil
            return
        }

        let queryNow = clock()
        historyQueryNow = queryNow
        historyState = .loading(volumeID: volumeID)
        historyInFlight = true
        let since = queryNow.addingTimeInterval(-Self.historyWindow)
        let until = queryNow.addingTimeInterval(Self.historyUpperBoundPadding)

        historyTask = Task { [weak self] in
            do {
                let points = try await Task.detached(priority: .utility) {
                    try await reader(volumeID, since, until)
                }.value
                guard let self, !Task.isCancelled,
                      generation == self.historyGeneration,
                      self.selectedVolumeID == volumeID else { return }
                self.historyInFlight = false
                self.historyState = .loaded(volumeID: volumeID, points: points)
            } catch {
                guard let self, !Task.isCancelled,
                      generation == self.historyGeneration,
                      self.selectedVolumeID == volumeID else { return }
                self.historyInFlight = false
                self.historyState = .failed(volumeID: volumeID, message: error.localizedDescription)
            }
        }
    }

    private func stopHistory(reason: HistoryUnavailableReason, volumeID: String?) {
        historyTask?.cancel()
        historyTask = nil
        historyGeneration += 1
        historyInFlight = false
        historyQueryNow = nil
        historyState = .unavailable(volumeID: volumeID, reason: reason)
    }

    // MARK: - Keys

    nonisolated static func selectionKey(for volume: DiskVolume) -> String {
        if let id = volume.persistentID { return "id:\(id.rawValue)" }
        return "mount:\(volume.mountPoint.path)"
    }
}

// MARK: - Text

/// Every string the SSD page adds. Keeping the keys in one place lets the tests check that the
/// dedicated `DiskVolumeSelection` catalog covers all of them in every shipped language.
enum DiskVolumeSelectionText: String, CaseIterable, Sendable {
    case disk = "Disk"
    case systemDisk = "System disk"
    case dataDisk = "Data disk"
    case localDisk = "Local disk"
    case checkingDisks = "Checking disks…"
    case volumeListError = "Couldn’t read the disk list: %@"
    case tryAgain = "Try Again"
    case refreshDisks = "Refresh disks"
    case capacityUnavailable = "Capacity unavailable"
    case capacityUnavailableDetail = "macOS didn’t report the capacity of this disk."
    case volumeUnidentified = "This disk can’t be identified"
    case volumeUnidentifiedDetail = "macOS didn’t report a stable identity for this disk, so its capacity history can’t be read."
    case volumeUnmounted = "This disk is no longer mounted"
    case volumeUnmountedDetail = "%@ is no longer mounted. Its capacity is not shown instead of switching to another disk."
    case apfsShared = "This disk shares free space with other APFS volumes"
    case apfsSharedDetail = "APFS volumes in the same container draw from one free-space pool. This capacity is not separate space you can add to another disk."
    case activityAllDisks = "Activity (all disks)"
    case activityAllDisksDetail = "Read and write rates cover every disk in this Mac, not only the selected disk."
    case historyLoading = "Loading capacity history…"
    case historyError = "Couldn’t read capacity history: %@"
    case historyNoIdentity = "Capacity history isn’t available because this disk has no stable identity."
    case historyNotMounted = "Capacity history isn’t available because this disk is not mounted."
    case historyNoStore = "Capacity history isn’t available because the history database couldn’t be opened."
    case recordingCaption = "Capacity is recorded once an hour while MacHelper is running. If background recording is off, recording stops when MacHelper quits."
    case clearHistoryMessage = "This permanently deletes all per-minute monitoring history, every metric it contains, and the hourly free-space history for every recorded disk. It can’t be undone. Process usage history, sensor and core history, other settings, and the operation history are not affected."
    case accessibilityVolumePicker = "Choose which disk’s capacity to show"
    case selectedDisk = "Selected disk: %@"
    case selectedDiskUnavailable = "Selected disk unavailable"
    case historyUnavailable = "Capacity history unavailable"

    func localized(in bundle: Bundle = .main, locale: Locale = .current) -> String {
        String(localized: String.LocalizationValue(rawValue),
               table: "DiskVolumeSelection",
               bundle: bundle,
               locale: locale)
    }
}

extension DiskVolumeRole {
    var titleText: DiskVolumeSelectionText {
        switch self {
        case .system: .systemDisk
        case .data: .dataDisk
        case .local: .localDisk
        }
    }
}

extension DiskCapacitySelectionModel.HistoryUnavailableReason {
    var text: DiskVolumeSelectionText {
        switch self {
        case .noIdentity: .historyNoIdentity
        case .notMounted: .historyNotMounted
        case .noHistoryStore: .historyNoStore
        }
    }
}

extension DiskCapacitySelectionModel.VolumeOption {
    /// The volume name, or the role title when macOS reports no name. The name is never used as
    /// identity; it is only what the picker shows.
    func displayName(in bundle: Bundle = .main, locale: Locale = .current) -> String {
        if let name = volume.name, !name.isEmpty { return name }
        return volume.role.titleText.localized(in: bundle, locale: locale)
    }

    /// System and data volumes can share the same name, so the picker always adds the role.
    func pickerTitle(in bundle: Bundle = .main, locale: Locale = .current) -> String {
        let role = volume.role.titleText.localized(in: bundle, locale: locale)
        guard let name = volume.name, !name.isEmpty else { return role }
        return "\(name) — \(role)"
    }
}

// MARK: - Production history reader

extension DiskCapacitySelectionModel {
    /// Reads the selected volume's points from the shared history database. The store's upper
    /// bound is exclusive, so the caller passes `now + 1`. The read runs off the main actor.
    static func historyReader(for history: MetricsHistory?) -> HistoryReader? {
        guard let history else { return nil }
        let store = VolumeCapacityHistory(history: history)
        return { volumeID, since, until in
            try await Task.detached(priority: .utility) {
                try store.points(volume: volumeID, since: since, until: until)
            }.value
        }
    }
}
