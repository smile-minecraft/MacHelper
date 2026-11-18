import AppKit
import Charts
import Foundation
import GRDB
@testable import Metrics
import Storage
import SwiftUI
import Testing
@testable import MonitorPanelFeature

/// Exercises the real menu-bar SSD and network page sources in an isolated package.
///
/// The views under test are the production files: all of `MonitorPanel.swift` is compiled, with
/// `DiskTab`/`DiskSectionHeader`/`NetworkTab` moved to a generated file as the byte-identical
/// declarations (only `private` removed) so this test can construct them. Rendering uses two
/// generated variants that differ only where the system boundary is: `DiskTabRender` drops the
/// `.task`/`.onReceive` modifiers because ImageRenderer can run them in-process, and
/// `NetworkTabRender` replaces the live `NetworkDetailsSection()` with a boundary view. The real
/// production bodies are still built and type-checked. The store, design system, helper client
/// and Storage surface are stand-ins; the test fills them with synthetic volumes, points and
/// readings and creates its own in-memory GRDB database. Nothing here starts the app, the helper,
/// the menu bar, a background recorder, Disk Arbitration, a network read or a user preference
/// lookup.
@Suite(.serialized)
@MainActor
struct MonitorPanelIntegrationTests {
    private let gigabyte: Int64 = 1_000_000_000
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

    /// A real in-memory GRDB database with the production `volume_capacity` table, filled through
    /// the fixed `VolumeCapacityHistory` snapshot. No file, app database or user data is opened.
    private func inMemoryHistory(points: [(volume: String, time: Date, free: Double, total: Double)]) throws -> MetricsHistory {
        let queue = try DatabaseQueue()
        try queue.write { db in try VolumeCapacityHistory.createTable(db) }
        let history = MetricsHistory(db: queue)
        let store = VolumeCapacityHistory(history: history)
        for point in points {
            guard let capacity = VolumeCapacity(free: point.free, total: point.total) else {
                throw FakeFailure("invalid fake capacity")
            }
            try store.record(capacity, volume: point.volume, at: point.time, now: now)
        }
        return history
    }

    /// The store stand-in only carries what the two pages read. The live series use recent
    /// timestamps because the production `Series.values` windows them against the wall clock;
    /// the values themselves are synthetic.
    private func makeStore(history: MetricsHistory?) -> MonitorStore {
        let store = MonitorStore()
        store.disk = DiskReading(readBytesPerSecond: 12_000_000,
                                 writeBytesPerSecond: 3_000_000,
                                 availableBytes: 400 * gigabyte,
                                 totalBytes: 1_000 * gigabyte)
        store.network = NetworkReading(inBytesPerSecond: 8_500_000, outBytesPerSecond: 1_250_000)

        let liveNow = Date()
        func series(_ base: Double) -> [ChartPoint] {
            (0..<20).map { index in
                ChartPoint(date: liveNow.addingTimeInterval(-Double(index) * 5),
                           value: base + Double(index) * 1_000)
            }
        }
        store.history = LiveHistory(series: [
            .diskRead: series(1_000_000),
            .diskWrite: series(500_000),
            .netIn: series(2_000_000),
            .netOut: series(300_000),
        ])
        store.persistentHistory = history
        return store
    }

    private func makeModel(volumes: [DiskVolume],
                           reader: DiskCapacitySelectionModel.HistoryReader?,
                           counter: Counter? = nil) -> DiskCapacitySelectionModel {
        DiskCapacitySelectionModel(
            sampleVolumes: {
                counter?.increment()
                return volumes
            },
            readHistory: reader,
            clock: { self.now })
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

    // MARK: - SSD page

    @Test func diskTabRendersFakeCapacityHistoryThroughTheProductionReader() async throws {
        let system = volume(role: .system,
                            name: "Fake System",
                            mountPoint: "/",
                            id: "SYS",
                            sharing: .sharedContainer("apfs:disk9"))
        let data = volume(role: .data,
                          name: "Fake Data",
                          mountPoint: "/System/Volumes/Data",
                          id: "DATA",
                          total: 2_000 * gigabyte,
                          available: 500 * gigabyte)
        let points: [(volume: String, time: Date, free: Double, total: Double)] = [
            ("SYS", now.addingTimeInterval(-5 * 3_600), 450_000_000_000, 1_000_000_000_000),
            ("SYS", now.addingTimeInterval(-4 * 3_600), 430_000_000_000, 1_000_000_000_000),
            ("SYS", now.addingTimeInterval(-3 * 3_600), 410_000_000_000, 1_000_000_000_000),
            ("SYS", now.addingTimeInterval(-2 * 3_600), 390_000_000_000, 1_000_000_000_000),
            ("DATA", now.addingTimeInterval(-3 * 3_600), 700_000_000_000, 2_000_000_000_000),
        ]
        let history = try inMemoryHistory(points: points)
        let store = makeStore(history: history)
        let counter = Counter()
        let model = makeModel(volumes: [system, data],
                              reader: DiskCapacitySelectionModel.historyReader(for: history),
                              counter: counter)

        model.refreshVolumes()
        #expect(await eventually { model.volumesState == .loaded })
        #expect(await eventually { isHistoryLoaded(model) })
        #expect(model.selectedKey == DiskCapacitySelectionModel.selectionKey(for: system))
        #expect(model.historyVolumeID == "SYS")
        #expect(model.historyPoints.count == 4)
        #expect(model.historyPoints.allSatisfy { $0.volume == "SYS" })
        #expect(model.historyPoints.map(\.free) == [
            450_000_000_000, 430_000_000_000, 410_000_000_000, 390_000_000_000,
        ])
        #expect(counter.value == 1)

        // The real production body builds against the fake store and loaded model. It is not
        // hosted, so the page's `.task` does not run; the render variant below drops only those
        // lifecycle modifiers because ImageRenderer can run them in the same process.
        _ = DiskTab(store: store, selection: model).body
        #expect(counter.value == 1, "building the real body must not run the .task sampler")
        #expect(isHistoryLoaded(model))

        let image = try render(DiskTabRender(store: store, selection: model))
        #expect(image.pixelsWide == 420)
        #expect(image.pixelsHigh > 0)
        #expect(redPixelCount(image) > 0, "the seven-day chart drew the fake capacity points")
        #expect(counter.value == 1, "rendering must not run a volume sampler")
    }

    @Test func diskTabRendersLoadingAndFailureStatesWithoutReachingTheSystem() async throws {
        let store = makeStore(history: nil)
        let counter = Counter()
        let failingModel = DiskCapacitySelectionModel(
            sampleVolumes: {
                counter.increment()
                throw FakeFailure("fake disk list failure")
            },
            readHistory: nil,
            clock: { self.now })

        failingModel.refreshVolumes()
        #expect(await eventually { failingModel.volumesState == .failed("fake disk list failure") })
        let failureImage = try render(DiskTabRender(store: store, selection: failingModel))
        #expect(failureImage.pixelsWide == 420)
        #expect(failureImage.pixelsHigh > 0)
        #expect(redPixelCount(failureImage) == 0, "a failed volume list must not draw the chart")
        #expect(counter.value == 1)

        let system = volume(role: .system, name: "Fake System", mountPoint: "/", id: "SYS")
        let historyModel = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: { _, _, _ in throw FakeFailure("fake history read failure") },
            clock: { self.now })
        historyModel.refreshVolumes()
        #expect(await eventually { historyModel.volumesState == .loaded })
        #expect(await eventually { isHistoryFailed(historyModel, message: "fake history read failure") })
        let historyImage = try render(DiskTabRender(store: store, selection: historyModel))
        #expect(historyImage.pixelsWide == 420)
        #expect(historyImage.pixelsHigh > 0)
        #expect(redPixelCount(historyImage) == 0, "a failed history read must not draw the chart")
    }

    // MARK: - Network page

    @Test func networkTabRendersFakeRatesOnlyWithTheLiveSectionBoundary() throws {
        let store = makeStore(history: nil)
        let snapshot = makeSnapshot(at: Date())

        // The real production body builds with the fake store. It constructs the real
        // `NetworkDetailsSection` (whose sampler only reads on appear) but does not host it, so
        // no interface is read. The render variant below replaces exactly that one call.
        _ = NetworkTab(store: store).body

        let image = try render(NetworkTabRender(store: store))
        #expect(image.pixelsWide == 420)
        #expect(image.pixelsHigh > 0)
        #expect(greenPixelCount(image) > 0, "the download rate and mirrored chart used the fake readings")
        #expect(bluePixelCount(image) > 0, "the upload series used the fake readings")

        let contentImage = try render(NetworkDetailsContent(snapshot: snapshot))
        #expect(contentImage.pixelsWide == 420)
        #expect(contentImage.pixelsHigh > 0)
        #expect(nonWhitePixelCount(contentImage) > 0, "the real network content drew the synthetic snapshot")
        #expect(greenPixelCount(contentImage) > 0, "the synthetic Wi-Fi interface and primary pill were drawn")
    }

    // MARK: - Settings section

    @Test func historyManagementSectionRendersWithTheStorageStandIns() throws {
        let image = try render(Form { HistoryManagementSection() })
        #expect(image.pixelsWide == 420)
        #expect(image.pixelsHigh > 0)
        #expect(nonWhitePixelCount(image) > 0)
    }

    // MARK: - Full panel value

    @Test func fullMonitorPanelValueBuildsFromTheFakeStore() {
        let store = makeStore(history: nil)
        let panel = MonitorPanel(store: store, actions: PanelActions(
            openSettings: {},
            openDiagnostics: {},
            openFanControl: {},
            openDiskAnalysis: {},
            openOptimize: {},
            openUninstall: {},
            openStartup: {},
            openHistory: {},
            openMain: {},
            quit: {}))
        #expect(panel.scrollable)
        #expect(store.watchCalls.isEmpty, "constructing the value must not run onAppear")
    }

    // MARK: - Helpers

    private func isHistoryLoaded(_ model: DiskCapacitySelectionModel) -> Bool {
        if case .loaded = model.historyState { return true }
        return false
    }

    private func isHistoryFailed(_ model: DiskCapacitySelectionModel, message: String) -> Bool {
        if case .failed(_, let actual) = model.historyState, actual == message { return true }
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

    private func bluePixelCount(_ rep: NSBitmapImageRep) -> Int {
        pixelCount(rep) { color in
            color.alphaComponent > 0.5
                && color.blueComponent > 0.55
                && color.redComponent < 0.45
                && color.greenComponent < 0.45
        }
    }

    private func nonWhitePixelCount(_ rep: NSBitmapImageRep) -> Int {
        pixelCount(rep) { color in
            !(color.redComponent > 0.97 && color.greenComponent > 0.97 && color.blueComponent > 0.97)
        }
    }
}

// MARK: - Test doubles

private struct FakeFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}
