import Foundation
import Testing
@testable import Metrics

private func profilerJSON(_ body: String) -> Data { Data(body.utf8) }

@Suite struct AccessoriesTests {
    // MARK: - IORegistry 解析

    @Test func parsesSingleKeyboardWithStringAndNumberPercent() {
        let stringPercent: [String: Any] = [
            "IOClass": "AppleDeviceManagementHIDEventService",
            "Product": "Magic Keyboard",
            "DeviceAddress": "AA:BB:CC:DD:EE:FF",
            "BatteryPercent": "82",
        ]
        let numberPercent: [String: Any] = [
            "IOClass": "AppleDeviceManagementHIDEventService",
            "Product": "Magic Keyboard",
            "DeviceAddress": "AA:BB:CC:DD:EE:FF",
            "BatteryPercent": NSNumber(value: 82),
        ]
        for entry in [stringPercent, numberPercent] {
            let readings = AccessoryBatterySampler.parseHID([entry])
            #expect(readings.count == 1)
            #expect(readings.first?.id == "aa:bb:cc:dd:ee:ff")
            #expect(readings.first?.name == "Magic Keyboard")
            #expect(readings.first?.kind == .keyboard)
            #expect(readings.first?.charge == 0.82)
        }
    }

    @Test func usesStableIDWithoutDeviceAddress() {
        let entry: [String: Any] = [
            "IOClass": "BNBMouseDevice",
            "Product": "MX Master",
            "BatteryPercent": NSNumber(value: 40),
        ]
        let reading = AccessoryBatterySampler.parseHID([entry]).first
        #expect(reading?.id == "mouse:mx master")
        #expect(reading?.kind == .mouse)
    }

    @Test func deduplicatesSameIDAndClampsCharge() {
        let entries: [[String: Any]] = [
            ["IOClass": "AppleHSBluetoothDevice", "DeviceName": "First", "DeviceAddress": "  AA:BB  ", "BatteryPercent": NSNumber(value: 150)],
            ["IOClass": "AppleHSBluetoothDevice", "DeviceName": "Second", "DeviceAddress": "aa:bb", "BatteryPercent": NSNumber(value: 20)],
            ["IOClass": "AppleHSBluetoothDevice", "DeviceName": "Negative", "BatteryPercent": NSNumber(value: -5)],
        ]
        let readings = AccessoryBatterySampler.parseHID(entries)
        // 150 超出範圍被跳過；-5 也跳過；只有 aa:bb 的 20 留下。
        #expect(readings.count == 1)
        #expect(readings.first?.id == "aa:bb")
        #expect(readings.first?.name == "Second")
        #expect(readings.first?.charge == 0.20)

        // 模型本身仍會把抽象數值 clamp 到 0...1。
        let clamped = AccessoryBatteryReading(id: "x", name: "X", kind: .other, charge: 5)
        #expect(clamped.charge == 1.0)
    }

    @Test func chargingStatusAndFlag() {
        let status: [String: Any] = [
            "IOClass": "AppleDeviceManagementHIDEventService", "Product": "Board",
            "BatteryPercent": NSNumber(value: 50), "BatteryStatus": "Charging",
        ]
        let flag: [String: Any] = [
            "IOClass": "AppleDeviceManagementHIDEventService", "Product": "Board",
            "BatteryPercent": NSNumber(value: 50), "BatteryStatusFlags": NSNumber(value: 2),
        ]
        let idle: [String: Any] = [
            "IOClass": "AppleDeviceManagementHIDEventService", "Product": "Board",
            "BatteryPercent": NSNumber(value: 50), "BatteryStatusFlags": NSNumber(value: 0),
        ]
        #expect(AccessoryBatterySampler.parseHID([status]).first?.isCharging == true)
        #expect(AccessoryBatterySampler.parseHID([flag]).first?.isCharging == true)
        #expect(AccessoryBatterySampler.parseHID([idle]).first?.isCharging == false)
    }

    @Test func skipsEntriesWithoutBatteryPercent() {
        let entry: [String: Any] = [
            "IOClass": "BNBTrackpadDevice", "Product": "Trackpad", "Name": "Fallback Name",
        ]
        #expect(AccessoryBatterySampler.parseHID([entry]).isEmpty)
    }

    // MARK: - system_profiler 解析

    @Test func parsesAirPodsWithLeftRightCaseAndPercentStrings() {
        let json = profilerJSON("""
        {"SPBluetoothDataType":[{"device_connected":[
          {"AirPods Pro":{"device_address":"11:22:33:44:55:66","device_minorType":"Headphones",
            "device_batteryLevelMain":"95%","device_batteryLevelLeft":"85",
            "device_batteryLevelRight":80,"device_batteryLevelCase":"70 %"}}
        ]}]}
        """)
        let reading = AccessoryBatterySampler.parseProfiler(json).first
        #expect(reading?.id == "11:22:33:44:55:66")
        #expect(reading?.name == "AirPods Pro")
        #expect(reading?.kind == .headphones)
        #expect(reading?.charge == 0.95)
        #expect(reading?.components.map(\.id) == [.left, .right, .chargingCase])
        #expect(reading?.components.map(\.charge) == [0.85, 0.80, 0.70])
    }

    @Test func chargeFallsBackToLowestComponentWithoutMain() {
        let json = profilerJSON("""
        {"SPBluetoothDataType":[{"device_connected":[
          {"Buds":{"device_minorType":"unknown","device_batteryLevelLeft":"82%",
            "device_batteryLevelRight":60}}
        ]}]}
        """)
        let reading = AccessoryBatterySampler.parseProfiler(json).first
        #expect(reading?.kind == .headphones) // 名稱含 Buds
        #expect(reading?.charge == 0.60)
        #expect(reading?.components.count == 2)
        #expect(reading?.id == "headphones:buds")
    }

    @Test func acceptsDeviceBatteryLevelKeyAndSkipsOutOfRange() {
        let json = profilerJSON("""
        {"SPBluetoothDataType":[{"device_connected":[
          {"Bad":{"device_address":"a1","device_minorType":"Keyboard","device_batteryLevel":"101"}},
          {"Good":{"device_address":"a2","device_minorType":"Mouse","device_batteryLevel":55}}
        ]}]}
        """)
        let readings = AccessoryBatterySampler.parseProfiler(json)
        #expect(readings.count == 1)
        #expect(readings.first?.name == "Good")
        #expect(readings.first?.kind == .mouse)
        #expect(readings.first?.charge == 0.55)
    }

    @Test func toleratesMalformedJSONAndMissingConnected() {
        #expect(AccessoryBatterySampler.parseProfiler(profilerJSON("not json")).isEmpty)
        #expect(AccessoryBatterySampler.parseProfiler(profilerJSON("{}")).isEmpty)
        #expect(AccessoryBatterySampler.parseProfiler(profilerJSON("{\"SPBluetoothDataType\":[]}")).isEmpty)
        #expect(AccessoryBatterySampler.parseProfiler(
            profilerJSON("{\"SPBluetoothDataType\":[{\"device_connected\":[]}]}")
        ).isEmpty)
    }

    // MARK: - 合併與排序

    @Test func mergeKeepsHIDPriorityAndProfilerComponents() {
        let hid: [[String: Any]] = [[
            "IOClass": "AppleHSBluetoothDevice", "DeviceName": "HID Name",
            "DeviceAddress": "AA:BB", "BatteryPercent": NSNumber(value: 90),
            "BatteryStatus": "Charging",
        ]]
        let json = profilerJSON("""
        {"SPBluetoothDataType":[{"device_connected":[
          {"Profiler Name":{"device_address":"aa:bb","device_minorType":"Headphones",
            "device_batteryLevelMain":"50%","device_batteryLevelLeft":"30",
            "device_batteryLevelCase":20}}
        ]}]}
        """)
        let readings = AccessoryBatterySampler.readings(hidProperties: hid, profilerJSON: json)
        #expect(readings.count == 1)
        #expect(readings.first?.name == "HID Name")
        #expect(readings.first?.charge == 0.90)
        #expect(readings.first?.isCharging == true)
        #expect(readings.first?.components.map(\.id) == [.left, .chargingCase])
        #expect(readings.first?.components.map(\.charge) == [0.30, 0.20])
    }

    @Test func mergeSortsByChargeThenName() {
        let hid: [[String: Any]] = [
            ["IOClass": "BNBMouseDevice", "Product": "Z Mouse", "BatteryPercent": NSNumber(value: 50)],
            ["IOClass": "BNBMouseDevice", "Product": "A Mouse", "BatteryPercent": NSNumber(value: 50)],
            ["IOClass": "BNBTrackpadDevice", "Product": "Low Trackpad", "BatteryPercent": NSNumber(value: 10)],
        ]
        let readings = AccessoryBatterySampler.readings(hidProperties: hid, profilerJSON: nil)
        #expect(readings.map(\.name) == ["Low Trackpad", "A Mouse", "Z Mouse"])
    }

    @Test func emptyInputsProduceNoReadings() {
        #expect(AccessoryBatterySampler.readings(hidProperties: [], profilerJSON: nil).isEmpty)
    }

    // MARK: - 快取

    @Test func samplerCachesProfilerWithin60Seconds() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let calls = Counter()
        let sampler = AccessoryBatterySampler(
            profilerOutput: { calls.tick(); return nil },
            now: { clock.now },
            hidProperties: { [] }
        )

        _ = sampler.sample()
        _ = sampler.sample()
        #expect(calls.value == 1)
        clock.advance(AccessoryBatterySampler.profilerCacheInterval - 1)
        _ = sampler.sample()
        #expect(calls.value == 1)
        clock.advance(2)
        _ = sampler.sample()
        #expect(calls.value == 2)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func tick() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
