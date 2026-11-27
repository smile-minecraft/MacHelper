import AppKit
import Charts
import Foundation
@testable import Metrics
@testable import MacHelper
@testable import Storage
import SwiftUI
import Testing

/// Exercises the real menu-bar SSD, network and battery pages, and the panel that hosts them,
/// inside the hosted test bundle.
///
/// The views under test are the production files. `DiskTabContent` and `PanelNetworkTabContent`
/// are the pages without their `.task`/`.onAppear` modifiers: `ImageRenderer` can run SwiftUI
/// lifecycle modifiers in the same process, and those would start live samplers. The store is a
/// test store with no hardware sources and no history database; the test fills it with synthetic
/// readings, volumes, points and creates its own in-memory GRDB database. Nothing here starts the
/// app, the helper, the menu bar, a background recorder, Disk Arbitration, IORegistry,
/// system_profiler or a network read, and the stored panel page lives in the test host's own
/// preferences domain, which is deleted at the end of the run.
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
        let history = try MetricsHistory(inMemory: ())
        let store = VolumeCapacityHistory(history: history)
        for point in points {
            guard let capacity = VolumeCapacity(free: point.free, total: point.total) else {
                throw FakeFailure("invalid fake capacity")
            }
            try store.record(capacity, volume: point.volume, at: point.time, now: now)
        }
        return history
    }

    /// The test store carries what the pages read and nothing else: no samplers, no database and
    /// no background loops. Readings go through the same `apply` path a real sample takes, so the
    /// live series fill in exactly as they do in the app; the battery page fixture has an internal
    /// battery and two accessories, one of which reports left/right/case components.
    private func makeStore(history: MetricsHistory? = nil,
                           modules: Set<MonitorModule> = [.battery, .accessories]) -> MonitorStore {
        let store = MonitorStore.makeForTests(settings: MonitorSettingsStore(), modules: modules, history: nil)
        // A handful of readings so the sparklines have points; the values are synthetic and the
        // timestamps are the current time because the production series windows them live.
        for index in 0..<20 {
            let step = Double(index)
            store.seed(.disk(DiskReading(readBytesPerSecond: 12_000_000 + step,
                                         writeBytesPerSecond: 3_000_000 + step,
                                         availableBytes: 400 * gigabyte,
                                         totalBytes: 1_000 * gigabyte)))
            store.seed(.network(NetworkReading(inBytesPerSecond: 8_500_000 + step,
                                               outBytesPerSecond: 1_250_000 + step)))
        }
        store.settings.configuration = MonitorConfiguration.default
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
        let store = makeStore()
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
        // hosted, so the page's `.task` does not run; the render below uses the page content,
        // which drops only those lifecycle modifiers.
        _ = DiskTabContent(store: store, selection: model).body
        #expect(counter.value == 1, "building the real body must not run the .task sampler")
        #expect(isHistoryLoaded(model))

        let image = try render(DiskTabContent(store: store, selection: model))
        #expect(image.pixelsWide == 420)
        #expect(image.pixelsHigh > 0)
        #expect(coloredPixelCount(image) > 0, "the seven-day chart drew the fake capacity points")
        #expect(counter.value == 1, "rendering must not run a volume sampler")
    }

    @Test func diskTabRendersLoadingAndFailureStatesWithoutReachingTheSystem() async throws {
        let store = makeStore()
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
        let failureImage = try render(DiskTabContent(store: store, selection: failingModel))
        #expect(failureImage.pixelsWide == 420)
        #expect(failureImage.pixelsHigh > 0)
        #expect(counter.value == 1)

        let system = volume(role: .system, name: "Fake System", mountPoint: "/", id: "SYS")
        let historyModel = DiskCapacitySelectionModel(
            sampleVolumes: { [system] },
            readHistory: { _, _, _ in throw FakeFailure("fake history read failure") },
            clock: { self.now })
        historyModel.refreshVolumes()
        #expect(await eventually { historyModel.volumesState == .loaded })
        #expect(await eventually { isHistoryFailed(historyModel, message: "fake history read failure") })
        let historyImage = try render(DiskTabContent(store: store, selection: historyModel))
        #expect(historyImage.pixelsWide == 420)
        #expect(historyImage.pixelsHigh > 0)
    }

    // MARK: - Network page

    @Test func networkTabRendersFakeRatesOnlyWithTheLiveSectionBoundary() throws {
        let store = makeStore()
        let snapshot = makeSnapshot(at: Date())

        // The real production body builds with the fake store. Its samplers only start in
        // `.onAppear`, which is not run here because the body is only built, not hosted. The
        // content below drops that lifecycle block so ImageRenderer stays offline.
        _ = PanelNetworkTabContent(store: store, model: NetworkPanelModel(), history: PanelHistory(),
                                   range: .constant(.live)).body

        let image = try render(PanelNetworkTabContent(store: store, model: NetworkPanelModel(),
                                                      history: PanelHistory(), range: .constant(.live)))
        #expect(image.pixelsWide == 420)
        #expect(image.pixelsHigh > 0)
        #expect(coloredPixelCount(image) > 0, "the rate cards and their sparklines used the fake readings")

        let contentImage = try render(NetworkDetailsContent(snapshot: snapshot))
        #expect(contentImage.pixelsWide == 420)
        #expect(contentImage.pixelsHigh > 0)
        #expect(nonWhitePixelCount(contentImage) > 0, "the real network content drew the synthetic snapshot")
    }

    // MARK: - Battery page

    @Test func batteryTabIsAvailableWhenTheMacHasABatteryOrAnAccessory() {
        let withBattery = makeStore()
        #expect(PanelPage.battery.isAvailable(in: withBattery.availableModules,
                                              hasAccessories: !withBattery.accessories.isEmpty))

        let empty = MonitorStore.makeForTests()
        #expect(!PanelPage.battery.isAvailable(in: empty.availableModules,
                                                hasAccessories: !empty.accessories.isEmpty))

        // The accessories module on its own does not light the page up; a connected accessory
        // with a reading is required.
        let moduleOnly = MonitorStore.makeForTests(modules: [.accessories])
        #expect(!PanelPage.battery.isAvailable(in: moduleOnly.availableModules,
                                                hasAccessories: !moduleOnly.accessories.isEmpty))

        let accessoryOnly = MonitorStore.makeForTests(modules: [.accessories])
        accessoryOnly.seed(.accessories([
            AccessoryBatteryReading(id: "keyboard-1", name: "Magic Keyboard", kind: .keyboard, charge: 0.82),
        ]))
        #expect(PanelPage.battery.isAvailable(in: accessoryOnly.availableModules,
                                               hasAccessories: !accessoryOnly.accessories.isEmpty))
    }

    @Test func batteryTabRendersTheInternalBatteryAndAccessoryRows() throws {
        let store = makeStore()
        store.seed(.battery(BatteryReading(charge: 0.64,
                                           isCharging: false,
                                           externalPower: true,
                                           watts: -5,
                                           cycleCount: 123,
                                           health: 0.91,
                                           celsius: 31)))
        store.seed(.accessories([
            AccessoryBatteryReading(id: "keyboard-1", name: "Magic Keyboard", kind: .keyboard,
                                    charge: 0.82, components: [], isCharging: false),
            AccessoryBatteryReading(id: "airpods-1", name: "AirPods Pro", kind: .headphones,
                                    charge: 0.55,
                                    components: [.init(id: .left, charge: 0.57),
                                                 .init(id: .right, charge: 0.53),
                                                 .init(id: .chargingCase, charge: 0.64)],
                                    isCharging: true),
        ]))
        let image = try render(BatteryTab(store: store))
        #expect(image.pixelsWide == 420)
        #expect(image.pixelsHigh > 0)
        #expect(nonWhitePixelCount(image) > 0, "the battery gauge and accessory rows drew synthetic readings")
    }

    // MARK: - Panel layout

    @Test func panelLayoutShowsTheDefaultOrderWhenNothingIsHiddenOrUnavailable() {
        let layout = PanelLayout(order: PanelPage.allCases, hidden: [])
        #expect(layout.visiblePages { _ in true } == PanelPage.allCases)
    }

    @Test func panelLayoutKeepsTheUserOrderAndDropsHiddenPages() {
        let customOrder = [PanelPage.network, .cpu, .disk, .memory, .gpu, .power, .battery]
        let layout = PanelLayout(order: customOrder, hidden: [.disk])
        #expect(layout.visiblePages { _ in true } == [.network, .cpu, .memory, .gpu, .power, .battery])
    }

    @Test func panelLayoutHidesTheBatteryPageUntilABatteryOrAccessoryAppears() {
        let layout = PanelLayout(order: PanelPage.allCases, hidden: [])

        let noBatteryNoAccessory = layout.visiblePages {
            $0.isAvailable(in: [], hasAccessories: false)
        }
        #expect(!noBatteryNoAccessory.contains(.battery))

        let moduleOnlyNoReading = layout.visiblePages {
            $0.isAvailable(in: [.accessories], hasAccessories: false)
        }
        #expect(!moduleOnlyNoReading.contains(.battery))

        let connectedAccessory = layout.visiblePages {
            $0.isAvailable(in: [.accessories], hasAccessories: true)
        }
        #expect(connectedAccessory.contains(.battery))

        let internalBattery = layout.visiblePages {
            $0.isAvailable(in: [.battery], hasAccessories: false)
        }
        #expect(internalBattery.contains(.battery))
    }

    @Test func panelLayoutHidesThePowerPageWithoutPowerOrFanSensors() {
        let layout = PanelLayout(order: PanelPage.allCases, hidden: [])

        let noPowerHardware = layout.visiblePages {
            $0.isAvailable(in: [.cpu], hasAccessories: false)
        }
        #expect(!noPowerHardware.contains(.power))

        let fanPresent = layout.visiblePages {
            $0.isAvailable(in: [.fan], hasAccessories: false)
        }
        #expect(fanPresent.contains(.power))

        let powerSensorPresent = layout.visiblePages {
            $0.isAvailable(in: [.power], hasAccessories: false)
        }
        #expect(powerSensorPresent.contains(.power))
    }

    @Test func panelLayoutYieldsNoPagesWhenEverythingIsHiddenOrUnavailable() {
        let allHidden = PanelLayout(order: PanelPage.allCases, hidden: Set(PanelPage.allCases))
        #expect(allHidden.visiblePages { _ in true }.isEmpty)

        let allUnavailable = PanelLayout(order: PanelPage.allCases, hidden: [])
        #expect(allUnavailable.visiblePages { _ in false }.isEmpty)
    }

    // MARK: - Settings section

    @Test func historyManagementSectionRendersWithAnEmptyDatabase() throws {
        // A throwaway database in the temporary folder, so the section renders with the real
        // storage code and the person's history is never opened.
        let directory = FileManager.default.temporaryDirectory.appending(path: "history-section-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appending(path: "history.sqlite"))
        let model = HistoryManagementModel(store: store)
        let image = try render(Form { HistoryManagementSection(model: model) })
        #expect(image.pixelsWide == 420)
        #expect(image.pixelsHigh > 0)
        #expect(nonWhitePixelCount(image) > 0)
    }

    // MARK: - Full panel value

    @Test func fullMonitorPanelValueBuildsFromTheFakeStore() {
        let store = makeStore()
        let panel = buildPanel(store)
        #expect(panel.scrollable)
        #expect(store.processWatchBalance == 0, "constructing the value must not run onAppear")
    }

    // MARK: - Panel page selection

    @Test func panelResolvesTheFirstVisiblePageWhenTheStoredPageIsHidden() {
        withStoredPage(PanelPage.battery.rawValue) {
            let store = makeStore()
            store.settings.configuration.hiddenPanelPages = [.battery]
            let panel = buildPanel(store)
            // The stored page is hidden, so both the strip and the content resolve to cpu.
            #expect(panel.tabs == [.cpu, .gpu, .memory, .disk, .network])
            #expect(panel.shownTab == .cpu)
        }
    }

    @Test func panelResolvesTheFirstVisiblePageWhenTheStoredPageIsUnavailable() {
        withStoredPage(PanelPage.power.rawValue) {
            // No power or fan hardware on this store.
            let store = makeStore()
            let panel = buildPanel(store)
            #expect(panel.tabs == [.cpu, .gpu, .memory, .disk, .network, .battery])
            #expect(panel.shownTab == .cpu)
        }
    }

    @Test func panelKeepsTheStoredPageWhileItRemainsVisible() {
        withStoredPage(PanelPage.battery.rawValue) {
            let store = makeStore()
            let panel = buildPanel(store)
            #expect(panel.tabs == [.cpu, .gpu, .memory, .disk, .network, .battery])
            #expect(panel.shownTab == .battery)
        }
    }

    @Test func panelShowsTheEmptyStateAndNoStripWhenEveryPageIsHidden() throws {
        try withStoredPage(nil) {
            let store = makeStore()
            store.settings.configuration.hiddenPanelPages = Set(PanelPage.allCases)
            let panel = buildPanel(store)
            #expect(panel.tabs.isEmpty, "the strip must not appear when no page can show")
            #expect(panel.shownTab == nil)
            let image = try render(panel.body)
            #expect(nonWhitePixelCount(image) > 0, "the empty state drew its symbol and title")
        }
    }

    /// Stores the panel page in the test host's own defaults domain, so the panel's `@AppStorage`
    /// reads it and a test run never writes the person's preferences. The domain is deleted after
    /// the case.
    private func withStoredPage(_ raw: String?, run: () throws -> Void) rethrows {
        let defaults = TestHost.defaults
        let previous = defaults.string(forKey: "panel.module")
        if let raw {
            defaults.set(raw, forKey: "panel.module")
        } else {
            defaults.removeObject(forKey: "panel.module")
        }
        defer {
            if let previous {
                defaults.set(previous, forKey: "panel.module")
            } else {
                defaults.removeObject(forKey: "panel.module")
            }
            defaults.removePersistentDomain(forName: TestHost.defaultsSuiteName)
        }
        try run()
    }

    private func buildPanel(_ store: MonitorStore) -> MonitorPanel {
        MonitorPanel(store: store, actions: PanelActions(
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

    /// Any mark the theme draws: saturated pixels rather than the white page or the neutral
    /// text and hairlines, so the check does not depend on which palette the theme uses.
    private func coloredPixelCount(_ rep: NSBitmapImageRep) -> Int {
        pixelCount(rep) { color in
            guard color.alphaComponent > 0.5 else { return false }
            let high = max(color.redComponent, color.greenComponent, color.blueComponent)
            let low = min(color.redComponent, color.greenComponent, color.blueComponent)
            return high - low > 0.25
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
