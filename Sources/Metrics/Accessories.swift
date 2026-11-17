import Foundation
import IOKit

/// 已連線配件的一筆電量讀數。只有至少找到一個電量來源時才會產生。
public struct AccessoryBatteryReading: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let kind: Kind
    /// 0...1
    public let charge: Double
    /// 依 left、right、chargingCase 的固定順序排列。
    public let components: [Component]
    public let isCharging: Bool

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case keyboard, mouse, trackpad, headphones, other
    }

    public struct Component: Sendable, Hashable, Identifiable {
        public enum ID: String, Sendable, Codable, CaseIterable {
            case left, right, chargingCase
        }

        public let id: ID
        /// 0...1
        public let charge: Double

        public init(id: ID, charge: Double) {
            self.id = id
            self.charge = Self.clamp(charge)
        }

        private static func clamp(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(max(value, 0), 1)
        }
    }

    public init(
        id: String,
        name: String,
        kind: Kind,
        charge: Double,
        components: [Component] = [],
        isCharging: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.charge = Self.clamp(charge)
        // 不同來源回報的元件順序不一定一致，統一排序讓輸出與順序無關。
        let order = Component.ID.allCases
        self.components = components.sorted { a, b in
            let ai = order.firstIndex(of: a.id) ?? order.count
            let bi = order.firstIndex(of: b.id) ?? order.count
            return ai < bi
        }
        self.isCharging = isCharging
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// 每呼叫一次都重新讀 IORegistry；system_profiler 最多每 60 秒跑一次。
/// 共用狀態都用 NSLock 保護，呼叫端可以放心從背景執行緒呼叫。
public final class AccessoryBatterySampler: @unchecked Sendable {
    static let profilerCacheInterval: TimeInterval = 60

    private let lock = NSLock()
    private let profilerOutput: @Sendable () -> Data?
    private let now: @Sendable () -> Date
    private let hidProperties: @Sendable () -> [[String: Any]]
    private var cachedProfilerJSON: Data?
    private var cachedAt: Date?

    public init() {
        self.profilerOutput = Self.runSystemProfiler
        self.now = Date.init
        self.hidProperties = Self.readHIDProperties
    }

    /// 注入點：測試用它提供假的 profiler 輸出、時鐘與 IORegistry properties，不碰真的系統指令。
    init(
        profilerOutput: @escaping @Sendable () -> Data?,
        now: @escaping @Sendable () -> Date = Date.init,
        hidProperties: @escaping @Sendable () -> [[String: Any]] = { AccessoryBatterySampler.readHIDProperties() }
    ) {
        self.profilerOutput = profilerOutput
        self.now = now
        self.hidProperties = hidProperties
    }

    public func sample() -> [AccessoryBatteryReading] {
        // IORegistry 每次都讀；profiler 用加鎖的快取，失敗也快取空結果避免每次都跑慢指令。
        let hid = hidProperties()
        let date = now()
        let profilerJSON = lock.withLock { () -> Data? in
            if let cachedAt, date.timeIntervalSince(cachedAt) < Self.profilerCacheInterval {
                return cachedProfilerJSON
            }
            let output = profilerOutput()
            self.cachedProfilerJSON = output
            self.cachedAt = date
            return output
        }
        return Self.readings(hidProperties: hid, profilerJSON: profilerJSON)
    }

    private static func runSystemProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // 先非同步讀完 stdout，再等待結束。直接 wait 再讀，pipe 滿了會讓子行程卡住。
        let dataBox = MutableDataBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            dataBox.set(stdout.fileHandleForReading.readDataToEndOfFile())
            semaphore.signal()
        }
        process.waitUntilExit()
        semaphore.wait()
        let data = dataBox.value
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private static func readHIDProperties() -> [[String: Any]] {
        let classes = [
            "AppleDeviceManagementHIDEventService",
            "AppleHSBluetoothDevice",
            "BNBMouseDevice",
            "BNBTrackpadDevice",
        ]
        var result: [[String: Any]] = []
        for className in classes {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var raw: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      var properties = raw?.takeRetainedValue() as? [String: Any]
                else { continue }
                // 把 class 名稱放進 dictionary，讓 parseHID 能判斷 kind。
                properties["IOClass"] = className
                result.append(properties)
            }
        }
        return result
    }
}

// MARK: - 解析

extension AccessoryBatterySampler {
    /// 兩條來源合併：同 id 以 IORegistry 的名稱、電量與充電狀態為準，
    /// 但保留 profiler 提供的元件；最後依電量由低到高、名稱排序。
    static func readings(hidProperties: [[String: Any]], profilerJSON: Data?) -> [AccessoryBatteryReading] {
        let hid = parseHID(hidProperties)
        let profiler = profilerJSON.flatMap(parseProfiler) ?? []

        var merged: [String: AccessoryBatteryReading] = [:]
        var order: [String] = []

        // HID 先進場基準；同 id 的 profiler 只補元件，不覆蓋 IORegistry 的名稱、電量與充電狀態。
        for reading in hid where merged[reading.id] == nil {
            merged[reading.id] = reading
            order.append(reading.id)
        }
        for reading in profiler {
            if let existing = merged[reading.id] {
                merged[reading.id] = AccessoryBatteryReading(
                    id: existing.id,
                    name: existing.name,
                    kind: existing.kind,
                    charge: existing.charge,
                    components: mergeComponents(existing.components, reading.components),
                    isCharging: existing.isCharging
                )
            } else {
                merged[reading.id] = reading
                order.append(reading.id)
            }
        }

        return order.compactMap { merged[$0] }.sorted {
            if $0.charge != $1.charge { return $0.charge < $1.charge }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }
    }

    /// 同一 id 時，先出現的元件優先；兩邊都有的元件保留先出現的電量。
    private static func mergeComponents(
        _ lhs: [AccessoryBatteryReading.Component],
        _ rhs: [AccessoryBatteryReading.Component]
    ) -> [AccessoryBatteryReading.Component] {
        var byID: [AccessoryBatteryReading.Component.ID: AccessoryBatteryReading.Component] = [:]
        for component in lhs + rhs where byID[component.id] == nil {
            byID[component.id] = component
        }
        let order = AccessoryBatteryReading.Component.ID.allCases
        return order.compactMap { byID[$0] }
    }

    static func parseHID(_ properties: [[String: Any]]) -> [AccessoryBatteryReading] {
        var result: [AccessoryBatteryReading] = []
        var seen = Set<String>()
        for entry in properties {
            let className = string(entry["IOClass"]) ?? ""
            guard let charge = percent(entry["BatteryPercent"]) else { continue }
            let name = string(entry["Product"]) ?? string(entry["DeviceName"]) ?? string(entry["Name"]) ?? "Accessory"
            let kind = hidKind(className: className, name: name)
            let address = string(entry["DeviceAddress"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let id = address.flatMap { $0.isEmpty ? nil : $0 } ?? "\(kind.rawValue):\(name.lowercased())"
            guard seen.insert(id).inserted else { continue }
            let charging = isHIDCharging(status: entry["BatteryStatus"], flags: entry["BatteryStatusFlags"])
            result.append(AccessoryBatteryReading(
                id: id, name: name, kind: kind, charge: charge, isCharging: charging
            ))
        }
        return result
    }

    /// BatteryStatus 為 "Charging"，或 BatteryStatusFlags 的 charging bit (1 << 1 = 2) 設定時才算充電。
    /// 其他旗標的意義沒有官方文件，不猜。
    private static func isHIDCharging(status: Any?, flags: Any?) -> Bool {
        if let status = string(status), status.lowercased() == "charging" { return true }
        if let number = flags as? NSNumber, number.intValue & (1 << 1) != 0 { return true }
        return false
    }

    private static func hidKind(className: String, name: String) -> AccessoryBatteryReading.Kind {
        let text = "\(className) \(name)".lowercased()
        if text.contains("keyboard") { return .keyboard }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("mouse") { return .mouse }
        if text.contains("headphones") || text.contains("headset") || text.contains("airpods") { return .headphones }
        return .other
    }

    static func parseProfiler(_ data: Data) -> [AccessoryBatteryReading] {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let top = root as? [String: Any],
              let bluetooth = top["SPBluetoothDataType"] as? [[String: Any]],
              let first = bluetooth.first
        else { return [] }

        let devices = first["device_connected"]
        var entries: [[String: Any]] = []
        if let array = devices as? [[String: Any]] {
            for item in array {
                // 每個元素通常是「裝置名稱 -> 屬性字典」。
                if let named = item as? [String: [String: Any]] {
                    for (name, var attributes) in named {
                        if attributes["device_name"] == nil { attributes["device_name"] = name }
                        entries.append(attributes)
                    }
                } else {
                    // 元素若不是「名稱 -> 屬性」的形狀，就當作一般的屬性字典。
                    entries.append(item)
                }
            }
        } else if let dictionary = devices as? [String: Any] {
            if let nested = dictionary as? [String: [String: Any]] {
                for (name, attributes) in nested {
                    var attributes = attributes
                    if attributes["device_name"] == nil { attributes["device_name"] = name }
                    entries.append(attributes)
                }
            } else {
                entries.append(dictionary)
            }
        }
        guard !entries.isEmpty else { return [] }

        var result: [AccessoryBatteryReading] = []
        var seen = Set<String>()
        for entry in entries {
            var components: [AccessoryBatteryReading.Component] = []
            if let left = percent(entry["device_batteryLevelLeft"]) {
                components.append(AccessoryBatteryReading.Component(id: .left, charge: left))
            }
            if let right = percent(entry["device_batteryLevelRight"]) {
                components.append(AccessoryBatteryReading.Component(id: .right, charge: right))
            }
            if let caseLevel = percent(entry["device_batteryLevelCase"]) {
                components.append(AccessoryBatteryReading.Component(id: .chargingCase, charge: caseLevel))
            }

            let main = percent(entry["device_batteryLevelMain"]) ?? percent(entry["device_batteryLevel"])
            // 沒有主電量時，用已知元件的最低電量代表整機。
            guard let charge = main ?? components.map(\.charge).min() else { continue }

            let name = string(entry["device_name"]) ?? "Accessory"
            let kind = profilerKind(minorType: string(entry["device_minorType"]), name: name)
            let address = string(entry["device_address"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let id = address.flatMap { $0.isEmpty ? nil : $0 } ?? "\(kind.rawValue):\(name.lowercased())"
            guard seen.insert(id).inserted else { continue }
            result.append(AccessoryBatteryReading(
                id: id, name: name, kind: kind, charge: charge, components: components
            ))
        }
        return result
    }

    private static func profilerKind(minorType: String?, name: String) -> AccessoryBatteryReading.Kind {
        switch minorType?.lowercased() ?? "" {
        case "keyboard": return .keyboard
        case "mouse": return .mouse
        case "trackpad": return .trackpad
        case "headphones", "headset": return .headphones
        default: break
        }
        let text = name.lowercased()
        if text.contains("airpods") || text.contains("headphones") || text.contains("headset") || text.contains("buds") {
            return .headphones
        }
        return .other
    }

    /// 外部資料可能是 "82%"、"82"、82 或 82.0。只接受 0...100 的有限值。
    private static func percent(_ value: Any?) -> Double? {
        var raw: Double?
        if let number = value as? NSNumber {
            raw = number.doubleValue
        } else if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = trimmed.hasSuffix("%")
                ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                : trimmed
            raw = Double(cleaned)
        }
        guard let raw, raw.isFinite, raw >= 0, raw <= 100 else { return nil }
        return raw / 100
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        return nil
    }
}

private final class MutableDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var value: Data { lock.withLock { storage } }
    func set(_ data: Data) { lock.withLock { storage = data } }
}
