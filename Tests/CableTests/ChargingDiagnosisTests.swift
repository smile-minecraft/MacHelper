import Foundation
import Testing
@testable import Cable

@Suite struct ChargingDiagnosisTests {
    private func power(
        adapter: Double? = 96,
        recommended: Int? = 96,
        charging: Bool? = true,
        external: Bool? = true,
        reasons: [String] = [],
        temperature: Double? = 30,
        batteryInstalled: Bool? = true,
        model: String? = "MacBookPro18,1"
    ) -> PowerState {
        PowerState(
            machineModel: model,
            batteryInstalled: batteryInstalled,
            adapterWatts: adapter,
            recommendedAdapterWatts: recommended,
            externalConnected: external,
            isCharging: charging,
            notChargingReasons: reasons,
            temperatureCelsius: temperature
        )
    }

    private func port(cable: CableSpec?, connected: Bool = true) -> PortStatus {
        PortStatus(id: "Port-USB-C@2", number: 2, portType: "USB-C", connected: connected, cable: cable)
    }

    private func find(_ id: String, in findings: [ChargingFinding]) -> ChargingFinding? {
        findings.first { $0.id == id }
    }

    @Test func desktopWithoutBatteryIsNotApplicable() {
        let findings = ChargingDiagnosis.evaluate(power: power(adapter: 60, charging: false, external: true, batteryInstalled: false, model: "Mac16,10"))
        #expect(findings.count == 1)
        #expect(findings.first?.id == "charging.notApplicable.desktop")
        #expect(findings.first?.severity == .info)
        #expect(findings.first?.reason.contains("BatteryInstalled = false") == true)

        let laptop = ChargingDiagnosis.evaluate(power: power(), ports: [port(cable: .noEmarker)])
        #expect(!laptop.contains { $0.id == "charging.notApplicable.desktop" })
    }

    @Test func underpoweredAdapterTriggersOnlyBelowRecommendation() throws {
        let low = ChargingDiagnosis.evaluate(power: power(adapter: 60))
        let finding = try #require(find("charging.adapter.underpowered", in: low))
        #expect(finding.severity == .warning)
        #expect(finding.reason.contains("60 W"))
        let severe = ChargingDiagnosis.evaluate(power: power(adapter: 45))
        #expect(find("charging.adapter.underpowered", in: severe)?.severity == .problem)
        let correct = ChargingDiagnosis.evaluate(power: power(adapter: 96))
        #expect(find("charging.adapter.underpowered", in: correct) == nil)
    }

    @Test func threeAmpCableTriggersOnlyWithALargerAdapter() throws {
        let threeAmp = CableSpec(kind: .passive, current: .amps3, maxWatts: 60)
        let finding = try #require(find("cable.current3a.limit60w", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 100), ports: [port(cable: threeAmp)], cables: [threeAmp]
        )))
        #expect(finding.severity == .warning)
        #expect(finding.recommendation.contains("5 A"))
        let fiveAmp = CableSpec(kind: .passive, current: .amps5, maxWatts: 100)
        #expect(find("cable.current3a.limit60w", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 100), ports: [port(cable: fiveAmp)], cables: [fiveAmp]
        )) == nil)
        #expect(find("cable.current3a.limit60w", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 60), ports: [port(cable: threeAmp)], cables: [threeAmp]
        )) == nil)
    }

    @Test func missingEmarkerTriggersOnlyOnAnActivePort() throws {
        let finding = try #require(find("cable.noEmarker", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 100), ports: [port(cable: .noEmarker)]
        )))
        #expect(finding.reason.contains("SOP'"))
        #expect(find("cable.noEmarker", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 100), ports: [port(cable: CableSpec(kind: .passive, current: .amps5))]
        )) == nil)
        #expect(find("cable.noEmarker", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 100), ports: [port(cable: .noEmarker, connected: false)]
        )) == nil)
    }

    @Test func pausedChargingReasonIsReportedAndThermalReasonEscalates() throws {
        let paused = try #require(find("charging.paused.reason", in: ChargingDiagnosis.evaluate(
            power: power(charging: false, reasons: ["Predictive charging / charging limit"])
        )))
        #expect(paused.severity == .warning)
        #expect(paused.reason.contains("Predictive charging"))
        let hot = try #require(find("charging.paused.reason", in: ChargingDiagnosis.evaluate(
            power: power(charging: false, reasons: ["Temperature above maximum to stop charging"])
        )))
        #expect(hot.severity == .problem)
        #expect(find("charging.paused.reason", in: ChargingDiagnosis.evaluate(
            power: power(charging: true, reasons: ["Battery fully charged"])
        )) == nil)
        #expect(find("charging.paused.reason", in: ChargingDiagnosis.evaluate(
            power: power(charging: false, external: false, reasons: ["VBUS not present"])
        )) == nil)
    }

    @Test func hubAndDisplayOnTheSamePortAreReported() throws {
        let hub = USBDeviceNode(name: "USB Hub", isHub: true, portNumber: 2)
        let display = DisplayInfo(id: "d1", portNumber: 2)
        let finding = try #require(find("charging.throughHubOrDisplay", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 96), usbDevices: [hub], displays: [display]
        )))
        #expect(finding.severity == .info)
        #expect(find("charging.throughHubOrDisplay", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 96), usbDevices: [hub], displays: [DisplayInfo(id: "d1", portNumber: 1)]
        )) == nil)
    }

    @Test func hotBatteryTriggersOnlyAboveTheThreshold() throws {
        let hot = try #require(find("battery.overheating", in: ChargingDiagnosis.evaluate(power: power(temperature: 46))))
        #expect(hot.severity == .problem)
        #expect(find("battery.overheating", in: ChargingDiagnosis.evaluate(power: power(temperature: 30))) == nil)
    }

    @Test func slowDeviceTriggersOnlyWhenBelowItsCapability() {
        let slow = USBDeviceNode(locationID: 123, name: "Fast Disk", negotiatedSpeedMbps: 480, maxSpeedMbps: 10_000)
        let findings = ChargingDiagnosis.evaluate(power: power(), usbDevices: [slow])
        #expect(findings.contains { $0.title.contains("USB 2.0 speed") })
        #expect(findings.contains { $0.id.contains("123") })
        let fullSpeed = USBDeviceNode(locationID: 123, name: "Fast Disk", negotiatedSpeedMbps: 10_000, maxSpeedMbps: 10_000)
        #expect(ChargingDiagnosis.evaluate(power: power(), usbDevices: [fullSpeed]).isEmpty)
    }
}
