import AppKit
import Charts
import Foundation
import GRDB
@testable import Metrics
import Storage
import SwiftUI
import Testing
@testable import MonitorPanelFeature

/// Runs the menu panel's disk and network sources against the live `Sources/Storage` module.
///
/// The UI script (`Tests/UI/run-monitor-panel-integration-tests.sh`) still substitutes
/// `MetricsHistory`, `HistoryStore` and the rest of Storage because those files were being
/// changed in parallel. This suite removes that blind spot: the whole Storage module is
/// compiled from the working tree, and every write and read below goes through the same
/// types the app uses (`MetricsHistory`, `HistoryStore`, `VolumeCapacityHistory`,
/// `MonitorAgentRecorder`).
///
/// Nothing here starts the app, the helper, a background service, Disk Arbitration, a real
/// Homebrew, or reads the user's database, preferences or Trash. The databases are either
/// in-memory or inside the scratch `HOME`/`TMPDIR` the runner creates; the volume sampler
/// and the capacity sampler are closures that return fixed fake readings. The network page
/// is only rendered from a synthetic `NetworkDetailsSnapshot`; the live section's sampler
/// never runs. The store and the design system are the same stand-ins the UI script uses,
/// because the real ones own hardware samplers and user appearance preferences.
@Suite(.serialized)
@MainActor
struct LiveStorageIntegrationTests {
    private let gigabyte: Int64 = 1_000_000_000
    private let hour: TimeInterval = 3_600
    /// A whole hour, so the capacity store's hour boundary and the fake clock agree.
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

    private func capacity(free: Double, total: Double = 1_000 * 1_000_000_000) throws -> VolumeCapacity {
        try #require(VolumeCapacity(free: free, total: total))
    }

    private func scratchDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(history: MetricsHistory?) -> MonitorStore {
        let store = MonitorStore()
        store.disk = DiskReading(readBytesPerSecond: 12_000_000,
                                 writeBytesPerSecond: 3_000_000,
                                 availableBytes: 400 * gigabyte,
                                 totalBytes: 1_000 * gigabyte)
        store.network = NetworkReading(inBytesPerSecond: 8_500_000, outBytesPerSecond: 1_250_000)
        let liveNow = Date()
        store.history = LiveHistory(series: [
            .diskRead: (0..<20).map { ChartPoint(date: liveNow.addingTimeInterval(-Double($0) * 5), value: 1_000_000) },
            .diskWrite: (0..<20).map { ChartPoint(date: liveNow.addingTimeInterval(-Double($0) * 5), value: 500_000) },
            .netIn: (0..<20).map { ChartPoint(date: liveNow.addingTimeInterval(-Double($0) * 5), value: 2_000_000) },
            .netOut: (0..<20).map { ChartPoint(date: liveNow.addingTimeInterval(-Double($0) * 5), value: 300_000) },
        ])
        store.persistentHistory = history
        return store
    }

    private func makeSnapshot(at date: Date) -> NetworkDetailsSnapshot {
        let wifi = NetworkInterfaceDetails(
            name: "en0",
            displayName: "Wi-Fi",
            kind: .wifi,
            isUp: true,
            isRunning: true,
            ipv4: [IPv4InterfaceAddress(address: "192.0.2.10", prefixLength: 24, scope: .privateNetwork)],
            ipv6: [],
            linkSpeedBitsPerSecond: .available(1_000_000_000),
            mtu: .available(1500))
        return NetworkDetailsSnapshot(capturedAt: date,
                                      interfaces: .available([wifi]),
                                      systemPrimaryIPv4: .interface("en0"),
                                      systemPrimaryIPv6: .none)
    }

    // MARK: - Disk page reads the real store

    @Test func diskPageReadsPointsWrittenByTheLiveCapacityHistory() async throws {
        let history = try MetricsHistory(inMemory: ())
        let capacityHistory = VolumeCapacityHistory(history: history)
        let system = volume(role: .system, name: "Fake System", mountPoint: "/", id: "SYS",
                            sharing: .sharedContainer("apfs:disk9"))
        let data = volume(role: .data, name: "Fake Data", mountPoint: "/System/Volumes/Data", id: "DATA",
                          total: 2_000 * gigabyte, available: 500 * gigabyte)

        for (hoursAgo, free) in [(5.0, 450.0), (4.0, 430.0), (3.0, 410.0), (2.0, 390.0)] {
            let written = try capacityHistory.record(try capacity(free: free * Double(gigabyte)),
                                                     volume: "SYS",
                                                     at: now.addingTimeInterval(-hoursAgo * hour),
                                                     now: now)
            #expect(written)
        }
        let dataWritten = try capacityHistory.record(try capacity(free: 700 * Double(gigabyte),
                                                                  total: 2_000 * Double(gigabyte)),
                                                     volume: "DATA",
                                                     at: now.addingTimeInterval(-3 * hour),
                                                     now: now)
        #expect(dataWritten)

        // The production reader is built from the same `MetricsHistory` the app stores on the
        // monitor store; the model below queries it with the seven-day window the page uses.
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system, data] },
            readHistory: DiskCapacitySelectionModel.historyReader(for: history),
            clock: { self.now })

        model.refreshVolumes()
        #expect(await eventually { model.volumesState == .loaded })
        #expect(await eventually { isHistoryLoaded(model) })
        #expect(model.selectedKey == DiskCapacitySelectionModel.selectionKey(for: system))
        #expect(model.historyVolumeID == "SYS")
        #expect(model.historyPoints.map(\.volume) == ["SYS", "SYS", "SYS", "SYS"])
        #expect(model.historyPoints.map(\.free) == [
            450 * Double(gigabyte), 430 * Double(gigabyte),
            410 * Double(gigabyte), 390 * Double(gigabyte),
        ])

        // The production page body builds against the live Storage types. It is not hosted, so
        // its `.task` does not run; the render variant below only drops that lifecycle block.
        let store = makeStore(history: history)
        _ = DiskTab(store: store, selection: model).body
        let image = try render(DiskTabRender(store: store, selection: model))
        #expect(image.pixelsWide == 420)
        #expect(image.pixelsHigh > 0)
        #expect(redPixelCount(image) > 0, "the seven-day chart drew the points read from SQLite")
    }

    @Test func aSecondWriteInTheSameHourKeepsTheFirstPoint() throws {
        let history = try MetricsHistory(inMemory: ())
        let capacityHistory = VolumeCapacityHistory(history: history)

        let first = try capacityHistory.record(try capacity(free: 100),
                                               volume: "SYS",
                                               at: now.addingTimeInterval(10),
                                               now: now)
        let second = try capacityHistory.record(try capacity(free: 900),
                                                volume: "SYS",
                                                at: now.addingTimeInterval(20),
                                                now: now)
        #expect(first)
        #expect(!second, "a duplicate hour must not insert a second row")

        let points = try capacityHistory.points(volume: "SYS",
                                                since: now.addingTimeInterval(-hour),
                                                until: now.addingTimeInterval(hour))
        #expect(points.count == 1)
        #expect(points.first?.free == 100)
        #expect(points.first?.time == now)
    }

    // MARK: - Settings clear and the disk page

    @Test func settingsClearDeletesCapacityRowsAndRejectsPreClearReadings() async throws {
        let directory = try scratchDirectory("live-clear")
        let url = directory.appending(path: "history.sqlite")
        let writer = try MetricsHistory(url: url)
        let capacityHistory = VolumeCapacityHistory(history: writer)

        _ = try capacityHistory.record(try capacity(free: 400),
                                       volume: "SYS",
                                       at: now.addingTimeInterval(-2 * hour),
                                       now: now)
        _ = try capacityHistory.record(try capacity(free: 380),
                                       volume: "SYS",
                                       at: now.addingTimeInterval(-hour),
                                       now: now)

        let settings = try HistoryStore(url: url)
        #expect(try settings.retention() == .default)
        #expect(settings.diskUsage().totalBytes > 0)

        try settings.clear(.minuteSamples, now: now)
        #expect(try capacityHistory.points(volume: "SYS", since: now.addingTimeInterval(-3 * hour)).isEmpty)
        #expect(try settings.retention() == .default, "clearing history must not delete the retention setting")

        // A reading sampled at or before the clear belongs to the period the user deleted.
        let dropped = try capacityHistory.record(try capacity(free: 370),
                                                 volume: "SYS",
                                                 at: now.addingTimeInterval(-1),
                                                 now: now.addingTimeInterval(10))
        #expect(!dropped, "a reading from before the clear must not come back")

        let kept = try capacityHistory.record(try capacity(free: 360),
                                              volume: "SYS",
                                              at: now.addingTimeInterval(hour),
                                              now: now.addingTimeInterval(hour))
        #expect(kept)

        // The page's reader is the production one; after the clear it sees only the new point.
        let reader = try #require(DiskCapacitySelectionModel.historyReader(for: writer))
        let points = try await reader("SYS",
                                      now.addingTimeInterval(-7 * 86_400),
                                      now.addingTimeInterval(2 * hour))
        #expect(points.count == 1)
        #expect(points.first?.free == 360)

        // The in-process notification is what the SSD page listens for; `historyDidClear`
        // replaces the displayed points with a fresh query instead of keeping the old ones.
        let system = volume(role: .system, name: "Fake System", mountPoint: "/", id: "SYS")
        let model = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: DiskCapacitySelectionModel.historyReader(for: writer),
            clock: { self.now.addingTimeInterval(hour) })
        model.refreshVolumes()
        #expect(await eventually { isHistoryLoaded(model) })
        model.historyDidClear()
        #expect(await eventually { isHistoryLoaded(model) })
        #expect(model.historyPoints.count == 1)
    }

    @Test func historyDefaultsStayInsideTheScratchHome() throws {
        let scratchHome = try #require(ProcessInfo.processInfo.environment["MACHELPER_LIVE_SCRATCH_HOME"])
        #expect(MetricsHistory.defaultURL.path.hasPrefix(scratchHome))
        #expect(MonitorAgentProfileStore.defaultURL().path.hasPrefix(scratchHome))
        #expect(MonitorAgentHeartbeatStore.defaultURL().path.hasPrefix(scratchHome))
    }

    @Test func settingsModelLoadsAndClearsTheLiveHistoryStore() throws {
        let url = MetricsHistory.defaultURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try MetricsHistory(url: url)
        let capacityHistory = VolumeCapacityHistory(history: writer)
        _ = try capacityHistory.record(try capacity(free: 420),
                                       volume: "SYS",
                                       at: now.addingTimeInterval(-hour),
                                       now: now)

        let model = HistoryManagementModel()
        model.load()
        #expect(model.usage != nil)
        #expect(model.retention == .default)
        #expect(model.processCollectionEnabled == false)
        #expect(model.seriesCollectionEnabled == false)

        model.setRetention(.thirtyDays)
        #expect(model.retention == .thirtyDays)
        let settings = try HistoryStore(url: url)
        #expect(try settings.retention() == .thirtyDays)

        model.clear()
        #expect(try capacityHistory.points(volume: "SYS", since: now.addingTimeInterval(-2 * hour)).isEmpty)
        #expect(try settings.retention() == .thirtyDays, "the settings section keeps its own settings")
    }

    // MARK: - Monitor history schema

    @Test func monitorMinuteHistoryRoundTripsThroughTheLiveSchema() throws {
        let history = try MetricsHistory(inMemory: ())
        let minute = FinishedMinute(time: now, totals: [
            "cpu": ColumnTotals(sum: 50, count: 2),
            "memory": ColumnTotals(sum: 30, count: 1),
            "networkIn": ColumnTotals(sum: 4_000, count: 4),
        ])
        try history.recordMinute(minute, now: now.addingTimeInterval(60))

        let count = try history.count()
        #expect(count == 1)
        let samples = try history.samples(since: now.addingTimeInterval(-60), bucket: 60)
        #expect(samples.count == 1)
        #expect(samples.first?.cpu == 25)
        #expect(samples.first?.memory == 30)
        #expect(samples.first?.networkIn == 1_000)
        #expect(samples.first?.gpu == nil)
    }

    @Test func seriesHistoryKeepsGapsForTheSensorCharts() throws {
        let directory = try scratchDirectory("live-series")
        let url = directory.appending(path: "history.sqlite")
        let history = try MetricsHistory(url: url)
        let settings = try HistoryStore(url: url)
        try settings.setSeriesCollectionEnabled(true)

        let series = "temperature.Fake Sensor"
        for (offset, value) in [(0.0, 40.0), (60.0, 42.0), (600.0, 50.0)] {
            try history.recordSeriesMinute(
                FinishedSeriesMinute(time: now.addingTimeInterval(offset),
                                     totals: [series: ColumnTotals(sum: value, count: 1)]),
                now: now.addingTimeInterval(900))
        }

        let available = try history.availableSeries()
        #expect(available.map(\.series) == [series])
        let samples = try history.seriesSamples(series,
                                                since: now.addingTimeInterval(-60),
                                                until: now.addingTimeInterval(900))
        #expect(samples.map(\.value) == [40, 42, 50])

        let buckets = try history.seriesBuckets([series],
                                                since: now.addingTimeInterval(-60),
                                                until: now.addingTimeInterval(900),
                                                bucket: 300)
        let points = try #require(buckets[series])
        #expect(points.count == 2, "a ten-minute gap must split the chart into two runs")
        #expect(points.first?.storedMinuteCount == 2)
        #expect(points.first?.value == 41)
        #expect(points.last?.value == 50)
    }

    // MARK: - Background recorder writes what the page reads

    @Test func backgroundRecorderWritesCapacityThatTheDiskPageReads() async throws {
        let directory = try scratchDirectory("live-agent")
        let profileURL = directory.appending(path: "monitor-agent.json")
        let heartbeatURL = directory.appending(path: "monitor-agent-status.json")
        try MonitorAgentProfileStore.save(
            MonitorAgentProfile(backgroundRecordingEnabled: true,
                                modules: [],
                                capacityGeneration: "live-test-1"),
            to: profileURL)

        let history = try MetricsHistory(inMemory: ())
        let reading = VolumeCapacityReading(volume: "SYS", capacity: try capacity(free: 350))
        var recorder = MonitorAgentRecorder(
            profileURL: profileURL,
            heartbeatURL: heartbeatURL,
            history: history,
            sampler: { _ in [:] },
            volumeCapacity: VolumeCapacityCollection(sample: { [reading] }))

        let capacityHistory = VolumeCapacityHistory(history: history)
        func storedPoints() throws -> [VolumeCapacityPoint] {
            try capacityHistory.points(volume: "SYS", since: now.addingTimeInterval(-hour))
        }

        var completed = false
        for _ in 0..<400 {
            recorder.tick(now: now)
            if try storedPoints().count == 1 {
                completed = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(completed, "the background recorder did not store the hourly capacity point")

        // The same bytes the recorder wrote are what the page's production reader returns.
        let reader = try #require(DiskCapacitySelectionModel.historyReader(for: history))
        let points = try await reader("SYS", now.addingTimeInterval(-hour), now.addingTimeInterval(hour))
        #expect(points.count == 1)
        #expect(points.first?.free == 350)

        let beat = try #require(MonitorAgentHeartbeatStore.load(from: heartbeatURL))
        #expect(beat.lastCapacitySampleAt != nil)

        // Disabling background recording drops the capacity recorder; enabling a new
        // generation starts the next hour with a fresh pass.
        try MonitorAgentProfileStore.save(
            MonitorAgentProfile(backgroundRecordingEnabled: false,
                                modules: [],
                                capacityGeneration: "live-test-1"),
            to: profileURL)
        recorder.tick(now: now.addingTimeInterval(5))
        #expect(try storedPoints().count == 1)

        try MonitorAgentProfileStore.save(
            MonitorAgentProfile(backgroundRecordingEnabled: true,
                                modules: [],
                                capacityGeneration: "live-test-2"),
            to: profileURL)
        var secondHour = false
        for _ in 0..<400 {
            recorder.tick(now: now.addingTimeInterval(hour))
            if try storedPoints().count == 2 {
                secondHour = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(secondHour, "a new enabled generation must record the next hour")
    }

    // MARK: - Network page

    @Test func networkDetailsContentRendersASyntheticSnapshotWithLiveMetrics() throws {
        let image = try render(NetworkDetailsContent(snapshot: makeSnapshot(at: Date())))
        #expect(image.pixelsWide == 420)
        #expect(image.pixelsHigh > 0)
        #expect(nonWhitePixelCount(image) > 0)
        #expect(greenPixelCount(image) > 0, "the synthetic Wi-Fi interface and primary pill were drawn")
    }

    // MARK: - Helpers

    private func isHistoryLoaded(_ model: DiskCapacitySelectionModel) -> Bool {
        if case .loaded = model.historyState { return true }
        return false
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool,
                            timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    @MainActor
    private func render(_ view: some View, width: CGFloat = 420) throws -> NSBitmapImageRep {
        let content = ZStack {
            Color.white
            view
        }
        .frame(width: width)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.nsImage, "ImageRenderer produced no image")
        let tiff = try #require(image.tiffRepresentation, "ImageRenderer produced no TIFF data")
        return try #require(NSBitmapImageRep(data: tiff), "ImageRenderer produced no bitmap")
    }

    private func pixelCount(_ rep: NSBitmapImageRep,
                            where predicate: (NSColor) -> Bool) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if predicate(color) { count += 1 }
            }
        }
        return count
    }

    private func redPixelCount(_ rep: NSBitmapImageRep) -> Int {
        pixelCount(rep) { color in
            color.alphaComponent > 0.5
                && color.redComponent > 0.6
                && color.greenComponent < 0.35
                && color.blueComponent < 0.35
        }
    }

    private func greenPixelCount(_ rep: NSBitmapImageRep) -> Int {
        pixelCount(rep) { color in
            color.alphaComponent > 0.5
                && color.greenComponent > 0.45
                && color.redComponent < 0.4
                && color.blueComponent < 0.4
        }
    }

    private func nonWhitePixelCount(_ rep: NSBitmapImageRep) -> Int {
        pixelCount(rep) { color in
            !(color.redComponent > 0.97 && color.greenComponent > 0.97 && color.blueComponent > 0.97)
        }
    }
}
