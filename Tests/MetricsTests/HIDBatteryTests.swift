import Foundation
import Testing
@testable import Metrics

@Suite struct HIDBatteryTests {
    // MARK: - 純函式

    @Test func chargeAcceptsOnlyZeroToHundred() {
        #expect(HIDBatteryReader.charge(fromInteger: 0) == 0.0)
        #expect(HIDBatteryReader.charge(fromInteger: 1) == 0.01)
        #expect(HIDBatteryReader.charge(fromInteger: 45) == 0.45)
        #expect(HIDBatteryReader.charge(fromInteger: 100) == 1.0)
        #expect(HIDBatteryReader.charge(fromInteger: -1) == nil)
        #expect(HIDBatteryReader.charge(fromInteger: 101) == nil)
        #expect(HIDBatteryReader.charge(fromInteger: 255) == nil)
    }

    @Test func idIncludesLocationWhenPresent() {
        #expect(HIDBatteryReader.id(vendorID: 0x046d, productID: 0xc547, locationID: 0x02113000) == "hid:046d:c547:2113000")
        #expect(HIDBatteryReader.id(vendorID: 0x046d, productID: 0xc547, locationID: nil) == "hid:046d:c547")
    }

    /// `reading(for:)` 的守門條件：vendor page 的介面不開裝置，交給 HID++ 查詢。
    @Test func vendorPageDevicesAreSkipped() {
        #expect(HIDBatteryReader.isVendorPage(0xFF00))
        #expect(HIDBatteryReader.isVendorPage(0xFF01))
        #expect(HIDBatteryReader.isVendorPage(0xFFFF))
        #expect(!HIDBatteryReader.isVendorPage(0x01))
        #expect(!HIDBatteryReader.isVendorPage(0x0C))
        #expect(!HIDBatteryReader.isVendorPage(nil))
    }

    @Test func kindUsesUsagePageThenNameFallback() {
        #expect(HIDBatteryReader.kind(usagePage: 0x01, usage: 0x06, name: "") == .keyboard)
        #expect(HIDBatteryReader.kind(usagePage: 0x01, usage: 0x02, name: "") == .mouse)
        #expect(HIDBatteryReader.kind(usagePage: 0x01, usage: 0x01, name: "Wireless Mouse") == .mouse)
        #expect(HIDBatteryReader.kind(usagePage: nil, usage: nil, name: "Soundcore Buds") == .headphones)
        #expect(HIDBatteryReader.kind(usagePage: nil, usage: nil, name: "Wireless Keyboard") == .keyboard)
        #expect(HIDBatteryReader.kind(usagePage: nil, usage: nil, name: "Trackpad") == .trackpad)
        #expect(HIDBatteryReader.kind(usagePage: nil, usage: nil, name: "Mystery Box") == .other)
    }

    // MARK: - BatterySourceCache：30–60 秒快取與背景重查

    @Test func refreshForTestingSeedsCacheSynchronously() {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let calls = Counter()
        let cache = BatterySourceCache(ttl: 45, now: { clock.now }, query: {
            calls.tick()
            return [reading(charge: 0.5)]
        })

        let seeded = cache.refreshForTesting()
        #expect(seeded.map(\.charge) == [0.5])
        // 快取內的值立即回傳，不再觸發查詢。
        #expect(cache.readings().map(\.charge) == [0.5])
        #expect(calls.value == 1)
    }

    @Test func expiredCacheReturnsStaleImmediatelyAndRefreshesInBackground() {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let scheduler = TestScheduler()
        let calls = Counter()
        let cache = BatterySourceCache(
            ttl: 45,
            now: { clock.now },
            schedule: { scheduler.enqueue($0) },
            query: {
                calls.tick()
                return [reading(charge: calls.value == 1 ? 0.25 : 0.9)]
            }
        )

        // 第一次同步查詢立即回 0.25（refreshForTesting 走同一條 query 路徑）。
        _ = cache.refreshForTesting()
        #expect(calls.value == 1)

        clock.advance(46) // 超過 TTL
        let stale = cache.readings() // 立即回舊值，並排入背景重查
        #expect(stale.map(\.charge) == [0.25])
        #expect(cache.readings().map(\.charge) == [0.25])
        #expect(calls.value == 1) // 排入後、手動執行前，query 尚未呼叫
        #expect(scheduler.pendingCount == 1) // 連續 stale 讀取只排入一次

        #expect(scheduler.runNext())
        #expect(calls.value == 2)
        #expect(cache.readings().map(\.charge) == [0.9])
    }

    @Test func backgroundRefreshFillsEmptyCacheWithoutBlocking() {
        let scheduler = TestScheduler()
        let calls = Counter()
        let cache = BatterySourceCache(ttl: 45, schedule: { scheduler.enqueue($0) }) {
            calls.tick()
            return [reading(charge: 0.75)]
        }

        // 快取空：立即回 []，只排入背景查詢，不執行 query。
        #expect(cache.readings().isEmpty)
        #expect(calls.value == 0)
        #expect(scheduler.pendingCount == 1)

        #expect(scheduler.runNext())
        #expect(calls.value == 1)
        #expect(cache.readings().map(\.charge) == [0.75])
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

private final class TestScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []

    func enqueue(_ work: @escaping @Sendable () -> Void) {
        lock.withLock { pending.append(work) }
    }

    var pendingCount: Int { lock.withLock { pending.count } }

    func runNext() -> Bool {
        let work = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        guard let work else { return false }
        work()
        return true
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func tick() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private func reading(charge: Double) -> AccessoryBatteryReading {
    AccessoryBatteryReading(id: "hid:test:test", name: "Test Device", kind: .mouse, charge: charge)
}
