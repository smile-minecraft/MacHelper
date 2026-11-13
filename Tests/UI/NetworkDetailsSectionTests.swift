import Dispatch
import Foundation
import Metrics
import Testing
@testable import NetworkDetailsFeature

/// Exercises the section's state machine, not the native menu UI. Every snapshot is synthetic and
/// every system read goes through `ControlledProvider`; nothing calls `getifaddrs`, `sysctl`,
/// SystemConfiguration, the network, the app or the helper. The SwiftUI `onAppear`/`onDisappear`
/// wiring and the real `NetworkDetails` resources are not exercised here.
@Suite(.serialized)
@MainActor
struct NetworkDetailsSectionTests {
    private let startDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Synthetic snapshots

    private func makeInterface(name: String = "en0",
                               displayName: String? = "Wi-Fi",
                               kind: NetworkInterfaceKind = .wifi,
                               isUp: Bool = true,
                               isRunning: Bool = true,
                               ipv4: [IPv4InterfaceAddress] = [],
                               ipv6: [IPv6InterfaceAddress] = [],
                               linkSpeed: NetworkDetailAvailability<UInt64> = .unavailable(.notReportedBySystem),
                               mtu: NetworkDetailAvailability<Int> = .unavailable(.notReportedBySystem)) -> NetworkInterfaceDetails {
        NetworkInterfaceDetails(name: name,
                                displayName: displayName,
                                kind: kind,
                                isUp: isUp,
                                isRunning: isRunning,
                                ipv4: ipv4,
                                ipv6: ipv6,
                                linkSpeedBitsPerSecond: linkSpeed,
                                mtu: mtu)
    }

    private func snapshot(_ interfaces: NetworkDetailAvailability<[NetworkInterfaceDetails]>,
                          at date: Date,
                          primaryIPv4: PrimaryInterfaceState = .none,
                          primaryIPv6: PrimaryInterfaceState = .none) -> NetworkDetailsSnapshot {
        NetworkDetailsSnapshot(capturedAt: date,
                               interfaces: interfaces,
                               systemPrimaryIPv4: primaryIPv4,
                               systemPrimaryIPv6: primaryIPv6)
    }

    private func wifiSnapshot(address: String, at date: Date) -> NetworkDetailsSnapshot {
        snapshot(.available([
            makeInterface(ipv4: [IPv4InterfaceAddress(address: address,
                                                      prefixLength: 24,
                                                      scope: .privateNetwork)],
                          linkSpeed: .available(1_000_000_000),
                          mtu: .available(1500)),
        ]),
        at: date,
        primaryIPv4: .interface("en0"))
    }

    private func makeModel(provider: ControlledProvider,
                           clock: MutableClock,
                           scheduler: ControllableRefreshScheduler,
                           interval: Duration = .seconds(30)) -> NetworkDetailsSectionModel {
        let sampler = NetworkDetailsSampler(provider: provider, now: { clock.now })
        return NetworkDetailsSectionModel(sampler: sampler, interval: interval) { interval in
            try await scheduler.waitForNextRefresh(interval: interval)
        }
    }

    // MARK: - Loading

    @Test func firstReadShowsLoadingInsteadOfAnEmptyOrOfflineSnapshot() async throws {
        let clock = MutableClock(startDate)
        let expected = wifiSnapshot(address: "192.0.2.10", at: startDate)
        let provider = ControlledProvider(snapshots: [expected])
        provider.block(reads: [1])
        let model = makeModel(provider: provider, clock: clock, scheduler: ControllableRefreshScheduler())

        model.setVisible(true)
        #expect(await eventually { provider.hasEntered(1) })
        // The first read is still in flight. The section must not invent an empty interface list,
        // a "down" status or zero link speed from the absence of a snapshot.
        #expect(model.state == .loading)

        provider.release(1)
        #expect(await eventually { isLoaded(model) })
        guard case .loaded(let delivered) = model.state else {
            Issue.record("expected the first snapshot to be delivered")
            return
        }
        #expect(delivered == expected)
        #expect(delivered.interface(named: "en0")?.ipv4.first?.address == "192.0.2.10")
        model.setVisible(false)
    }

    // MARK: - Background delivery

    @Test func snapshotIsReadOffMainAndPassedToTheContent() async throws {
        let clock = MutableClock(startDate)
        let expected = wifiSnapshot(address: "192.0.2.10", at: startDate)
        let provider = ControlledProvider(snapshots: [expected])
        let model = makeModel(provider: provider, clock: clock, scheduler: ControllableRefreshScheduler())

        model.setVisible(true)
        #expect(await eventually { provider.readCount == 1 })
        #expect(await eventually { isLoaded(model) })
        #expect(provider.allReadsOffMainThread)
        #expect(model.state == .loaded(expected))
        model.setVisible(false)
    }

    // MARK: - Schedule and cache

    @Test func updatesOnTheConfiguredIntervalAndReusesTheSamplerCacheBetweenTicks() async throws {
        let clock = MutableClock(startDate)
        let first = wifiSnapshot(address: "192.0.2.10", at: startDate)
        let second = wifiSnapshot(address: "192.0.2.20", at: startDate.addingTimeInterval(30))
        let provider = ControlledProvider(snapshots: [first, second])
        let scheduler = ControllableRefreshScheduler()
        let model = makeModel(provider: provider, clock: clock, scheduler: scheduler)

        model.setVisible(true)
        #expect(await eventually { provider.readCount == 1 })
        #expect(await eventually { scheduler.requestCount == 1 })
        #expect(scheduler.lastInterval == .seconds(30))

        // One second later the sampler's 15-second cache still holds the first snapshot. A tick
        // must not turn into another expensive system read.
        clock.advance(by: 1)
        scheduler.tick()
        #expect(await eventually { scheduler.requestCount == 2 })
        #expect(provider.readCount == 1)

        // The next loop is due 30 seconds after the first read; the cache has expired by then.
        clock.advance(by: 29)
        scheduler.tick()
        #expect(await eventually { provider.readCount == 2 })
        #expect(await eventually {
            guard case .loaded(let delivered) = model.state else { return false }
            return delivered.interface(named: "en0")?.ipv4.first?.address == "192.0.2.20"
        })
        #expect(provider.dates == [startDate, startDate.addingTimeInterval(30)])
        model.setVisible(false)
    }

    // MARK: - Visibility, cancellation and duplicates

    @Test func hidingStopsTheLoopAndShowingAgainKeepsExactlyOne() async throws {
        let clock = MutableClock(startDate)
        let first = wifiSnapshot(address: "192.0.2.10", at: startDate)
        let second = wifiSnapshot(address: "192.0.2.20", at: startDate.addingTimeInterval(30))
        let provider = ControlledProvider(snapshots: [first, second])
        let scheduler = ControllableRefreshScheduler()
        let model = makeModel(provider: provider, clock: clock, scheduler: scheduler)

        model.setVisible(true)
        #expect(await eventually { scheduler.requestCount == 1 && provider.readCount == 1 })
        #expect(scheduler.activeWaiters == 1)

        // A repeated appear must not add a second timer.
        model.setVisible(true)
        #expect(scheduler.requestCount == 1)
        #expect(scheduler.activeWaiters == 1)

        model.setVisible(false)
        #expect(await eventually { scheduler.cancelledWaiters == 1 && scheduler.activeWaiters == 0 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(provider.readCount == 1)

        clock.advance(by: 30)
        model.setVisible(true)
        #expect(await eventually { scheduler.requestCount == 2 })
        #expect(scheduler.activeWaiters == 1)
        #expect(await eventually { provider.readCount == 2 })
        #expect(await eventually {
            guard case .loaded(let delivered) = model.state else { return false }
            return delivered.interface(named: "en0")?.ipv4.first?.address == "192.0.2.20"
        })
        model.setVisible(false)
    }

    // MARK: - Slow replies

    @Test func slowReplyFromAStoppedLoopCannotOverwriteTheNewerSnapshot() async throws {
        let clock = MutableClock(startDate)
        let old = wifiSnapshot(address: "192.0.2.10", at: startDate)
        let newer = wifiSnapshot(address: "192.0.2.20", at: startDate.addingTimeInterval(30))
        let provider = ControlledProvider(snapshots: [old, newer])
        provider.block(reads: [1, 2])
        let scheduler = ControllableRefreshScheduler()
        let model = makeModel(provider: provider, clock: clock, scheduler: scheduler)

        model.setVisible(true)
        #expect(await eventually { provider.hasEntered(1) })
        #expect(model.state == .loading)

        // Stop while the first read is blocked, then restart. The old read cannot be cancelled at
        // the system-call boundary, so it finishes later and must be discarded by generation.
        model.setVisible(false)
        clock.advance(by: 30)
        model.setVisible(true)

        provider.release(1)
        #expect(await eventually { provider.hasEntered(2) })
        try? await Task.sleep(for: .milliseconds(50))
        // The first read has completed by now, but it belongs to the stopped loop. The section is
        // still waiting for the new read and must not show the old snapshot.
        #expect(model.state == .loading)

        provider.release(2)
        #expect(await eventually {
            guard case .loaded(let delivered) = model.state else { return false }
            return delivered.interface(named: "en0")?.ipv4.first?.address == "192.0.2.20"
        })
        #expect(provider.readCount == 2)
        #expect(provider.allReadsOffMainThread)
        #expect(provider.dates == [startDate, startDate.addingTimeInterval(30)])
        model.setVisible(false)
    }

    // MARK: - Read failure

    @Test func readFailureIsPresentedAsUnavailableInsteadOfLoadingOrEmpty() async throws {
        let clock = MutableClock(startDate)
        let failure = snapshot(.unavailable(.readFailed), at: startDate)
        let provider = ControlledProvider(snapshots: [failure])
        let model = makeModel(provider: provider, clock: clock, scheduler: ControllableRefreshScheduler())

        model.setVisible(true)
        #expect(await eventually { isLoaded(model) })
        guard case .loaded(let delivered) = model.state else {
            Issue.record("expected the read-failure snapshot to be delivered")
            return
        }
        #expect(delivered.interfaces == .unavailable(.readFailed))

        // The reviewed display model keeps a failed read distinct from an empty list and from
        // "no network"; the section hands it through unchanged.
        let display = NetworkDetailsDisplay(snapshot: delivered)
        #expect(display.source == .unavailable(.readFailed))
        model.setVisible(false)
    }

    // MARK: - Helpers

    private func isLoaded(_ model: NetworkDetailsSectionModel) -> Bool {
        if case .loaded = model.state { return true }
        return false
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool,
                            timeout: Duration = .seconds(3)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }
}

// MARK: - Test doubles

/// A clock whose date only moves when the test advances it. The production sampler receives it so
/// cache expiry is controlled by the test, not by wall time.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

/// A synthetic `NetworkDetailsProviding` that can hold selected reads until the test releases
/// them. It never touches the system.
private final class ControlledProvider: NetworkDetailsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [NetworkDetailsSnapshot]
    private var nextRead = 0
    private var blockedReads: Set<Int> = []
    private var enteredReads: Set<Int> = []
    private var gates: [Int: DispatchSemaphore] = [:]
    private var readThreads: [Bool] = []
    private var readDates: [Date] = []

    init(snapshots: [NetworkDetailsSnapshot]) {
        self.snapshots = snapshots
    }

    var readCount: Int {
        lock.withLock { nextRead }
    }

    var allReadsOffMainThread: Bool {
        lock.withLock { readThreads.allSatisfy { !$0 } }
    }

    var dates: [Date] {
        lock.withLock { readDates }
    }

    func block(reads: Set<Int>) {
        lock.withLock {
            blockedReads = reads
            for read in reads {
                gates[read] = DispatchSemaphore(value: 0)
            }
        }
    }

    func hasEntered(_ read: Int) -> Bool {
        lock.withLock { enteredReads.contains(read) }
    }

    func release(_ read: Int) {
        let gate = lock.withLock { gates[read] }
        gate?.signal()
    }

    func read(at date: Date) -> NetworkDetailsSnapshot {
        let readNumber: Int
        let gate: DispatchSemaphore?
        let snapshot: NetworkDetailsSnapshot

        lock.lock()
        readNumber = nextRead + 1
        nextRead = readNumber
        if blockedReads.contains(readNumber) {
            enteredReads.insert(readNumber)
            gate = gates[readNumber]
        } else {
            gate = nil
        }
        snapshot = snapshots[min(readNumber - 1, snapshots.count - 1)]
        readThreads.append(Thread.isMainThread)
        readDates.append(date)
        lock.unlock()

        gate?.wait()
        return snapshot
    }
}

/// A refresh scheduler the test releases one tick at a time. Waiting is cancellation-aware, like
/// `Task.sleep` in production, and records whether the section's timer actually stopped.
private final class ControllableRefreshScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingTicks = 0
    private var requests = 0
    private var intervals: [Duration] = []
    private var active = 0
    private var cancelled = 0

    var requestCount: Int {
        lock.withLock { requests }
    }

    var lastInterval: Duration? {
        lock.withLock { intervals.last }
    }

    var activeWaiters: Int {
        lock.withLock { active }
    }

    var cancelledWaiters: Int {
        lock.withLock { cancelled }
    }

    func waitForNextRefresh(interval: Duration) async throws {
        lock.withLock {
            requests += 1
            intervals.append(interval)
            active += 1
        }
        defer { lock.withLock { active -= 1 } }

        while true {
            do {
                try Task.checkCancellation()
            } catch {
                lock.withLock { cancelled += 1 }
                throw error
            }

            let hasTick = lock.withLock { () -> Bool in
                guard pendingTicks > 0 else { return false }
                pendingTicks -= 1
                return true
            }
            if hasTick { return }

            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                lock.withLock { cancelled += 1 }
                throw error
            }
        }
    }

    func tick() {
        lock.withLock { pendingTicks += 1 }
    }
}
