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

    /// A port with a PD partner identity (Vendor ID (SOP)) and no data transport is
    /// what the diagnosis treats as a possible charging port.
    private func chargingPort(number: Int = 2, cable: CableSpec?) -> PortStatus {
        PortStatus(
            id: "Port-USB-C@\(number)",
            number: number,
            portType: "USB-C",
            connected: true,
            activeTransports: [.cc],
            partner: PartnerIdentity(vendorID: 1439, productID: 4321),
            cable: cable
        )
    }

    private func port(
        number: Int = 2,
        cable: CableSpec?,
        connected: Bool = true,
        partnerVendorID: Int? = nil,
        transports: [Transport] = [.cc]
    ) -> PortStatus {
        PortStatus(
            id: "Port-USB-C@\(number)",
            number: number,
            portType: "USB-C",
            connected: connected,
            activeTransports: transports,
            partner: partnerVendorID.map { PartnerIdentity(vendorID: $0) },
            cable: cable
        )
    }

    private func find(_ id: String, in findings: [ChargingFinding]) -> ChargingFinding? {
        findings.first { $0.id == id }
    }

    private let fiveAmp = CableSpec(kind: .passive, current: .amps5, maxWatts: 240)
    private let threeAmp = CableSpec(kind: .passive, current: .amps3, maxWatts: 60)

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

    @Test func threeAmpCableOnTheChargingPortWarns() throws {
        let finding = try #require(find("cable.current3a.limit60w", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 100), ports: [chargingPort(cable: threeAmp)]
        )))
        #expect(finding.severity == .warning)
        #expect(finding.reason.contains("Port-USB-C@2"))
        #expect(finding.recommendation.contains("5 A"))

        #expect(find("cable.current3a.limit60w", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 100), ports: [chargingPort(cable: fiveAmp)]
        )) == nil)
        #expect(find("cable.current3a.limit60w", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 60), ports: [chargingPort(cable: threeAmp)]
        )) == nil)
    }

    @Test func cableOnAKeyboardPortDoesNotWarnWhileTheChargerUsesATwoMetreFiveAmpCable() {
        // The keyboard cable has no e-marker and the charging port has a 5 A cable:
        // neither cable rule may look at the keyboard port.
        let keyboard = port(number: 6, cable: .noEmarker, partnerVendorID: 1133, transports: [.cc, .usb2])
        let charger = chargingPort(cable: fiveAmp)
        let findings = ChargingDiagnosis.evaluate(power: power(adapter: 140), ports: [charger, keyboard])
        #expect(find("cable.current3a.limit60w", in: findings) == nil)
        #expect(find("cable.noEmarker", in: findings) == nil)
    }

    @Test func aThreeAmpCableOnAnotherPortDoesNotWarn() {
        let keyboard = port(number: 6, cable: threeAmp, partnerVendorID: 1133, transports: [.cc, .usb2])
        let findings = ChargingDiagnosis.evaluate(power: power(adapter: 140), ports: [chargingPort(cable: fiveAmp), keyboard])
        #expect(find("cable.current3a.limit60w", in: findings) == nil)
    }

    @Test func missingEmarkerOnTheChargingPortWarns() throws {
        let finding = try #require(find("cable.noEmarker", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 100), ports: [chargingPort(number: 3, cable: .noEmarker)]
        )))
        #expect(finding.severity == .warning)
        #expect(finding.reason.contains("Port-USB-C@3"))
        #expect(finding.reason.contains("SOP'") || finding.reason.contains("Discover Identity"))
        let eMarked = chargingPort(cable: fiveAmp)
        #expect(find("cable.noEmarker", in: ChargingDiagnosis.evaluate(power: power(adapter: 100), ports: [eMarked])) == nil)
    }

    @Test func withoutAnIdentifiableChargingPortTheCableRulesFallBackToInfo() throws {
        // A data-carrying port has no SOP partner identity, so nothing looks like the
        // charger: the rules still run, but only as info and naming the port.
        let usbPort = port(number: 4, cable: threeAmp, transports: [.cc, .usb2])
        let findings = ChargingDiagnosis.evaluate(power: power(adapter: 100), ports: [usbPort])
        let threeAmpFinding = try #require(find("cable.current3a.limit60w", in: findings))
        #expect(threeAmpFinding.severity == .info)
        #expect(threeAmpFinding.reason.contains("Port-USB-C@4"))
        #expect(threeAmpFinding.reason.contains("If the charger is connected"))

        let noMarkerPort = port(number: 4, cable: .noEmarker, transports: [.cc, .usb2])
        let emarkerFinding = try #require(find("cable.noEmarker", in: ChargingDiagnosis.evaluate(power: power(adapter: 100), ports: [noMarkerPort])))
        #expect(emarkerFinding.severity == .info)
        #expect(emarkerFinding.reason.contains("Port-USB-C@4"))
    }

    @Test func aDockPortIsNotTheChargingPort() {
        // The dock answers SOP and carries Thunderbolt data; the separate charging
        // port does not exist here, so nothing may be reported as a charger cable.
        let dock = port(number: 5, cable: threeAmp, partnerVendorID: 8457, transports: [.cc, .usb3])
        let findings = ChargingDiagnosis.evaluate(power: power(adapter: 140), ports: [dock])
        #expect(find("cable.current3a.limit60w", in: findings)?.severity == .info)

        let withCharger = ChargingDiagnosis.evaluate(power: power(adapter: 140), ports: [dock, chargingPort(cable: fiveAmp)])
        #expect(find("cable.current3a.limit60w", in: withCharger) == nil)
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

    @Test func aPortWithPartnerIdentityAndDisplayOrHubTrafficReportsSharedPower() throws {
        let displayPort = port(number: 2, cable: fiveAmp, partnerVendorID: 1439, transports: [.cc, .cio])
        let finding = try #require(find("charging.throughHubOrDisplay", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 96), ports: [displayPort]
        )))
        #expect(finding.severity == .info)
        #expect(finding.reason.contains("Port-USB-C@2"))

        // A hub on a port that also answers SOP.
        let hub = USBDeviceNode(name: "USB Hub", isHub: true, portNumber: 5)
        let dockPort = port(number: 5, cable: fiveAmp, partnerVendorID: 8457, transports: [.cc, .usb3])
        #expect(find("charging.throughHubOrDisplay", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 96), ports: [dockPort], usbDevices: [hub]
        )) != nil)

        // A USB-C display on the same port as the PD partner.
        let laptopCharger = port(number: 2, cable: fiveAmp, partnerVendorID: 1439, transports: [.cc])
        let usbcDisplay = DisplayInfo(id: "d2", connectionType: "USB-C", portNumber: 2)
        #expect(find("charging.throughHubOrDisplay", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 96), ports: [laptopCharger], displays: [usbcDisplay]
        )) != nil)
        // An HDMI display shares the port number with a USB-C port but is not a dock.
        let hdmiDisplay = DisplayInfo(id: "d3", connectionType: "HDMI", portNumber: 2)
        #expect(find("charging.throughHubOrDisplay", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 96), ports: [laptopCharger], displays: [hdmiDisplay]
        )) == nil)

        // Data without a PD partner, or a plain charger port, is not a dock.
        let noPartner = port(number: 2, cable: fiveAmp, transports: [.cc, .cio])
        #expect(find("charging.throughHubOrDisplay", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 96), ports: [noPartner], displays: [DisplayInfo(id: "d1", portNumber: 2)]
        )) == nil)
        #expect(find("charging.throughHubOrDisplay", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 96), ports: [chargingPort(cable: fiveAmp)]
        )) == nil)
    }

    @Test func aDockBesideASeparateChargerOrOnBatteryIsNotReportedAsTheSupply() {
        let dock = port(number: 2, cable: fiveAmp, partnerVendorID: 1439, transports: [.cc, .cio])
        // The laptop charges from its own charger on another port.
        #expect(find("charging.throughHubOrDisplay", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 96), ports: [dock, chargingPort(number: 3, cable: fiveAmp)]
        )) == nil)
        // Running on battery: nothing is supplying power through the dock.
        #expect(find("charging.throughHubOrDisplay", in: ChargingDiagnosis.evaluate(
            power: power(adapter: nil, charging: false, external: false), ports: [dock]
        )) == nil)
        // The dock is the only power source: reported.
        #expect(find("charging.throughHubOrDisplay", in: ChargingDiagnosis.evaluate(
            power: power(adapter: 96), ports: [dock]
        )) != nil)
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
        // No proven capability (USB 2.x descriptor) means no bottleneck claim.
        let unknown = USBDeviceNode(locationID: 124, name: "USB Receiver", negotiatedSpeedMbps: 12, maxSpeedMbps: nil)
        #expect(ChargingDiagnosis.evaluate(power: power(), usbDevices: [unknown]).isEmpty)
    }
}
