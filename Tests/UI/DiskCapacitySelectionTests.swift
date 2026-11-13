import Darwin
import Dispatch
import Foundation
import Storage
import Testing
@testable import DiskCapacitySelectionFeature
@testable import Metrics

/// The selection model is tested with fake volumes and a fake history reader only. Nothing here
/// samples a real disk, opens the history database, starts the app or the helper, or touches
/// user preferences.
@Suite(.serialized) struct DiskCapacitySelectionTests {
    private let hour: TimeInterval = 3_600
    private let gigabyte: Int64 = 1_000_000_000
    /// A whole hour, so `now` is an hourly boundary.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    private func volume(role: DiskVolumeRole,
                        name: String?,
                        mountPoint: String,
                        id: String?,
                        total: Int64? = 1_000 * 1_000_000_000,
                        available: Int64? = 400 * 1_000_000_000,
                        sharing: DiskCapacitySharing = .independent) -> DiskVolume {
        DiskVolume(role: role,
                   name: name,
                   mountPoint: URL(fileURLWithPath: mountPoint),
                   persistentID: id.map { DiskVolumePersistentID(rawValue: $0) },
                   totalBytes: total,
                   availableBytes: available,
                   capacitySharing: sharing)
    }

    private func point(_ volume: String, hoursAgo: Double, free: Double) -> VolumeCapacityPoint {
        VolumeCapacityPoint(volume: volume,
                            time: now.addingTimeInterval(-hoursAgo * hour),
                            free: free,
                            total: Double(1_000 * gigabyte))
    }

    private var systemVolume: DiskVolume {
        volume(role: .system, name: "Macintosh HD", mountPoint: "/", id: "SYS",
               sharing: .sharedContainer("apfs:disk3"))
    }

    private var dataVolume: DiskVolume {
        volume(role: .data, name: "Macintosh HD - Data", mountPoint: "/System/Volumes/Data", id: "DATA",
               total: 2_000 * gigabyte, available: 500 * gigabyte,
               sharing: .sharedContainer("apfs:disk3"))
    }

    // MARK: - Loading and default selection

    @Test @MainActor func loadsVolumesAndSelectsTheSystemDisk() async throws {
        let system = systemVolume
        let data = dataVolume
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system, data] },
            readHistory: { id, _, _ in [self.point(id, hoursAgo: 1, free: 100)] },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }

        #expect(model.volumes.map(\.volume.role) == [.system, .data])
        #expect(model.selectedKey == DiskCapacitySelectionModel.selectionKey(for: system))
        #expect(model.selectionState == .available(system))

        try await waitUntil("history") { model.historyState.isLoaded }
        #expect(model.historyVolumeID == "SYS")
        #expect(model.historyPoints.map(\.free) == [100])
        #expect(model.historyPoints.allSatisfy { $0.volume == "SYS" })
    }

    @Test @MainActor func samplingRunsOffTheMainThread() async throws {
        let source = SampleSource(.success([systemVolume]))
        let model = DiskCapacitySelectionModel(sampleVolumes: { try source.sample() },
                                               readHistory: { _, _, _ in [] },
                                               clock: { self.now })
        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        #expect(source.recordedOnMainThread() == false)
    }

    @Test @MainActor func historyReadRunsOffTheMainThread() async throws {
        let flag = ThreadFlag()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [self.systemVolume] },
            readHistory: { id, _, _ in
                // `Thread.isMainThread` is unavailable from async contexts; this C check is not.
                flag.set(pthread_main_np() != 0)
                return [self.point(id, hoursAgo: 1, free: 1)]
            },
            clock: { self.now })
        model.refreshVolumes()
        try await waitUntil("history") { model.historyState.isLoaded }
        #expect(flag.value == false)
    }

    @Test @MainActor func samplingFailureIsShownAndDoesNotInventAVolume() async throws {
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { throw SampleFailure() },
            readHistory: { _, _, _ in [] },
            clock: { self.now })
        model.refreshVolumes()
        try await waitUntil("failure") { model.volumesState == .failed("sample failed") }
        #expect(model.volumes.isEmpty)
        #expect(model.selectedKey == nil)
        #expect(model.selectionState == .none)
        #expect(model.historyState == .idle)
    }

    // MARK: - Switching disks

    @Test @MainActor func switchingToTheDataDiskUsesItsOwnIdentityAndCapacity() async throws {
        let system = systemVolume
        let data = dataVolume
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system, data] },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        await gate.waitUntilRequested("SYS")
        await gate.succeed("SYS", [point("SYS", hoursAgo: 2, free: 1)])
        try await waitUntil("system history") { model.historyState.isLoaded }

        model.select(DiskCapacitySelectionModel.selectionKey(for: data))

        #expect(model.selectedVolumeID == "DATA")
        #expect(model.selectionState == .available(data))
        #expect(model.capacity == DiskCapacitySelectionModel.Capacity(volume: data))
        #expect(model.historyPoints.isEmpty)
        #expect(model.historyState == .loading(volumeID: "DATA"))

        await gate.waitUntilRequested("DATA")
        await gate.succeed("DATA", [point("DATA", hoursAgo: 1, free: 2)])
        try await waitUntil("data history") { model.historyState.isLoaded }

        #expect(model.historyVolumeID == "DATA")
        #expect(model.historyPoints.map(\.volume) == ["DATA"])
        #expect(model.historyPoints.map(\.free) == [2])
    }

    @Test @MainActor func aLocalDiskCanBeSelectedAndIsIndependent() async throws {
        let system = systemVolume
        let local = volume(role: .local, name: "Backup", mountPoint: "/Volumes/Backup", id: "BACKUP",
                           total: 500 * gigabyte, available: 100 * gigabyte)
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system, local] },
            readHistory: { id, _, _ in [self.point(id, hoursAgo: 1, free: 3)] },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        model.select(DiskCapacitySelectionModel.selectionKey(for: local))

        #expect(model.selectionState == .available(local))
        #expect(model.selectedVolumeID == "BACKUP")
        #expect(model.capacity == DiskCapacitySelectionModel.Capacity(volume: local))
        #expect(model.isSharedCapacity == false)
        try await waitUntil("history") { model.historyState.isLoaded }
        #expect(model.historyVolumeID == "BACKUP")
    }

    // MARK: - Unmounted and unidentified disks

    @Test @MainActor func unmountingTheSelectedDiskKeepsTheSelectionAndShowsItUnmounted() async throws {
        let system = systemVolume
        let data = dataVolume
        let source = SampleSource(.success([system, data]))
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { try source.sample() },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        model.select(DiskCapacitySelectionModel.selectionKey(for: data))
        await gate.waitUntilRequested("DATA")
        await gate.succeed("DATA", [point("DATA", hoursAgo: 1, free: 2)])
        try await waitUntil("data history") { model.historyState.isLoaded }

        source.set(.success([system]))
        model.refreshVolumes()
        try await waitUntil("unmounted") { model.selectionState.isUnmounted }

        #expect(model.selectedKey == DiskCapacitySelectionModel.selectionKey(for: data))
        #expect(model.selectedKey != DiskCapacitySelectionModel.selectionKey(for: system))
        #expect(model.selectedVolumeID == "DATA")
        #expect(model.historyPoints.isEmpty)
        #expect(model.historyState == .unavailable(volumeID: "DATA", reason: .notMounted))
        #expect(model.isMountedSelection == false)
    }

    @Test @MainActor func remountingTheSelectedDiskRestoresItsHistory() async throws {
        let system = systemVolume
        let data = dataVolume
        let source = SampleSource(.success([system, data]))
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { try source.sample() },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        model.select(DiskCapacitySelectionModel.selectionKey(for: data))
        await gate.waitUntilRequested("DATA")
        await gate.succeed("DATA", [point("DATA", hoursAgo: 3, free: 1)])
        try await waitUntil("first data history") { model.historyState.isLoaded }

        source.set(.success([system]))
        model.refreshVolumes()
        try await waitUntil("unmounted") { model.selectionState.isUnmounted }

        source.set(.success([system, data]))
        model.refreshVolumes()
        // The first data query was the second request; the remount starts the third.
        try await waitForRequestCount(gate, 3)
        await gate.succeed("DATA", [point("DATA", hoursAgo: 1, free: 2)])
        try await waitUntil("remounted history") { model.historyState.isLoaded }

        #expect(model.selectionState == .available(data))
        #expect(model.historyVolumeID == "DATA")
        #expect(model.historyPoints.map(\.free) == [2])
    }

    @Test @MainActor func anUnidentifiableDiskIsShownAndNeverQueriesHistory() async throws {
        let backup = volume(role: .local, name: "Backup", mountPoint: "/Volumes/Backup", id: nil)
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [backup] },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }

        #expect(model.selectionState == .unidentifiable(backup))
        #expect(model.historyState == .unavailable(volumeID: nil, reason: .noIdentity))
        #expect(model.historyPoints.isEmpty)
        #expect(await gate.requestCount() == 0)

        let english = Locale(identifier: "en_US_POSIX")
        let title = model.volumes[0].pickerTitle(in: Bundle.module, locale: english)
        #expect(title == "Backup — Local disk")
    }

    @Test @MainActor func aMissingCapacityIsUnavailableInsteadOfZero() async throws {
        let backup = volume(role: .local, name: "Backup", mountPoint: "/Volumes/Backup", id: "BACKUP",
                            total: nil, available: nil)
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [backup] },
            readHistory: { _, _, _ in [] },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }

        #expect(model.selectionState == .available(backup))
        #expect(model.capacity == nil)
        #expect(model.selectedVolume?.totalBytes == nil)
        #expect(model.selectedVolume?.availableBytes == nil)
    }

    // MARK: - Out-of-order replies and errors

    @Test @MainActor func anOlderReplyCannotOverwriteTheNewSelection() async throws {
        let system = systemVolume
        let data = dataVolume
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system, data] },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        await gate.waitUntilRequested("SYS")

        model.select(DiskCapacitySelectionModel.selectionKey(for: data))
        await gate.waitUntilRequested("DATA")
        #expect(model.historyState == .loading(volumeID: "DATA"))

        // The new selection's reply arrives first.
        await gate.succeed("DATA", [point("DATA", hoursAgo: 1, free: 2)])
        try await waitUntil("data history") { model.historyState.isLoaded }

        // The old reply arrives last and must be ignored.
        await gate.succeed("SYS", [point("SYS", hoursAgo: 1, free: 1)])
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.historyVolumeID == "DATA")
        #expect(model.historyPoints.map(\.volume) == ["DATA"])
        #expect(model.historyPoints.map(\.free) == [2])
    }

    // The blocked sampler keeps the sample started by `connect(reader: nil)` from finishing,
    // which removes the race between the stale reply and the sample-driven reselection. The
    // stale query can then only be dropped by the model's own invalidation path.
    @Test @MainActor func connectNilWhileAHistoryQueryIsInFlightDropsItsLateSuccess() async throws {
        let system = systemVolume
        let source = BlockingSampleSource([system])
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { try source.sample() },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("first sample") { source.startedCount() == 1 }
        source.release()
        try await waitUntil("first sample finished") { source.completedCount() == 1 }
        try await Task.sleep(for: .milliseconds(30))
        try await waitUntil("volumes") { model.volumesState == .loaded }
        await gate.waitUntilRequested("SYS")
        await gate.succeed("SYS", [point("SYS", hoursAgo: 1, free: 5)])
        try await waitUntil("history") { model.historyState.isLoaded }
        #expect(model.historyPoints.map(\.free) == [5])

        // A second, slow query is in flight when the reader goes away.
        model.refreshAll(forceHistory: true)
        try await waitForRequestCount(gate, 2)
        try await waitUntil("second sample") { source.startedCount() == 2 }
        model.connect(reader: nil)

        #expect(model.historyState == .unavailable(volumeID: "SYS", reason: .noHistoryStore))
        #expect(model.historyPoints.isEmpty)

        // The in-flight reply carries points from before the disconnect; it must not be shown.
        await gate.succeed(requestAt: 1, [point("SYS", hoursAgo: 1, free: 99)])
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.historyState == .unavailable(volumeID: "SYS", reason: .noHistoryStore))
        #expect(model.historyPoints.isEmpty)

        // Let the sample that refreshAll started finish, then reconnect a real reader.
        source.release()
        try await waitUntil("second sample finished") { source.completedCount() == 2 }
        try await Task.sleep(for: .milliseconds(30))

        model.connect(reader: { id, _, _ in [self.point(id, hoursAgo: 1, free: 7)] })
        try await waitUntil("reconnected history") { model.historyState.isLoaded }
        source.release()
        #expect(model.historyPoints.map(\.free) == [7])
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.historyPoints.map(\.free) == [7])
    }

    @Test @MainActor func connectNilWhileAHistoryQueryIsInFlightDropsItsLateFailure() async throws {
        let system = systemVolume
        let source = BlockingSampleSource([system])
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { try source.sample() },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("first sample") { source.startedCount() == 1 }
        source.release()
        try await waitUntil("first sample finished") { source.completedCount() == 1 }
        try await Task.sleep(for: .milliseconds(30))
        try await waitUntil("volumes") { model.volumesState == .loaded }
        await gate.waitUntilRequested("SYS")
        await gate.succeed("SYS", [point("SYS", hoursAgo: 1, free: 5)])
        try await waitUntil("history") { model.historyState.isLoaded }

        model.refreshAll(forceHistory: true)
        try await waitForRequestCount(gate, 2)
        try await waitUntil("second sample") { source.startedCount() == 2 }
        model.connect(reader: nil)

        #expect(model.historyState == .unavailable(volumeID: "SYS", reason: .noHistoryStore))
        #expect(model.historyPoints.isEmpty)

        // A failure from the in-flight query must not replace the unavailable state either.
        await gate.fail(requestAt: 1, "late failure")
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.historyState == .unavailable(volumeID: "SYS", reason: .noHistoryStore))
        #expect(model.historyPoints.isEmpty)

        // Let the sample that refreshAll started finish, then reconnect a real reader.
        source.release()
        try await waitUntil("second sample finished") { source.completedCount() == 2 }
        try await Task.sleep(for: .milliseconds(30))

        model.connect(reader: { id, _, _ in [self.point(id, hoursAgo: 1, free: 7)] })
        try await waitUntil("reconnected history") { model.historyState.isLoaded }
        source.release()
        #expect(model.historyPoints.map(\.free) == [7])
    }

    @Test @MainActor func aHistoryFailureKeepsTheDiskAndShowsTheError() async throws {
        let system = systemVolume
        let data = dataVolume
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system, data] },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        model.select(DiskCapacitySelectionModel.selectionKey(for: data))
        await gate.waitUntilRequested("DATA")
        await gate.fail("DATA", "history read failed")

        try await waitUntil("failure") { model.historyState.isFailed }
        guard case .failed(let id, let message) = model.historyState else {
            Issue.record("expected a failed history state")
            return
        }
        #expect(id == "DATA")
        #expect(message.contains("history read failed"))
        #expect(model.historyPoints.isEmpty)
        #expect(model.historyVolumeID == "DATA")
        #expect(model.selectedVolumeID == "DATA")
    }

    // MARK: - Query window and refresh cadence

    @Test @MainActor func historyQueryUsesTheSevenDayWindowAndAnExclusiveUpperBound() async throws {
        let system = systemVolume
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        await gate.waitUntilRequested("SYS")

        let recorded = await gate.request("SYS")
        let request = try #require(recorded)
        #expect(request.since == now.addingTimeInterval(-7 * 86_400))
        #expect(request.until == now.addingTimeInterval(1))
        #expect(model.historyNow == now)
        await gate.succeed("SYS", [])
    }

    @Test @MainActor func sameSelectionPicksUpANewPointOnTheLowFrequencyRefresh() async throws {
        let system = systemVolume
        let clock = ClockBox(now)
        let points = PointSource()
        let reader: DiskCapacitySelectionModel.HistoryReader = { id, _, _ in points.points(for: id) }
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: reader,
            clock: { clock.now() })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        try await waitUntil("empty history") { model.historyState.isLoaded }
        #expect(model.historyPoints.isEmpty)
        #expect(model.historyQueryNow == now)

        points.set([point("SYS", hoursAgo: 0.5, free: 42)])
        clock.advance(by: 61)
        // The page's existing refresh method must advance the history too.
        model.refreshVolumes()
        try await waitUntil("new point") { model.historyPoints.map(\.free) == [42] }
        #expect(model.historyQueryNow == clock.now())
    }

    @Test @MainActor func historyWindowAdvancesAfterEightDays() async throws {
        let system = systemVolume
        let clock = ClockBox(now)
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { clock.now() })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        await gate.waitUntilRequested("SYS")
        await gate.succeed("SYS", [])
        try await waitUntil("history") { model.historyState.isLoaded }

        clock.advance(by: 8 * 86_400)
        model.refreshHistory(force: false)
        try await waitForRequestCount(gate, 2)
        let recorded = await gate.request(at: 1)
        let request = try #require(recorded)
        #expect(request.since == clock.now().addingTimeInterval(-7 * 86_400))
        #expect(request.until == clock.now().addingTimeInterval(1))
        #expect(model.historyQueryNow == clock.now())
        await gate.succeed(requestAt: 1, [])
    }

    @Test @MainActor func manualRefreshReplacesTheHistoryImmediately() async throws {
        let system = systemVolume
        let clock = ClockBox(now)
        let points = PointSource()
        let reader: DiskCapacitySelectionModel.HistoryReader = { id, _, _ in points.points(for: id) }
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: reader,
            clock: { clock.now() })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        try await waitUntil("empty history") { model.historyState.isLoaded }
        #expect(model.historyPoints.isEmpty)

        points.set([point("SYS", hoursAgo: 1, free: 7)])
        model.refreshAll(forceHistory: true)
        try await waitUntil("manual refresh") { model.historyPoints.map(\.free) == [7] }
        #expect(model.historyQueryNow == clock.now())
    }

    @Test @MainActor func reappearingPageForcesAHistoryRefresh() async throws {
        let system = systemVolume
        let points = PointSource()
        let reader: DiskCapacitySelectionModel.HistoryReader = { id, _, _ in points.points(for: id) }
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: reader,
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        try await waitUntil("empty history") { model.historyState.isLoaded }
        #expect(model.historyPoints.isEmpty)

        points.set([point("SYS", hoursAgo: 1, free: 8)])
        model.connect(reader: reader)
        try await waitUntil("reappeared") { model.historyPoints.map(\.free) == [8] }
    }

    @Test @MainActor func lowFrequencyHistoryRefreshDoesNotQueryMoreOftenThanTheInterval() async throws {
        let system = systemVolume
        let clock = ClockBox(now)
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { clock.now() })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        await gate.waitUntilRequested("SYS")
        await gate.succeed("SYS", [point("SYS", hoursAgo: 1, free: 1)])
        try await waitUntil("history") { model.historyState.isLoaded }

        // Repeated visible-page ticks inside the interval must not start another query.
        model.refreshAll(forceHistory: false)
        model.refreshAll(forceHistory: false)
        #expect(await gate.requestCount() == 1)

        clock.advance(by: 61)
        model.refreshAll(forceHistory: false)
        try await waitForRequestCount(gate, 2)
        #expect(await gate.requestCount() == 2)
        await gate.succeed("SYS", [])
    }

    @Test @MainActor func clearInvalidatesDisplayedPointsAndStartsANewQuery() async throws {
        let system = systemVolume
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        await gate.waitUntilRequested("SYS")
        await gate.succeed("SYS", [point("SYS", hoursAgo: 1, free: 5)])
        try await waitUntil("history") { model.historyState.isLoaded }
        #expect(model.historyPoints.map(\.free) == [5])

        model.historyDidClear()
        #expect(model.historyPoints.isEmpty)
        #expect(model.historyState == .loading(volumeID: "SYS"))

        try await waitForRequestCount(gate, 2)
        await gate.succeed(requestAt: 1, [])
        try await waitUntil("cleared") { model.historyState.isLoaded && model.historyPoints.isEmpty }
    }

    @Test @MainActor func aQueryStartedBeforeClearCannotRestoreClearedPointsWhenItArrivesLast() async throws {
        let system = systemVolume
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        await gate.waitUntilRequested("SYS")
        await gate.succeed("SYS", [point("SYS", hoursAgo: 1, free: 5)])
        try await waitUntil("history") { model.historyState.isLoaded }

        // A query that started before the clear is still in flight.
        model.refreshAll(forceHistory: true)
        try await waitForRequestCount(gate, 2)

        model.historyDidClear()
        try await waitForRequestCount(gate, 3)
        await gate.succeed(requestAt: 2, [])
        try await waitUntil("cleared") { model.historyState.isLoaded && model.historyPoints.isEmpty }

        // The pre-clear reply arrives last and must not restore its points.
        await gate.succeed(requestAt: 1, [point("SYS", hoursAgo: 1, free: 99)])
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.historyPoints.isEmpty)
        #expect(model.historyVolumeID == "SYS")
    }

    @Test @MainActor func aQueryStartedBeforeClearCannotRestoreClearedPointsWhenItArrivesFirst() async throws {
        let system = systemVolume
        let gate = HistoryGate()
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: { id, since, until in try await gate.read(id, since, until) },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        await gate.waitUntilRequested("SYS")
        await gate.succeed("SYS", [point("SYS", hoursAgo: 1, free: 5)])
        try await waitUntil("history") { model.historyState.isLoaded }

        model.refreshAll(forceHistory: true)
        try await waitForRequestCount(gate, 2)
        model.historyDidClear()
        try await waitForRequestCount(gate, 3)

        // The pre-clear reply arrives first; the post-clear query is still loading.
        await gate.succeed(requestAt: 1, [point("SYS", hoursAgo: 1, free: 99)])
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.historyPoints.isEmpty)
        #expect(model.historyState == .loading(volumeID: "SYS"))

        await gate.succeed(requestAt: 2, [])
        try await waitUntil("cleared") { model.historyState.isLoaded && model.historyPoints.isEmpty }
    }

    @Test @MainActor func backgroundClearIsPickedUpByTheLowFrequencyRefresh() async throws {
        let system = systemVolume
        let clock = ClockBox(now)
        let points = PointSource()
        points.set([point("SYS", hoursAgo: 1, free: 5)])
        let reader: DiskCapacitySelectionModel.HistoryReader = { id, _, _ in points.points(for: id) }
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: reader,
            clock: { clock.now() })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }
        try await waitUntil("history") { model.historyState.isLoaded }
        #expect(model.historyPoints.map(\.free) == [5])

        // Another process clears the store; no in-process event is posted.
        points.set([])
        clock.advance(by: 61)
        model.refreshAll(forceHistory: false)
        try await waitUntil("background clear") { model.historyState.isLoaded && model.historyPoints.isEmpty }
        #expect(model.historyQueryNow == clock.now())
    }

    @Test @MainActor func blockedSamplerDoesNotStartMoreThanOneSampleAndCanResume() async throws {
        let system = systemVolume
        let local = volume(role: .local, name: "Backup", mountPoint: "/Volumes/Backup", id: "BACKUP")
        let source = BlockingSampleSource([system, local])
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { try source.sample() },
            readHistory: { _, _, _ in [] },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("first sample") { source.startedCount() == 1 }
        model.refreshVolumes()
        model.refreshVolumes()
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.startedCount() == 1)

        source.release()
        try await waitUntil("first sample finished") { source.completedCount() == 1 }
        try await Task.sleep(for: .milliseconds(30))
        try await waitUntil("first load") { model.volumesState == .loaded }
        #expect(model.selectedVolumeID == "SYS")

        model.refreshVolumes()
        try await waitUntil("second sample") { source.startedCount() == 2 }
        source.release()
        try await waitUntil("second sample finished") { source.completedCount() == 2 }
        try await Task.sleep(for: .milliseconds(30))
        model.select(DiskCapacitySelectionModel.selectionKey(for: local))
        #expect(model.selectionState == .available(local))
    }

    // MARK: - APFS sharing

    @Test @MainActor func apfsSharedCapacityIsFlaggedAndIndependentVolumesAreNot() async throws {
        let system = systemVolume
        let data = dataVolume
        let local = volume(role: .local, name: "Backup", mountPoint: "/Volumes/Backup", id: "BACKUP")
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system, data, local] },
            readHistory: { _, _, _ in [] },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }

        #expect(model.isSharedCapacity)
        #expect(model.selectedVolume?.capacitySharing == .sharedContainer("apfs:disk3"))

        model.select(DiskCapacitySelectionModel.selectionKey(for: data))
        #expect(model.isSharedCapacity)

        model.select(DiskCapacitySelectionModel.selectionKey(for: local))
        #expect(model.isSharedCapacity == false)
        #expect(model.selectedVolume?.capacitySharing == .independent)
    }

    @Test @MainActor func pickerTitlesDistinguishSystemAndDataVolumesWithTheSameName() async throws {
        let system = volume(role: .system, name: "Macintosh HD", mountPoint: "/", id: "SYS",
                            sharing: .sharedContainer("apfs:disk3"))
        let data = volume(role: .data, name: "Macintosh HD", mountPoint: "/System/Volumes/Data", id: "DATA",
                          sharing: .sharedContainer("apfs:disk3"))
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system, data] },
            readHistory: { _, _, _ in [] },
            clock: { self.now })

        model.refreshVolumes()
        try await waitUntil("volumes") { model.volumesState == .loaded }

        let english = Locale(identifier: "en_US_POSIX")
        let systemOption = try #require(model.volumes.first { $0.volume.role == .system })
        let dataOption = try #require(model.volumes.first { $0.volume.role == .data })
        #expect(systemOption.pickerTitle(in: Bundle.module, locale: english) == "Macintosh HD — System disk")
        #expect(dataOption.pickerTitle(in: Bundle.module, locale: english) == "Macintosh HD — Data disk")
        #expect(systemOption.pickerTitle(in: Bundle.module, locale: english)
                != dataOption.pickerTitle(in: Bundle.module, locale: english))
    }

    // MARK: - Dedicated catalog

    @Test func catalogCoversEveryTextInEveryLanguage() throws {
        let document = try catalogDocument()
        #expect(document["sourceLanguage"] as? String == "en")
        let strings = try #require(document["strings"] as? [String: Any])

        let expectedKeys = Set(DiskVolumeSelectionText.allCases.map(\.rawValue))
        #expect(Set(strings.keys) == expectedKeys)
        let languages = ["es", "ja", "ko", "zh-Hans", "zh-Hant"]
        for key in expectedKeys {
            let entry = try #require(strings[key] as? [String: Any], "\(key) is missing")
            let localizations = try #require(entry["localizations"] as? [String: Any],
                                             "\(key) has no localizations")
            #expect(Set(localizations.keys) == Set(languages),
                    "\(key) has \(localizations.keys.sorted())")
            for language in languages {
                let unit = try #require((localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any],
                                        "\(key) [\(language)] has no string unit")
                #expect(unit["state"] as? String == "translated")
                let value = try #require(unit["value"] as? String)
                #expect(!value.isEmpty)
            }
        }
    }

    @Test func formatTranslationsKeepTheirPlaceholders() throws {
        let document = try catalogDocument()
        let strings = try #require(document["strings"] as? [String: Any])
        for (key, entry) in strings {
            let sourceCount = key.components(separatedBy: "%@").count - 1
            guard sourceCount > 0 else { continue }
            let localizations = try #require((entry as? [String: Any])?["localizations"] as? [String: Any])
            for (language, value) in localizations {
                let unit = try #require((value as? [String: Any])?["stringUnit"] as? [String: Any])
                let translated = try #require(unit["value"] as? String)
                #expect(translated.components(separatedBy: "%@").count - 1 == sourceCount,
                        "\(language) changed the placeholders in \(key)")
            }
        }
    }

    @Test func catalogSpotChecksUseTheRightLanguage() throws {
        func localized(_ text: DiskVolumeSelectionText, _ language: String) throws -> String {
            let bundle = try #require(Bundle(url: try resourcesURL()
                .appendingPathComponent("Localizations/\(language).lproj")))
            return text.localized(in: bundle)
        }
        #expect(try localized(.systemDisk, "ja") == "システムディスク")
        #expect(try localized(.dataDisk, "zh-Hant") == "資料磁碟")
        #expect(try localized(.localDisk, "es") == "Disco local")
        #expect(try localized(.historyLoading, "ko") == "용량 기록을 불러오는 중…")
        #expect(try localized(.apfsShared, "zh-Hans") == "此磁盘与其他 APFS 宗卷共用可用空间")
    }

    @Test func compiledTablesResolveEveryTextForEveryLanguage() throws {
        let resources = try resourcesURL()
        let languages = ["es", "ja", "ko", "zh-Hans", "zh-Hant"]
        let keys = Set(DiskVolumeSelectionText.allCases.map(\.rawValue))
        for language in languages {
            let lproj = resources.appendingPathComponent("Localizations/\(language).lproj")
            let bundle = try #require(Bundle(url: lproj), "\(language) bundle is missing")
            let table = try #require(NSDictionary(contentsOf: lproj.appendingPathComponent("DiskVolumeSelection.strings")) as? [String: String],
                                     "\(language) table is missing")
            #expect(Set(table.keys) == keys, "\(language) table keys differ")
            for text in DiskVolumeSelectionText.allCases {
                #expect(table[text.rawValue] != nil, "\(language) is missing \(text.rawValue)")
                #expect(text.localized(in: bundle) == table[text.rawValue],
                        "\(language) lookup differs for \(text.rawValue)")
            }
        }
    }

    @Test func clearHistoryMessageCoversEveryRecordedDisk() {
        let english = DiskVolumeSelectionText.clearHistoryMessage.rawValue
        #expect(english.contains("every recorded disk"))
        #expect(english.lowercased().contains("startup volume") == false)
    }

    // MARK: - Helpers

    private func catalogDocument() throws -> [String: Any] {
        let data = try Data(contentsOf: try resourcesURL().appendingPathComponent("DiskVolumeSelection.xcstrings"))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func resourcesURL() throws -> URL {
        let bundle = Bundle.module
        return try #require(bundle.resourceURL?.appendingPathComponent("Resources"),
                            "test resources are missing")
    }
}

// MARK: - Test doubles

private struct SampleFailure: LocalizedError {
    var errorDescription: String? { "sample failed" }
}

private struct GateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct WaitTimeout: Error, CustomStringConvertible {
    let description: String
}

private final class ThreadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    func set(_ value: Bool) { lock.withLock { stored = value } }
    var value: Bool? { lock.withLock { stored } }
}

/// A clock the test can move forward without waiting.
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    func now() -> Date { lock.withLock { date } }
    func advance(by interval: TimeInterval) { lock.withLock { date = date.addingTimeInterval(interval) } }
}

/// History points the test can replace between queries, like a store that another process
/// writes to or clears.
private final class PointSource: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [VolumeCapacityPoint] = []

    func set(_ points: [VolumeCapacityPoint]) { lock.withLock { stored = points } }

    func points(for volume: String) -> [VolumeCapacityPoint] {
        lock.withLock { stored.filter { $0.volume == volume } }
    }
}

/// A sampler that blocks until the test releases it, so a stuck Disk Arbitration call can be
/// simulated without touching a real disk.
private final class BlockingSampleSource: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let volumes: [DiskVolume]
    private var started = 0
    private var completed = 0

    init(_ volumes: [DiskVolume]) { self.volumes = volumes }

    func sample() throws -> [DiskVolume] {
        lock.withLock { started += 1 }
        semaphore.wait()
        lock.withLock { completed += 1 }
        return volumes
    }

    func release() { semaphore.signal() }
    func startedCount() -> Int { lock.withLock { started } }
    func completedCount() -> Int { lock.withLock { completed } }
}

/// A sampler whose result the test can change between refreshes.
private final class SampleSource: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[DiskVolume], any Error>
    private var onMainThread: Bool?

    init(_ result: Result<[DiskVolume], any Error>) {
        self.result = result
    }

    func set(_ result: Result<[DiskVolume], any Error>) {
        lock.withLock { self.result = result }
    }

    func sample() throws -> [DiskVolume] {
        let result = lock.withLock {
            onMainThread = Thread.isMainThread
            return self.result
        }
        return try result.get()
    }

    func recordedOnMainThread() -> Bool? { lock.withLock { onMainThread } }
}

/// A history reader that holds each reply until the test releases it, so the test controls the
/// order in which replies arrive.
private actor HistoryGate {
    struct Request: Sendable, Equatable {
        let index: Int
        let id: String
        let since: Date
        let until: Date
    }

    private var pending: [Int: CheckedContinuation<[VolumeCapacityPoint], any Error>] = [:]
    private var requested: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var recorded: [Request] = []

    func read(_ id: String, _ since: Date, _ until: Date) async throws -> [VolumeCapacityPoint] {
        try await withCheckedThrowingContinuation { continuation in
            // Register the continuation before the request becomes visible, so a test that
            // observes the request can release it immediately without a race.
            let index = recorded.count
            recorded.append(Request(index: index, id: id, since: since, until: until))
            pending[index] = continuation
            requested.insert(id)
            let waiting = waiters.removeValue(forKey: id) ?? []
            for waiter in waiting { waiter.resume() }
        }
    }

    func waitUntilRequested(_ id: String) async {
        if requested.contains(id) { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    /// Releases the newest pending request for `id`. Existing tests use one request per volume;
    /// tests with repeated requests use `succeed(requestAt:)` instead.
    func succeed(_ id: String, _ points: [VolumeCapacityPoint]) {
        guard let index = recorded.last(where: { $0.id == id && pending[$0.index] != nil })?.index else { return }
        pending.removeValue(forKey: index)?.resume(returning: points)
    }

    func fail(_ id: String, _ message: String) {
        guard let index = recorded.last(where: { $0.id == id && pending[$0.index] != nil })?.index else { return }
        pending.removeValue(forKey: index)?.resume(throwing: GateError(message: message))
    }

    func succeed(requestAt index: Int, _ points: [VolumeCapacityPoint]) {
        pending.removeValue(forKey: index)?.resume(returning: points)
    }

    func fail(requestAt index: Int, _ message: String) {
        pending.removeValue(forKey: index)?.resume(throwing: GateError(message: message))
    }

    func requestCount() -> Int { recorded.count }
    func request(_ id: String) -> Request? { recorded.last { $0.id == id } }
    func request(at index: Int) -> Request? { recorded.indices.contains(index) ? recorded[index] : nil }
}

@MainActor
private func waitUntil(_ what: String,
                       timeout: Duration = .seconds(5),
                       _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now > deadline {
            throw WaitTimeout(description: "timed out waiting for \(what)")
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
private func waitForRequestCount(_ gate: HistoryGate, _ count: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await gate.requestCount() < count {
        if ContinuousClock.now > deadline {
            throw WaitTimeout(description: "timed out waiting for \(count) history requests")
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

private extension DiskCapacitySelectionModel.HistoryState {
    var isLoaded: Bool { if case .loaded = self { true } else { false } }
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

private extension DiskCapacitySelectionModel.SelectionState {
    var isUnmounted: Bool { if case .unmounted = self { true } else { false } }
}
