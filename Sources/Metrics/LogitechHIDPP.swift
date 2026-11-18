import Foundation
import IOKit
import IOKit.hid

// MARK: - HID++ 2.0 協定常數

/// Logitech HID++ 2.0 的 report 格式。short report 共 7 bytes，long report 共 20 bytes；
/// 本實作只送出 short report（請求與暫存回覆都放得下）。
enum HIDppReport {
    static let shortID: UInt8 = 0x10
    static let longID: UInt8 = 0x11
    static let shortLength = 7
    /// 本次固定使用的 software ID（工作規格：1–15，固定 0x01）。
    static let softwareID: UInt8 = 0x01
}

enum HIDppFeatureID {
    static let deviceName: UInt16 = 0x0005
    static let batteryStatus: UInt16 = 0x1000
    static let unifiedBattery: UInt16 = 0x1004
}

/// Battery Status（feature 0x1000）function 0x00 回覆的 status byte。
/// 其他數值視為未知：照實回報電量，但不算充電中。
enum HIDppBatteryStatus: UInt8, Sendable {
    case discharging = 0
    case recharging = 1
    case almostFull = 2
    case full = 3
    case slowRecharge = 4
    case invalidBattery = 5
    case thermalError = 6

    var isCharging: Bool {
        switch self {
        case .recharging, .almostFull, .full, .slowRecharge: return true
        case .discharging, .invalidBattery, .thermalError: return false
        }
    }
}

/// Battery Status 解析結果。level 為 0...100 的整數；0 依規格視為未知，由呼叫端略過。
struct HIDppBatteryReading: Equatable, Sendable {
    let level: Int
    let status: HIDppBatteryStatus?
}

// MARK: - 純函式：請求 frame 與回覆解析（fixture 測試直接覆蓋）

enum HIDppReply: Equatable {
    /// 正常回覆；payload 是回覆 byte 4 之後的內容（short report 尾端的補零也保留在裡面）。
    case matched(featureIndex: UInt8, function: UInt8, payload: [UInt8])
    /// HID++ 1.0 錯誤回覆（byte 2 == 0x8f）。實機上未連線的 device index 就是這種回覆。
    case hidpp10Error(code: UInt8)
    /// HID++ 2.0 錯誤回覆（byte 2 == 0xff），例如 featureIndex 或 function 無效。
    case hidpp20Error(code: UInt8)
    /// 不是這筆請求的回覆（例如裝置主動送出的通知），忽略。
    case unrelated
}

enum LogitechHIDPP {
    /// 建立 short report 請求。params 最多 3 bytes（short report 扣掉 4 個 header byte）。
    static func requestFrame(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        swId: UInt8 = HIDppReport.softwareID,
        params: [UInt8] = []
    ) -> Data? {
        guard params.count <= HIDppReport.shortLength - 4 else { return nil }
        var frame = [HIDppReport.shortID, deviceIndex, featureIndex, (function & 0xF0) | (swId & 0x0F)]
        frame.append(contentsOf: params)
        frame += [UInt8](repeating: 0, count: HIDppReport.shortLength - frame.count)
        return Data(frame)
    }

    /// Root feature（0x0000）的 feature index 查詢：params 是 feature ID 大端 2 bytes。
    static func rootQueryFrame(
        deviceIndex: UInt8,
        feature: UInt16,
        swId: UInt8 = HIDppReport.softwareID
    ) -> Data? {
        requestFrame(
            deviceIndex: deviceIndex,
            featureIndex: 0x00,
            function: 0x00,
            swId: swId,
            params: [UInt8((feature >> 8) & 0xFF), UInt8(feature & 0xFF)]
        )
    }

    /// 解析回覆。只在 report 的 reportID 是 short/long、deviceIndex 對上、且
    /// featureIndex 與 function|swId 對上時才算 .matched；
    /// 0x8f / 0xff 標記的錯誤回覆會比對 echo 過來的 request ID，確認是給這筆請求的。
    static func parseReply(
        _ bytes: [UInt8],
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        swId: UInt8 = HIDppReport.softwareID
    ) -> HIDppReply {
        guard bytes.count >= 4,
              bytes[0] == HIDppReport.shortID || bytes[0] == HIDppReport.longID,
              bytes[1] == deviceIndex
        else { return .unrelated }
        let requestID = (function & 0xF0) | (swId & 0x0F)

        if bytes[2] == 0x8f {
            // HID++ 1.0 錯誤：short report 專屬，回覆 byte 3~4 echo 請求的 request ID，byte 5 是錯誤碼。
            guard bytes[0] == HIDppReport.shortID, bytes.count >= 6,
                  bytes[3] == featureIndex, bytes[4] == requestID
            else { return .unrelated }
            return .hidpp10Error(code: bytes[5])
        }
        if bytes[2] == 0xff {
            guard bytes.count >= 6, bytes[3] == featureIndex, bytes[4] == requestID else { return .unrelated }
            return .hidpp20Error(code: bytes[5])
        }
        guard bytes[2] == featureIndex, bytes[3] == requestID else { return .unrelated }
        return .matched(featureIndex: bytes[2], function: bytes[3] & 0xF0, payload: Array(bytes[4...]))
    }

    /// Root query 的回覆：protocol 上 bytes[2] 是 root 自己的 feature index（0x00），
    /// 真正找到的 feature index 在 payload[0]；0 代表不支援（或 2.0 錯誤由呼叫端另外處理）。
    static func supportedFeatureIndex(from reply: HIDppReply) -> UInt8? {
        guard case .matched(_, _, let payload) = reply,
              let index = payload.first,
              index != 0,
              index != 0xFF
        else { return nil }
        return index
    }

    /// Battery Status（0x1000）function 0x00 的 payload：第 0 個 byte 是放電電量（0=未知）、
    /// 第 2 個 byte 是充電狀態。level 0 與過短的 payload 都回傳 nil。
    static func batteryStatus(from payload: [UInt8]) -> HIDppBatteryReading? {
        guard payload.count >= 3 else { return nil }
        let level = Int(payload[0])
        guard level > 0, level <= 100 else { return nil }
        return HIDppBatteryReading(level: level, status: HIDppBatteryStatus(rawValue: payload[2]))
    }

    /// Unified Battery（0x1004）function 0x10 的 payload（kLogitechDeviceBatteryStatus）：
    /// [discharge, level, status]。discharge 是真實百分比，等於 0 代表裝置沒有提供百分比；
    /// level 是級距（8=full、4=good、2=low、1=critical），不能當成百分比用。
    /// status byte 與 BATTERY_STATUS 用同一個 enum（0 discharging … 6 thermal error）。
    /// 沒有真實百分比時回傳 nil，不會拿級距冒充電量。
    static func unifiedBattery(from payload: [UInt8]) -> HIDppBatteryReading? {
        guard payload.count >= 3 else { return nil }
        let level = Int(payload[0])
        guard level > 0, level <= 100 else { return nil }
        return HIDppBatteryReading(level: level, status: HIDppBatteryStatus(rawValue: payload[2]))
    }

    /// 名稱片段：有些韌體回覆的第一個 byte 是 offset echo（offset > 0 時判斷），尾部可能補 0x00。
    /// 逐 byte 收集到第一個 0x00 為止；遇到 echo byte 就跳過。
    static func nameChunkBytes(_ payload: [UInt8], offset: Int) -> [UInt8] {
        var index = 0
        if offset > 0, let first = payload.first, first == UInt8(offset) {
            index = 1
        }
        var bytes: [UInt8] = []
        while index < payload.count {
            let byte = payload[index]
            if byte == 0 { break }
            bytes.append(byte)
            index += 1
        }
        return bytes
    }

    /// 依名稱長度上限組合名稱；截到長度上限並要求合法 UTF-8。
    static func makeName(from bytes: [UInt8], maxLength: Int) -> String? {
        let trimmed = Array(bytes.prefix(maxLength))
        guard !trimmed.isEmpty else { return nil }
        return String(bytes: trimmed, encoding: .utf8)
    }

    /// DEVICE_NAME 0x0005 function 0x20 的 device kind byte。
    static func kind(fromDeviceKindByte byte: UInt8) -> AccessoryBatteryReading.Kind? {
        switch byte {
        case 0x00, 0x02: return .keyboard // keyboard、numpad
        case 0x03: return .mouse
        case 0x04: return .trackpad
        case 0x05: return .mouse // trackball
        default: return nil
        }
    }

    /// 名稱猜配件種類；只在 device kind 沒有或無法解讀時用。
    static func kindFromName(_ name: String) -> AccessoryBatteryReading.Kind? {
        let text = name.lowercased()
        if text.contains("keyboard") || text.contains("keys") { return .keyboard }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("mouse") || text.contains("mx anywhere") || text.contains("g502") || text.contains("gpro") { return .mouse }
        return nil
    }

    /// 建立配件讀數；HID++ 來源固定用 hidpp: 開頭的 id，跟其他來源不會撞。
    static func makeReading(
        deviceIndex: UInt8,
        name: String?,
        kind: AccessoryBatteryReading.Kind,
        battery: HIDppBatteryReading,
        vendorID: Int,
        productID: Int,
        locationID: Int?
    ) -> AccessoryBatteryReading {
        let resolvedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (resolvedName?.isEmpty == false ? resolvedName! : nil) ?? "Logitech Device \(deviceIndex)"
        let id: String
        if let locationID {
            id = String(format: "hidpp:%04x:%04x:%x:%d", vendorID, productID, locationID, deviceIndex)
        } else {
            id = String(format: "hidpp:%04x:%04x:%d", vendorID, productID, deviceIndex)
        }
        return AccessoryBatteryReading(
            id: id,
            name: finalName,
            kind: kind,
            charge: Double(battery.level) / 100,
            isCharging: battery.status?.isCharging ?? false
        )
    }
}

// MARK: - IOKit 查詢（背景執行；單次請求 200ms timeout；整個 session 有總時間上限）

enum HIDppQuery {
    static let requestTimeout: TimeInterval = 0.2
    static let sessionDeadline: TimeInterval = 2.5

    /// 查詢一台接收器背後 device index 1...6 的已連線裝置，回傳電量讀數。
    /// `log` 只給測試與實機探測用，正式路徑傳 nil。
    static func queryAll(log: ((String) -> Void)? = nil) -> [AccessoryBatteryReading] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // 只匹配 Logitech 的 HID++ 接收器介面：vendor 0x046D、vendor page 0xFF00、usage 0x0001。
        // 少了 vendor ID 會對其他廠商同 usage 的介面送 HID++ 報告。
        let matching: CFDictionary = [
            kIOHIDVendorIDKey as String: 0x046D,
            kIOHIDDeviceUsagePageKey as String: 0xFF00,
            kIOHIDDeviceUsageKey as String: 0x0001,
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            log?("IOHIDManagerOpen failed")
            return []
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let receivers = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            log?("no vendor page receiver enumerated")
            return []
        }
        log?("receivers found: \(receivers.count)")

        var result: [AccessoryBatteryReading] = []
        for receiver in Array(receivers) {
            result.append(contentsOf: queryReceiver(receiver, log: log))
        }
        return result
    }

    private static func queryReceiver(_ device: IOHIDDevice, log: ((String) -> Void)?) -> [AccessoryBatteryReading] {
        // 不搶占裝置，讓滑鼠鍵盤繼續正常運作。
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            log?("IOHIDDeviceOpen failed; skipping receiver")
            return []
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let runLoop = CFRunLoopGetCurrent() else {
            log?("no run loop; skipping receiver")
            return []
        }
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        defer { IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue) }

        let box = ReplyBox()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, inputReportCallback, Unmanaged.passUnretained(box).toOpaque())
        defer {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
            buffer.deallocate()
        }

        let vendorID = property(device, kIOHIDVendorIDKey) as? Int ?? 0
        let productID = property(device, kIOHIDProductIDKey) as? Int ?? 0
        let locationID = property(device, kIOHIDLocationIDKey) as? Int
        let deadline = Date().addingTimeInterval(sessionDeadline)

        var readings: [AccessoryBatteryReading] = []
        for index in 1 ... 6 {
            if Date() >= deadline {
                log?("session deadline reached; stopping at index \(index)")
                break
            }
            guard let reading = queryDevice(
                device, box: box, deviceIndex: UInt8(index),
                vendorID: vendorID, productID: productID, locationID: locationID,
                deadline: deadline, log: log
            ) else { continue }
            readings.append(reading)
        }
        return readings
    }

    private static func queryDevice(
        _ device: IOHIDDevice,
        box: ReplyBox,
        deviceIndex: UInt8,
        vendorID: Int,
        productID: Int,
        locationID: Int?,
        deadline: Date,
        log: ((String) -> Void)?
    ) -> AccessoryBatteryReading? {
        // 依序試 0x1000（BATTERY_STATUS，舊介面）與 0x1004（UNIFIED_BATTERY，
        // 只有在上面拿不到真實百分比時才用）。root 回覆 bytes[2] 永遠是 0，
        // 找到的 feature index 在 payload[0]。
        let channel = HIDppChannel(
            sendRootQuery: { feature in
                sendAndWait(
                    device, box: box, frame: LogitechHIDPP.rootQueryFrame(deviceIndex: deviceIndex, feature: feature),
                    deviceIndex: deviceIndex, featureIndex: 0x00, function: 0x00, deadline: deadline, log: log
                )
            },
            sendFeatureRequest: { featureIndex, function in
                sendAndWait(
                    device, box: box,
                    frame: LogitechHIDPP.requestFrame(deviceIndex: deviceIndex, featureIndex: featureIndex, function: function),
                    deviceIndex: deviceIndex, featureIndex: featureIndex, function: function,
                    deadline: deadline, log: log
                )
            }
        )
        guard let battery = batteryReading(channel: channel, deviceIndex: deviceIndex, log: log) else { return nil }

        // 名稱與 kind 都是展示用的加分資訊；失敗不影響電量讀數。
        let details = queryDeviceDetails(device, box: box, deviceIndex: deviceIndex, deadline: deadline, log: log)
        let kind = details.kind
            ?? details.name.flatMap(LogitechHIDPP.kindFromName)
            ?? .other
        log?("idx \(deviceIndex): \(details.name ?? "?") level \(battery.level) status \(String(describing: battery.status)) kind \(kind.rawValue)")
        return LogitechHIDPP.makeReading(
            deviceIndex: deviceIndex,
            name: details.name,
            kind: kind,
            battery: battery,
            vendorID: vendorID, productID: productID, locationID: locationID
        )
    }

    /// 先 BATTERY_STATUS 0x1000；拿不到（不支援或無百分比）時退到 UNIFIED_BATTERY 0x1004。
    /// 內部 static、不提供 IOHIDDevice 參數，讓測試可以用腳本通道驅動同一段流程。
    internal static func batteryReading(
        channel: HIDppChannel,
        deviceIndex: UInt8,
        log: ((String) -> Void)? = nil
    ) -> HIDppBatteryReading? {
        if let reading = queryBatteryStatusFeature(channel: channel, deviceIndex: deviceIndex, log: log) {
            return reading
        }
        log?("idx \(deviceIndex): falling back to unified battery 0x1004")
        return queryUnifiedBatteryFeature(channel: channel, deviceIndex: deviceIndex, log: log)
    }

    /// 訊息通道：把請求送給裝置並回傳回覆。正式版包裝 IOHIDDevice＋box，
    /// 測試版用腳本假機驅動同一段查詢流程（G502 在 2026-11-18 的實測行為）。
    internal struct HIDppChannel {
        let sendRootQuery: (UInt16) -> HIDppReply?
        let sendFeatureRequest: (UInt8, UInt8) -> HIDppReply?
    }

    private static func queryBatteryStatusFeature(
        channel: HIDppChannel,
        deviceIndex: UInt8,
        log: ((String) -> Void)?
    ) -> HIDppBatteryReading? {
        guard let batteryRoot = channel.sendRootQuery(HIDppFeatureID.batteryStatus) else {
            log?("idx \(deviceIndex): no reply to battery root query")
            return nil
        }

        switch batteryRoot {
        case .matched:
            guard let featureIndex = LogitechHIDPP.supportedFeatureIndex(from: batteryRoot) else {
                log?("idx \(deviceIndex): battery feature not supported (index 0)")
                return nil
            }
            guard let batteryReply = channel.sendFeatureRequest(featureIndex, 0x00) else {
                log?("idx \(deviceIndex): no reply to battery status request")
                return nil
            }
            switch batteryReply {
            case .matched(_, _, let payload):
                guard let battery = LogitechHIDPP.batteryStatus(from: payload) else {
                    log?("idx \(deviceIndex): battery payload unreadable or level 0 (unknown)")
                    return nil
                }
                log?("idx \(deviceIndex): battery 0x1000 level \(battery.level) status \(String(describing: battery.status))")
                return battery
            case .hidpp20Error(let code), .hidpp10Error(let code):
                log?("idx \(deviceIndex): battery status error 0x\(String(format: "%02x", code))")
                return nil
            case .unrelated:
                log?("idx \(deviceIndex): unrelated reply to battery status request")
                return nil
            }
        case .hidpp10Error(let code):
            log?("idx \(deviceIndex): 1.0 error 0x\(String(format: "%02x", code)) (no device?)")
            return nil
        case .hidpp20Error(let code):
            log?("idx \(deviceIndex): 2.0 error 0x\(String(format: "%02x", code))")
            return nil
        case .unrelated:
            log?("idx \(deviceIndex): unrelated reply to battery root query")
            return nil
        }
    }

    private static func queryUnifiedBatteryFeature(
        channel: HIDppChannel,
        deviceIndex: UInt8,
        log: ((String) -> Void)?
    ) -> HIDppBatteryReading? {
        guard let root = channel.sendRootQuery(HIDppFeatureID.unifiedBattery) else {
            log?("idx \(deviceIndex): no reply to unified battery root query")
            return nil
        }
        switch root {
        case .matched:
            guard let featureIndex = LogitechHIDPP.supportedFeatureIndex(from: root) else {
                log?("idx \(deviceIndex): unified battery not supported (index 0)")
                return nil
            }
            guard let reply = channel.sendFeatureRequest(featureIndex, 0x10) else {
                log?("idx \(deviceIndex): no reply to unified battery status request")
                return nil
            }
            switch reply {
            case .matched(_, _, let payload):
                // discharge == 0：裝置沒有提供百分比，只給級距，不把級距冒充電量百分比。
                guard let battery = LogitechHIDPP.unifiedBattery(from: payload) else {
                    log?("idx \(deviceIndex): unified battery has no percentage (discharge=0); skipping")
                    return nil
                }
                log?("idx \(deviceIndex): unified battery 0x1004 level \(battery.level) status \(String(describing: battery.status))")
                return battery
            case .hidpp20Error(let code), .hidpp10Error(let code):
                log?("idx \(deviceIndex): unified battery error 0x\(String(format: "%02x", code))")
                return nil
            case .unrelated:
                log?("idx \(deviceIndex): unrelated reply to unified battery request")
                return nil
            }
        case .hidpp10Error(let code):
            log?("idx \(deviceIndex): 1.0 error 0x\(String(format: "%02x", code)) (no device?)")
            return nil
        case .hidpp20Error(let code):
            log?("idx \(deviceIndex): 2.0 error 0x\(String(format: "%02x", code))")
            return nil
        case .unrelated:
            log?("idx \(deviceIndex): unrelated reply to unified battery root query")
            return nil
        }
    }

    /// 查詢 DEVICE_NAME（0x0005）的 feature index、名稱與 device kind。只做 root query 一次，
    /// 名稱讀不到時仍嘗試 kind；任何一步失敗都回傳 nil 欄位。
    private static func queryDeviceDetails(
        _ device: IOHIDDevice,
        box: ReplyBox,
        deviceIndex: UInt8,
        deadline: Date,
        log: ((String) -> Void)?
    ) -> (name: String?, kind: AccessoryBatteryReading.Kind?) {
        // root query：Device Name（0x0005）。回覆 feature index 0 代表不支援。
        guard let root = sendAndWait(
            device, box: box,
            frame: LogitechHIDPP.rootQueryFrame(deviceIndex: deviceIndex, feature: HIDppFeatureID.deviceName),
            deviceIndex: deviceIndex, featureIndex: 0x00, function: 0x00, deadline: deadline, log: log
        ) else { log?("idx \(deviceIndex): no reply to name root query"); return (nil, nil) }
        // 同 Battery：bytes[2] 是 root 自己，找到的 feature index 在 payload[0]。
        guard let nameFeatureIndex = LogitechHIDPP.supportedFeatureIndex(from: root) else { log?("idx \(deviceIndex): device name not supported (index 0)"); return (nil, nil) }

        let name = queryName(device, box: box, deviceIndex: deviceIndex, nameFeatureIndex: nameFeatureIndex, deadline: deadline, log: log)

        // function 0x20（getDeviceKind）是可選功能；失敗就靠名稱猜。
        var kind: AccessoryBatteryReading.Kind?
        if let kindReply = sendAndWait(
            device, box: box,
            frame: LogitechHIDPP.requestFrame(deviceIndex: deviceIndex, featureIndex: nameFeatureIndex, function: 0x20),
            deviceIndex: deviceIndex, featureIndex: nameFeatureIndex, function: 0x20, deadline: deadline, log: log
        ), case .matched(_, _, let kindPayload) = kindReply, let kindByte = kindPayload.first {
            kind = LogitechHIDPP.kind(fromDeviceKindByte: kindByte)
        }
        return (name, kind)
    }

    private static func queryName(
        _ device: IOHIDDevice,
        box: ReplyBox,
        deviceIndex: UInt8,
        nameFeatureIndex: UInt8,
        deadline: Date,
        log: ((String) -> Void)?
    ) -> String? {
        guard let lengthReply = sendAndWait(
            device, box: box,
            frame: LogitechHIDPP.requestFrame(deviceIndex: deviceIndex, featureIndex: nameFeatureIndex, function: 0x00),
            deviceIndex: deviceIndex, featureIndex: nameFeatureIndex, function: 0x00, deadline: deadline, log: log
        ) else { return nil }
        guard case .matched(_, _, let lengthPayload) = lengthReply, let nameLength = lengthPayload.first, nameLength > 0 else { return nil }

        var bytes: [UInt8] = []
        while bytes.count < Int(nameLength) {
            let offset = bytes.count
            guard let chunk = sendAndWait(
                device, box: box,
                frame: LogitechHIDPP.requestFrame(
                    deviceIndex: deviceIndex, featureIndex: nameFeatureIndex, function: 0x10,
                    params: [UInt8(offset)]
                ),
                deviceIndex: deviceIndex, featureIndex: nameFeatureIndex, function: 0x10,
                deadline: deadline, log: log
            ) else { return nil }
            guard case .matched(_, _, let chunkPayload) = chunk else { return nil }
            let piece = LogitechHIDPP.nameChunkBytes(chunkPayload, offset: offset)
            if piece.isEmpty { return nil }
            bytes.append(contentsOf: piece.prefix(Int(nameLength) - bytes.count))
        }
        return LogitechHIDPP.makeName(from: bytes, maxLength: Int(nameLength))
    }

    private static func sendAndWait(
        _ device: IOHIDDevice,
        box: ReplyBox,
        frame: Data?,
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        deadline: Date,
        log: ((String) -> Void)?
    ) -> HIDppReply? {
        guard let frame else { log?("frame build failed"); return nil }
        _ = box.drain() // 先清掉上一筆請求留下的過期回覆，再送這一筆。
        let sendResult = frame.withUnsafeBytes { raw in
            IOHIDDeviceSetReport(
                device, kIOHIDReportTypeOutput,
                CFIndex(HIDppReport.shortID), raw.baseAddress!.assumingMemoryBound(to: UInt8.self), frame.count
            )
        }
        guard sendResult == kIOReturnSuccess else {
            log?("SetReport failed: 0x\(String(format: "%08x", sendResult))")
            return nil
        }
        let timeout = min(requestTimeout, deadline.timeIntervalSinceNow)
        guard timeout > 0 else { return nil }
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
            for report in box.drain() {
                let reply = LogitechHIDPP.parseReply(report, deviceIndex: deviceIndex, featureIndex: featureIndex, function: function)
                if reply != .unrelated { return reply }
            }
        }
        return nil
    }

    private static func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [[UInt8]] = []

    func add(_ bytes: [UInt8]) {
        lock.withLock { reports.append(bytes) }
    }

    func drain() -> [[UInt8]] {
        lock.withLock {
            let all = reports
            reports.removeAll()
            return all
        }
    }
}

private let inputReportCallback: IOHIDReportCallback = { context, _, _, _, _, report, reportLength in
    guard let context, reportLength > 0 else { return }
    let box = Unmanaged<ReplyBox>.fromOpaque(context).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    box.add(bytes)
}

// MARK: - 對外入口：45 秒快取 + 背景重查，呼叫端立即回傳

public final class LogitechHIDPPSampler: @unchecked Sendable {
    public static let shared = LogitechHIDPPSampler()

    private let cache: BatterySourceCache

    public init() {
        cache = BatterySourceCache { HIDppQuery.queryAll(log: nil) }
    }

    /// 自訂時鐘與查詢實作，只有測試用。
    init(now: @escaping @Sendable () -> Date, query: @escaping @Sendable () -> [AccessoryBatteryReading]) {
        cache = BatterySourceCache(now: now, query: query)
    }

    /// 立即回傳快取；第一次與過期後會在背景重查。
    public func readings() -> [AccessoryBatteryReading] {
        cache.readings()
    }
}
