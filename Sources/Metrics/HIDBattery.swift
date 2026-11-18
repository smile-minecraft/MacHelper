import Foundation
import IOKit
import IOKit.hid

/// 30–60 秒快取加背景重查。呼叫者立即拿到快取值；第一次查詢與過期後的重查都在背景執行緒進行，
/// 不阻塞 MonitorStore 的取樣。查詢本身由 `query` 完成，失敗時保留舊快取並照常更新時間戳，
/// 避免裝置一時不回覆就每次都重查。
final class BatterySourceCache: @unchecked Sendable {
    static let defaultTTL: TimeInterval = 45

    private let lock = NSLock()
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let query: @Sendable () -> [AccessoryBatteryReading]
    private var cached: [AccessoryBatteryReading] = []
    private var cachedAt: Date?
    private var refreshing = false

    init(
        ttl: TimeInterval = BatterySourceCache.defaultTTL,
        now: @escaping @Sendable () -> Date = Date.init,
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .utility).async(execute: work)
        },
        query: @escaping @Sendable () -> [AccessoryBatteryReading]
    ) {
        self.ttl = ttl
        self.now = now
        self.schedule = schedule
        self.query = query
    }

    func readings() -> [AccessoryBatteryReading] {
        let date = now()
        let (cachedReadings, shouldRefresh) = lock.withLock {
            let stale = cachedAt.map { date.timeIntervalSince($0) >= ttl } ?? true
            guard stale && !refreshing else { return (cached, false) }
            refreshing = true
            return (cached, true)
        }

        if shouldRefresh {
            let query = query
            schedule { [weak self] in
                let fresh = query()
                guard let self else { return }
                self.lock.withLock {
                    self.cached = fresh
                    self.cachedAt = self.now()
                    self.refreshing = false
                }
            }
        }
        return cachedReadings
    }

    /// 測試用：同步執行一次查詢並更新快取，回傳查詢結果。
    func refreshForTesting() -> [AccessoryBatteryReading] {
        let fresh = query()
        lock.withLock {
            cached = fresh
            cachedAt = now()
            refreshing = false
        }
        return fresh
    }
}

/// 標準 HID Battery Strength（usage page 0x06、usage 0x20）的讀取來源。
/// 列舉所有 HID 裝置，找出 Battery Strength 元素並讀值；沒有此元素或讀值超出 0...100 的裝置直接略過。
/// 不搶占裝置（kIOHIDOptionsTypeNone），也不讀寫任何按鍵或滑鼠事件。
public final class HIDBatteryReader: @unchecked Sendable {
    public static let shared = HIDBatteryReader()

    private let cache: BatterySourceCache

    public init() {
        cache = BatterySourceCache { HIDBatteryReader.queryAll() }
    }

    /// 自訂時鐘與查詢實作，只有測試用。
    init(now: @escaping @Sendable () -> Date, query: @escaping @Sendable () -> [AccessoryBatteryReading]) {
        cache = BatterySourceCache(now: now, query: query)
    }

    /// 立即回傳快取；第一次與過期後會在背景重查。
    public func readings() -> [AccessoryBatteryReading] {
        cache.readings()
    }

    // MARK: - 純函式（測試直接驗證）

    /// Battery Strength 只接受 0...100 的有限整數；其他值視為此裝置沒有有效電量，回傳 nil。
    static func charge(fromInteger raw: Int) -> Double? {
        guard (0 ... 100).contains(raw) else { return nil }
        return Double(raw) / 100
    }

    /// usage page 0xFF00 以上是 vendor 自訂頁面（例如 Logitech 接收器的 0xFF00），
    /// 標準 Battery Strength 不會出現在這種介面上；這類裝置交給廠牌協定處理。
    static func isVendorPage(_ usagePage: Int?) -> Bool {
        guard let usagePage else { return false }
        return (0xFF00 ... 0xFFFF).contains(usagePage)
    }

    static func id(vendorID: Int, productID: Int, locationID: Int?) -> String {
        if let locationID {
            return String(format: "hid:%04x:%04x:%x", vendorID, productID, locationID)
        }
        return String(format: "hid:%04x:%04x", vendorID, productID)
    }

    /// 依 HID 裝置屬性猜配件種類：先看 Generic Desktop 的 Primary Usage（1/2/6），再用名稱猜。
    static func kind(usagePage: Int?, usage: Int?, name: String) -> AccessoryBatteryReading.Kind {
        if usagePage == 0x01, let usage {
            switch usage {
            case 0x06: return .keyboard
            case 0x02: return .mouse
            default: break
            }
        }
        let text = name.lowercased()
        if text.contains("keyboard") { return .keyboard }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("mouse") { return .mouse }
        if text.contains("headphones") || text.contains("headset") || text.contains("buds") { return .headphones }
        return .other
    }

    // MARK: - IOKit 列舉

    private static func queryAll() -> [AccessoryBatteryReading] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // nil matching：列舉所有 HID 裝置，再逐台找 Battery Strength 元素。
        // 注意：不呼叫 IOHIDManagerOpen，manager open 會開啟所有匹配裝置（含鍵盤與 Logitech vendor 介面）。
        // IOHIDManagerCopyDevices 在 SetDeviceMatching 之後不需 Open，探針已確認列舉結果與 open 版本一致。
        IOHIDManagerSetDeviceMatching(manager, nil)

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        var result: [AccessoryBatteryReading] = []
        var seen = Set<String>()
        for device in devices {
            guard let reading = reading(for: device), seen.insert(reading.id).inserted else { continue }
            result.append(reading)
        }
        return result
    }

    private static func reading(for device: IOHIDDevice) -> AccessoryBatteryReading? {
        let usagePage = property(device, kIOHIDPrimaryUsagePageKey) as? Int
        let usage = property(device, kIOHIDPrimaryUsageKey) as? Int
        // vendor 自訂頁面（例如 Logitech 接收器的 0xFF00）交給 HID++ 查詢；
        // 這裡不開裝置，避免兩個來源同時開啟同一個介面。
        guard !isVendorPage(usagePage) else { return nil }

        let batteryElementMatching: CFDictionary = [
            kIOHIDElementUsagePageKey as String: 0x06,
            kIOHIDElementUsageKey as String: 0x20,
        ] as CFDictionary
        guard let elements = IOHIDDeviceCopyMatchingElements(device, batteryElementMatching, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]
        else { return nil }
        // 接受 Input 與 Feature 元素；GetValue 失敗或讀值超出 0...100 的直接跳過。
        // 只接受可讀取的 input/feature 元素；output 與 collection 不讀。
        let readableTypes: Set<IOHIDElementType> = [
            kIOHIDElementTypeInput_Misc,
            kIOHIDElementTypeInput_Button,
            kIOHIDElementTypeInput_Axis,
            kIOHIDElementTypeInput_ScanCodes,
            kIOHIDElementTypeInput_NULL,
            kIOHIDElementTypeFeature,
        ]
        let batteryElements = elements.filter { readableTypes.contains(IOHIDElementGetType($0)) }
        guard !batteryElements.isEmpty else { return nil }

        // IOHIDDeviceGetValue 要求裝置是開啟的；用非獨占模式開啟，讀完就關，不影響裝置正常使用。
        // open 失敗直接回 nil，不嘗試讀值；成功才 defer close。
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        // 同一裝置可能有多個 Battery Strength 元素，取第一個能讀出 0...100 的值。
        // IOHIDDeviceGetValue 的 pValue 是非 optional 的指標；回傳的 IOHIDValue 由裝置持有，
        // 不是 caller-owned，所以用 takeUnretainedValue 取值，不能釋放。
        let valuePointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { valuePointer.deallocate() }
        var chargeValue: Double?
        for element in batteryElements {
            guard IOHIDDeviceGetValue(device, element, valuePointer) == kIOReturnSuccess else { continue }
            let raw = Int(IOHIDValueGetIntegerValue(valuePointer.pointee.takeUnretainedValue()))
            if let charge = charge(fromInteger: raw) {
                chargeValue = charge
                break
            }
        }
        guard let charge = chargeValue else { return nil }

        let vendorID = property(device, kIOHIDVendorIDKey) as? Int
        let productID = property(device, kIOHIDProductIDKey) as? Int
        let locationID = property(device, kIOHIDLocationIDKey) as? Int
        let name = (property(device, kIOHIDProductKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name?.isEmpty == false ? name! : "Accessory"
        let id = id(vendorID: vendorID ?? 0, productID: productID ?? 0, locationID: locationID)
        return AccessoryBatteryReading(
            id: id,
            name: resolvedName,
            kind: kind(usagePage: usagePage, usage: usage, name: resolvedName),
            charge: charge
        )
    }

    private static func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }
}
