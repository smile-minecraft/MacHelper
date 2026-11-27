import Foundation
import Testing
@testable import Metrics

@Suite struct LogitechHIDPPTests {
    // MARK: - 請求 frame

    @Test func shortFrameLayout() {
        let frame = LogitechHIDPP.requestFrame(deviceIndex: 0x02, featureIndex: 0x03, function: 0x10, params: [0x04])
        #expect(frame == Data([0x10, 0x02, 0x03, 0x11, 0x04, 0x00, 0x00]))
    }

    @Test func shortFrameDefaultsToZeroParams() {
        let frame = LogitechHIDPP.requestFrame(deviceIndex: 0x01, featureIndex: 0x07, function: 0x00)
        #expect(frame == Data([0x10, 0x01, 0x07, 0x01, 0x00, 0x00, 0x00]))
    }

    @Test func shortFrameRejectsTooManyParams() {
        #expect(LogitechHIDPP.requestFrame(deviceIndex: 0x01, featureIndex: 0x00, function: 0x00, params: [1, 2, 3, 4]) == nil)
    }

    @Test func functionByteMergesHighNibbleWithSoftwareID() {
        let frame = LogitechHIDPP.requestFrame(deviceIndex: 0x01, featureIndex: 0x03, function: 0x20, swId: 0x0F)
        #expect(frame?[3] == 0x2F)
    }

    @Test func rootQueryFrameEncodesFeatureIDBigEndian() {
        let frame = LogitechHIDPP.rootQueryFrame(deviceIndex: 0x01, feature: 0x1000)
        #expect(frame == Data([0x10, 0x01, 0x00, 0x01, 0x10, 0x00, 0x00]))
        let nameFrame = LogitechHIDPP.rootQueryFrame(deviceIndex: 0x01, feature: 0x0005)
        #expect(nameFrame == Data([0x10, 0x01, 0x00, 0x01, 0x00, 0x05, 0x00]))
    }

    // MARK: - 回覆解析

    @Test func parsesMatchedShortReply() {
        // function 0x00、swId 0x01 → echo byte 是 0x01。
        let bytes: [UInt8] = [0x10, 0x01, 0x03, 0x01, 0x11, 0x00, 0x00]
        #expect(LogitechHIDPP.parseReply(bytes, deviceIndex: 0x01, featureIndex: 0x03, function: 0x00)
                == .matched(featureIndex: 0x03, function: 0x00, payload: [0x11, 0x00, 0x00]))
    }

    @Test func parsesMatchedLongReply() {
        // long report 0x11、20 bytes：Battery Status 回覆在前 7 bytes，尾端補零。
        var bytes: [UInt8] = [0x11, 0x01, 0x07, 0x01, 0x58, 0x58, 0x03]
        bytes += [UInt8](repeating: 0, count: 13)
        let reply = LogitechHIDPP.parseReply(bytes, deviceIndex: 0x01, featureIndex: 0x07, function: 0x00)
        guard case .matched(_, _, let payload) = reply else {
            Issue.record("expected matched reply, got \(reply)")
            return
        }
        #expect(Array(payload.prefix(3)) == [0x58, 0x58, 0x03])
    }

    @Test func rootQueryFoundIndexIsReadFromPayload() {
        // 真機回覆 bytes[2] 永遠是 root 自己（0x00）；找到的 feature index 在 payload[0]。
        // 合成 bytes（function 0x00、swId 0x01），語義與 2026-11-18 的實機 capture 一致：
        // idx 1 root 查詢後功能 index 為 3，version 為 5。
        let reply = LogitechHIDPP.parseReply([0x10, 0x01, 0x00, 0x01, 0x03, 0x00, 0x05],
                                              deviceIndex: 0x01, featureIndex: 0x00, function: 0x00)
        #expect(reply == .matched(featureIndex: 0x00, function: 0x00, payload: [0x03, 0x00, 0x05]))
        #expect(LogitechHIDPP.supportedFeatureIndex(from: reply) == 3)

        // 不支援（payload[0] == 0）或者錯誤回覆：都不能拿到 index。
        let unsupported = LogitechHIDPP.parseReply([0x10, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00],
                                                    deviceIndex: 0x01, featureIndex: 0x00, function: 0x00)
        #expect(LogitechHIDPP.supportedFeatureIndex(from: unsupported) == nil)
    }

    @Test func supportedFeatureIndexRejectsEverythingExceptRealInputs() {
        #expect(LogitechHIDPP.supportedFeatureIndex(from: .unrelated) == nil)
        #expect(LogitechHIDPP.supportedFeatureIndex(from: .hidpp10Error(code: 0x08)) == nil)
        #expect(LogitechHIDPP.supportedFeatureIndex(from: .hidpp20Error(code: 0x06)) == nil)
        #expect(LogitechHIDPP.supportedFeatureIndex(from: .matched(featureIndex: 0x00, function: 0x00, payload: [])) == nil)
        #expect(LogitechHIDPP.supportedFeatureIndex(from: .matched(featureIndex: 0x00, function: 0x00, payload: [0xFF])) == nil)
        // function byte 不影響 root 查詢時取 index 的判斷：index 一律讀 payload[0]。
        #expect(LogitechHIDPP.supportedFeatureIndex(from: .matched(featureIndex: 0x00, function: 0x10, payload: [0x07, 0x00, 0x00])) == 7)
    }

    @Test func ignoresUnrelatedReports() {
        // function 0x00、swId 0x01 的 matched echo 是 0x01。
        let matched: [UInt8] = [0x10, 0x01, 0x03, 0x01, 0x11, 0x00, 0x00]
        // 裝置編號不對（別台請求的回覆）。
        #expect(LogitechHIDPP.parseReply(matched, deviceIndex: 0x02, featureIndex: 0x03, function: 0x00) == .unrelated)
        // feature index 不對。
        #expect(LogitechHIDPP.parseReply(matched, deviceIndex: 0x01, featureIndex: 0x04, function: 0x00) == .unrelated)
        // function | swId 不對（0x03 vs 預期 0x13）。
        #expect(LogitechHIDPP.parseReply(matched, deviceIndex: 0x01, featureIndex: 0x03, function: 0x10) == .unrelated)
        // report ID 不是 0x10 / 0x11。
        #expect(LogitechHIDPP.parseReply([0x12, 0x01, 0x03, 0x03, 0x11, 0x00, 0x00],
                                          deviceIndex: 0x01, featureIndex: 0x03, function: 0x00) == .unrelated)
        // 長度不足。
        #expect(LogitechHIDPP.parseReply([0x10, 0x01, 0x03], deviceIndex: 0x01, featureIndex: 0x03, function: 0x00) == .unrelated)
    }

    @Test func hidpp10ErrorEchoIsChecked() {
        // 實機 trace：未連線的 device index 回 8f 00 01 <request echo> 08 00（UNKNOWN_DEVICE）。
        let reply = LogitechHIDPP.parseReply([0x10, 0x02, 0x8f, 0x00, 0x01, 0x08, 0x00],
                                              deviceIndex: 0x02, featureIndex: 0x00, function: 0x00)
        #expect(reply == .hidpp10Error(code: 0x08))
        // echo 對不上就不是給這筆請求的。
        #expect(LogitechHIDPP.parseReply([0x10, 0x02, 0x8f, 0x00, 0x02, 0x08, 0x00],
                                          deviceIndex: 0x02, featureIndex: 0x00, function: 0x00) == .unrelated)
        // 1.0 錯誤只走 short report。
        #expect(LogitechHIDPP.parseReply([0x11, 0x02, 0x8f, 0x00, 0x01, 0x08, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                                          deviceIndex: 0x02, featureIndex: 0x00, function: 0x00) == .unrelated)
    }

    @Test func hidpp20ErrorEchoIsChecked() {
        // 2.0 錯誤：0xff featureIndex requestID|swId code 00。function 0x00、swId 1 → requestID 0x01。
        let reply = LogitechHIDPP.parseReply([0x10, 0x01, 0xff, 0x03, 0x01, 0x06, 0x00],
                                              deviceIndex: 0x01, featureIndex: 0x03, function: 0x00)
        #expect(reply == .hidpp20Error(code: 0x06))
        #expect(LogitechHIDPP.parseReply([0x10, 0x01, 0xff, 0x03, 0x02, 0x06, 0x00],
                                          deviceIndex: 0x01, featureIndex: 0x03, function: 0x00) == .unrelated)
        #expect(LogitechHIDPP.parseReply([0x10, 0x01, 0xff, 0x04, 0x01, 0x06, 0x00],
                                          deviceIndex: 0x01, featureIndex: 0x03, function: 0x00) == .unrelated)
    }

    // MARK: - Unified Battery（feature 0x1004）

    @Test func unifiedBatteryUsesDischargeByteOnly() {
        // discharge=88、level=8（FULL 級距）、status=1（recharging）
        #expect(LogitechHIDPP.unifiedBattery(from: [0x58, 0x08, 0x01]) == HIDppBatteryReading(level: 88, status: .recharging))
        // discharge=0：裝置沒有提供百分比；級距不能冒充電量百分比。
        #expect(LogitechHIDPP.unifiedBattery(from: [0x00, 0x08, 0x01]) == nil)
        #expect(LogitechHIDPP.unifiedBattery(from: [0x00, 0x04, 0x01]) == nil)
        // 超出 0...100
        #expect(LogitechHIDPP.unifiedBattery(from: [0xFF, 0x08, 0x01]) == nil)
        // 過短
        #expect(LogitechHIDPP.unifiedBattery(from: [0x58, 0x08]) == nil)
        #expect(LogitechHIDPP.unifiedBattery(from: []) == nil)
        // status byte 與 0x1000 用同一個 enum
        #expect(LogitechHIDPP.unifiedBattery(from: [0x64, 0x08, 0x03])?.status == .full)
        #expect(LogitechHIDPP.unifiedBattery(from: [0x64, 0x08, 0x05])?.status == .invalidBattery)
        #expect(LogitechHIDPP.unifiedBattery(from: [0x64, 0x08, 0x99])?.status == nil)
        #expect(LogitechHIDPP.unifiedBattery(from: [0x64, 0x08, 0x01])?.status?.isCharging == true)
    }

    // MARK: - 生產查詢流程（腳本通道驅動 production batteryReading）

    /// G502 X LIGHTSPEED 在 2026-11-18 實測的行為：0x1000 不支援（payload[0]==0），0x1004 回真實百分比。
    @Test func productionFlowFallsBackToUnifiedBatteryWhen1000Unsupported() {
        var logLines: [String] = []
        let channel = scriptedChannel(
            root: { feature in
                switch feature {
                case 0x1000: return .matched(featureIndex: 0x00, function: 0x00, payload: [0x00, 0x00, 0x00]) // 不支援
                case 0x1004: return .matched(featureIndex: 0x00, function: 0x00, payload: [0x07, 0x00, 0x02]) // supported @ index 7
                default: return .hidpp10Error(code: 0x08)
                }
            },
            featureRequest: { index, function in
                if index == 0x07, function == 0x10 {
                    return .matched(featureIndex: 0x07, function: 0x10, payload: [0x58, 0x08, 0x01, 0x00]) // 88% recharging
                }
                return .hidpp10Error(code: 0x08)
            }
        )
        let reading = HIDppQuery.batteryReading(channel: channel, deviceIndex: 1) { logLines.append($0) }
        #expect(reading == HIDppBatteryReading(level: 88, status: .recharging))
        // 0x1000 路徑應該試過並被記錄，fallback 也要記錄。
        #expect(logLines.contains { $0.contains("falling back to unified battery 0x1004") })
    }

    /// 舊型設備：0x1000 回真實百分比，不會跳去 0x1004。
    @Test func productionFlowPrefers1000WhenItYieldsLevel() {
        var logLines: [String] = []
        let channel = scriptedChannel(
            root: { feature in
                switch feature {
                case 0x1000: return .matched(featureIndex: 0x00, function: 0x00, payload: [0x03, 0x00, 0x02]) // index 3
                case 0x1004: Issue.record("0x1004 must not be queried when 0x1000 answers"); return nil
                default: return .hidpp10Error(code: 0x08)
                }
            },
            featureRequest: { index, function in
                if index == 0x03, function == 0x00 {
                    return .matched(featureIndex: 0x03, function: 0x00, payload: [0x50, 0x50, 0x00, 0x00]) // 80% discharging
                }
                return .hidpp10Error(code: 0x08)
            }
        )
        let reading = HIDppQuery.batteryReading(channel: channel, deviceIndex: 2) { logLines.append($0) }
        #expect(reading == HIDppBatteryReading(level: 80, status: .discharging))
    }

    /// 退到 0x1004 後，裝置沒有提供百分比（discharge==0）→ 整體回 nil，級距不冒充百分比。
    @Test func productionFlowUnifiedBatteryWithoutPercentageYieldsNoReading() {
        let channel = scriptedChannel(
            root: { feature in
                switch feature {
                case 0x1000: return .matched(featureIndex: 0x00, function: 0x00, payload: [0x00, 0x00, 0x00])
                case 0x1004: return .matched(featureIndex: 0x00, function: 0x00, payload: [0x07, 0x00, 0x02])
                default: return .hidpp10Error(code: 0x08)
                }
            },
            featureRequest: { index, function in
                if index == 0x07, function == 0x10 {
                    return .matched(featureIndex: 0x07, function: 0x10, payload: [0x00, 0x08, 0x01, 0x00]) // discharge=0
                }
                return .hidpp10Error(code: 0x08)
            }
        )
        #expect(HIDppQuery.batteryReading(channel: channel, deviceIndex: 1) == nil)
    }

    /// 退到 0x1004 後，0x1000 有 level 但 level==0（未知），也要退到 0x1004。
    @Test func productionFlowFallsBackWhen1000LevelIsZero() {
        let channel = scriptedChannel(
            root: { feature in
                switch feature {
                case 0x1000: return .matched(featureIndex: 0x00, function: 0x00, payload: [0x03, 0x00, 0x02])
                case 0x1004: return .matched(featureIndex: 0x00, function: 0x00, payload: [0x07, 0x00, 0x02])
                default: return .hidpp10Error(code: 0x08)
                }
            },
            featureRequest: { index, function in
                switch (index, function) {
                case (0x03, 0x00): return .matched(featureIndex: 0x03, function: 0x00, payload: [0x00, 0x00, 0x00, 0x00]) // level 0
                case (0x07, 0x10): return .matched(featureIndex: 0x07, function: 0x10, payload: [0x32, 0x02, 0x00, 0x00]) // 50% discharging
                default: return .hidpp10Error(code: 0x08)
                }
            }
        )
        #expect(HIDppQuery.batteryReading(channel: channel, deviceIndex: 1) == HIDppBatteryReading(level: 50, status: .discharging))
    }

    /// root 查詢逾時（nil）→ 該 index 沒有讀數，測試環境不崩潰。
    @Test func productionFlowTimeoutYieldsNoReading() {
        let channel = scriptedChannel(
            root: { _ in nil },
            featureRequest: { _, _ in Issue.record("must not send feature request after nil root"); return nil }
        )
        #expect(HIDppQuery.batteryReading(channel: channel, deviceIndex: 1) == nil)
    }

    private func scriptedChannel(
        root: @escaping (UInt16) -> HIDppReply?,
        featureRequest: @escaping (UInt8, UInt8) -> HIDppReply?
    ) -> HIDppQuery.HIDppChannel {
        HIDppQuery.HIDppChannel(sendRootQuery: root, sendFeatureRequest: featureRequest)
    }

    // MARK: - Battery Status（feature 0x1000）

    @Test func batteryFixtureRecharging() {
        // dischargeLevel 88、nextLevel 88、status 1（recharging）。
        let reply = LogitechHIDPP.parseReply([0x10, 0x01, 0x07, 0x01, 0x58, 0x58, 0x01],
                                              deviceIndex: 0x01, featureIndex: 0x07, function: 0x00)
        guard case .matched(_, _, let payload) = reply else {
            Issue.record("expected matched reply")
            return
        }
        #expect(LogitechHIDPP.batteryStatus(from: payload) == HIDppBatteryReading(level: 88, status: .recharging))
    }

    @Test func batteryStatusLevelValidation() {
        #expect(LogitechHIDPP.batteryStatus(from: [100, 90, 3]) == HIDppBatteryReading(level: 100, status: .full))
        #expect(LogitechHIDPP.batteryStatus(from: [1, 0, 0])?.level == 1)
        // level 0 依規格視為未知。
        #expect(LogitechHIDPP.batteryStatus(from: [0, 0, 3]) == nil)
        // 超出 0...100。
        #expect(LogitechHIDPP.batteryStatus(from: [101, 90, 3]) == nil)
        // 過短。
        #expect(LogitechHIDPP.batteryStatus(from: [88]) == nil)
        #expect(LogitechHIDPP.batteryStatus(from: [88, 88]) == nil)
    }

    @Test func batteryStatusChargingFlags() {
        let charging: [HIDppBatteryStatus] = [.recharging, .almostFull, .full, .slowRecharge]
        let notCharging: [HIDppBatteryStatus] = [.discharging, .invalidBattery, .thermalError]
        for status in charging { #expect(status.isCharging) }
        for status in notCharging { #expect(!status.isCharging) }
        #expect(HIDppBatteryStatus(rawValue: 7) == nil)
    }

    @Test func batteryStatusFullRangeOfKnownStates() {
        let expected: [UInt8: HIDppBatteryStatus] = [0: .discharging, 1: .recharging, 2: .almostFull, 3: .full, 4: .slowRecharge, 5: .invalidBattery, 6: .thermalError]
        for (byte, status) in expected {
            #expect(HIDppBatteryStatus(rawValue: byte) == status)
            #expect(LogitechHIDPP.batteryStatus(from: [80, 80, byte])?.status == status)
        }
    }

    // MARK: - Device Name（feature 0x0005）

    @Test func nameChunkBytesStopsAtZero() {
        #expect(LogitechHIDPP.nameChunkBytes([0x47, 0x35, 0x30, 0x32, 0x00, 0x00, 0x00], offset: 0) == [0x47, 0x35, 0x30, 0x32]) // "G502"
        #expect(LogitechHIDPP.nameChunkBytes([], offset: 8) == [])
    }

    @Test func nameChunkBytesSkipsEchoWhenItMatchesOffset() {
        // offset 4、echo byte 0x04：跳過第一個 byte。
        #expect(LogitechHIDPP.nameChunkBytes([0x04] + Array("X LI".utf8) + [0x00, 0x00], offset: 4) == Array("X LI".utf8))
        // 第一個 byte 不是 offset：不當成 echo。
        #expect(LogitechHIDPP.nameChunkBytes([0x58, 0x20, 0x4c, 0x49, 0x00, 0x00, 0x00], offset: 4) == Array("X LI".utf8))
    }

    @Test func makeNameDecodesUTF8AndRespectsLimit() {
        #expect(LogitechHIDPP.makeName(from: Array("G502 X LIGHTSPEED".utf8), maxLength: 64) == "G502 X LIGHTSPEED")
        #expect(LogitechHIDPP.makeName(from: Array("abcdef".utf8), maxLength: 3) == "abc")
        #expect(LogitechHIDPP.makeName(from: [], maxLength: 64) == nil)
        #expect(LogitechHIDPP.makeName(from: [0xFF, 0xFE], maxLength: 10) == nil)
    }

    // MARK: - device kind 與配件種類

    @Test func kindFromDeviceKindByte() {
        #expect(LogitechHIDPP.kind(fromDeviceKindByte: 0x00) == .keyboard)
        #expect(LogitechHIDPP.kind(fromDeviceKindByte: 0x02) == .keyboard)
        #expect(LogitechHIDPP.kind(fromDeviceKindByte: 0x03) == .mouse)
        #expect(LogitechHIDPP.kind(fromDeviceKindByte: 0x04) == .trackpad)
        #expect(LogitechHIDPP.kind(fromDeviceKindByte: 0x05) == .mouse)
        #expect(LogitechHIDPP.kind(fromDeviceKindByte: 0x07) == nil)
    }

    @Test func kindFromNamePatterns() {
        #expect(LogitechHIDPP.kindFromName("G502 X LIGHTSPEED") == .mouse)
        #expect(LogitechHIDPP.kindFromName("MX Keys S") == .keyboard)
        #expect(LogitechHIDPP.kindFromName("MX Trackpad") == .trackpad)
        #expect(LogitechHIDPP.kindFromName("Something Random") == nil)
    }

    // MARK: - 讀數組合

    @Test func makeReadingBuildsStableIDAndFallsBackToIndex() {
        let reading = LogitechHIDPP.makeReading(
            deviceIndex: 1,
            name: "G502 X LIGHTSPEED",
            kind: .mouse,
            battery: HIDppBatteryReading(level: 88, status: .recharging),
            vendorID: 0x046d, productID: 0xc547, locationID: 0x02113000
        )
        #expect(reading.id == "hidpp:046d:c547:2113000:1")
        #expect(reading.name == "G502 X LIGHTSPEED")
        #expect(reading.kind == .mouse)
        #expect(reading.charge == 0.88)
        #expect(reading.isCharging)

        let anonymous = LogitechHIDPP.makeReading(
            deviceIndex: 3,
            name: nil,
            kind: .other,
            battery: HIDppBatteryReading(level: 50, status: .discharging),
            vendorID: 0x046d, productID: 0xc547, locationID: nil
        )
        #expect(anonymous.name == "Logitech Device 3")
        #expect(anonymous.id == "hidpp:046d:c547:3")
        #expect(!anonymous.isCharging)
    }

    @Test func makeReadingTrimsWhitespaceName() {
        let reading = LogitechHIDPP.makeReading(
            deviceIndex: 2,
            name: "   ",
            kind: .mouse,
            battery: HIDppBatteryReading(level: 10, status: nil),
            vendorID: 0x046d, productID: 0xc547, locationID: nil
        )
        #expect(reading.name == "Logitech Device 2")
        #expect(reading.isCharging == false)
    }

    /// 實機路徑：只在 MACHELPER_LIVE_HIDPP=1 時執行。在 c547 接收器上查詢所有
    /// device index，把日誌寫到 MACHELPER_LIVE_HIDPP_LOG 指定的檔案。
    /// 沒有裝置或不支援時「回空」是正確結果，不是失敗。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACHELPER_LIVE_HIDPP"] == "1"))
    func liveQueryOnReceiver() throws {
        let env = ProcessInfo.processInfo.environment
        let started = Date()
        var lines: [String] = []
        let readings = HIDppQuery.queryAll { lines.append($0) }
        let elapsed = Date().timeIntervalSince(started)
        let summary = [
            "elapsed=\(elapsed)s",
            "readings=\(readings.map { "\($0.id) name=\($0.name) charge=\($0.charge) isCharging=\($0.isCharging)" })",
        ] + lines
        let logPath = env["MACHELPER_LIVE_HIDPP_LOG"] ?? NSTemporaryDirectory() + "machelper-live-hidpp.log"
        try summary.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        // 總逾時有界：單一接收器 session 上限 2.5 秒，加 buffer。
        #expect(elapsed < 5)
    }

    /// 實機驗證快取與背景查詢：第一次 readings() 必須立刻回傳（不阻塞取樣），
    /// 之後背景查詢把結果補進快取。裝置休眠時補不到是正常結果，只記錄不判定失敗。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACHELPER_LIVE_HIDPP"] == "1"))
    func liveSamplerFillsCacheInBackground() throws {
        let env = ProcessInfo.processInfo.environment
        let sampler = LogitechHIDPPSampler.shared
        let started = Date()
        _ = sampler.readings()
        let firstCallElapsed = Date().timeIntervalSince(started)

        var readings: [AccessoryBatteryReading] = []
        let waitUntil = Date().addingTimeInterval(5)
        while Date() < waitUntil {
            readings = sampler.readings()
            if !readings.isEmpty { break }
            // Live-only (MACHELPER_LIVE_HIDPP): the real receiver's background query has no
            // completion hook, so this test polls the cache it fills.
            Thread.sleep(forTimeInterval: 0.1)
        }
        let totalElapsed = Date().timeIntervalSince(started)

        let summary = [
            "firstCallElapsed=\(firstCallElapsed)s",
            "totalElapsed=\(totalElapsed)s",
            "cachedReadings=\(readings.map { "\($0.id) name=\($0.name) charge=\($0.charge) isCharging=\($0.isCharging)" })",
        ]
        let logPath = (env["MACHELPER_LIVE_HIDPP_LOG"] ?? NSTemporaryDirectory() + "machelper-live-hidpp.log") + ".sampler"
        try summary.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        // 不阻塞：第一次呼叫只讀快取，不能等 HID++ 查詢。
        #expect(firstCallElapsed < 0.1)
    }
}
