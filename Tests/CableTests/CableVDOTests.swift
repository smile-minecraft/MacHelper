import Foundation
import Testing
@testable import Cable

@Suite struct CableVDOTests {
    /// Builds a PD VDO from independent fields so a swapped bit range fails a test.
    private func vdo(
        version: UInt32 = 0,
        plug: UInt32 = 2,
        epr: UInt32 = 0,
        latency: UInt32 = 1,
        termination: UInt32 = 0,
        voltage: UInt32 = 0,
        current: UInt32 = 1,
        speed: UInt32 = 0,
        vbusThroughCable: UInt32 = 0,
        sopPrime: UInt32 = 0
    ) -> UInt32 {
        (version << 21) | (plug << 18) | (epr << 17) | (latency << 13) | (termination << 11)
            | (voltage << 9) | (current << 5) | (vbusThroughCable << 4) | (sopPrime << 3) | speed
    }

    private func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    /// Active Cable VDO1: HW 1, FW 2, VDO version 1.3, Type-C plug, EPR, both ends
    /// active, 50 V, 5 A, VBUS through the cable, SOP'' controller, USB4 Gen3.
    private func activeCableVDO1() -> UInt32 {
        (1 << 28) | (2 << 24) | (3 << 21) | (2 << 18) | (1 << 17) | (3 << 13) | (3 << 11)
            | (3 << 9) | (2 << 5) | (1 << 4) | (1 << 3) | 3
    }

    /// Active Cable VDO2: 70 °C operating, 80 °C shutdown, copper, re-timer, USB4,
    /// USB2 and USB3 supported, two lanes, Gen2 or higher, no asymmetric mode.
    private func activeCableVDO2() -> UInt32 {
        (70 << 24) | (80 << 16) | (1 << 9) | (1 << 3) | 1
    }

    @Test func activeCableArrayReadsVDO1AtTheFourthVDO() throws {
        let vdo1 = activeCableVDO1()
        let vdo2 = activeCableVDO2()
        // SOP' Discover Identity order: [ID Header, Cert Stat, Product, Active Cable VDO1,
        // Active Cable VDO2]. VDO1 is index 3, VDO2 is index 4.
        let spec = try #require(CableVDOParser.decode(
            vdos: [littleEndian(0x18000000), littleEndian(0), littleEndian(0), littleEndian(vdo1), littleEndian(vdo2)],
            kind: .active,
            vendorID: 1234,
            productID: 5678
        ))
        #expect(spec.kind == .active)
        #expect(spec.speed == .usb4Gen3)
        #expect(spec.current == .amps5)
        #expect(spec.voltage == .volts50)
        #expect(spec.maxWatts == 240)
        #expect(spec.eprCapable == true)
        #expect(spec.plug == .typeC)
        #expect(spec.termination == .bothEndsActive)
        #expect(spec.latency == .ns20To30)
        #expect(spec.vdoVersion == 3)
        #expect(spec.vdoVersionIsValid)
        #expect(spec.hardwareVersion == 1)
        #expect(spec.firmwareVersion == 2)
        #expect(spec.active?.maximumOperatingCelsius == 70)
        #expect(spec.active?.shutdownCelsius == 80)
        #expect(spec.active?.copper == true)
        #expect(spec.active?.retimer == true)
        #expect(spec.active?.twoLanes == true)
        #expect(spec.active?.asymmetricMode == false)
        #expect(spec.rawVDOs.count == 5)
    }

    @Test func activeCableNodeWithProductTypeFourDecodesTheVDOArray() throws {
        let node: [String: Any] = [
            "IOObjectClass": "IOPortTransportComponentCCUSBPDSOPp",
            "Metadata": [
                "Product Type": 4,
                "Product Type Description": "Active Cable",
                "Vendor ID": 1234,
                "Product ID": 5678,
                "VDOs": [
                    littleEndian(0x18000000), littleEndian(0), littleEndian(0),
                    littleEndian(activeCableVDO1()), littleEndian(activeCableVDO2()),
                ],
            ],
        ]
        let spec = try #require(IORegistryParser.parseCable(node))
        #expect(spec.kind == .active)
        #expect(spec.vendorID == 1234)
        #expect(spec.productID == 5678)
        #expect(spec.speed == .usb4Gen3)
        #expect(spec.current == .amps5)
        #expect(spec.maxWatts == 240)
        #expect(spec.vdoVersionIsValid)
        #expect(spec.active?.retimer == true)
        #expect(spec.active?.twoLanes == true)
        #expect(spec.rawVDOs[3] == activeCableVDO1())
        #expect(spec.rawVDOs[4] == activeCableVDO2())
    }

    @Test func realCableVDOFromThisMac() throws {
        let spec = CableVDOParser.decode(cableVDO: 0x250A2643, kind: .passive,
                                         vendorID: 14057, productID: 12290,
                                         productTypeDescription: "Passive Cable")
        #expect(spec.vendorID == 14057)
        #expect(spec.productID == 12290)
        #expect(spec.kind == .passive)
        #expect(spec.speed == .usb4Gen3)
        #expect(spec.speed.gigabitsPerSecond == 40)
        #expect(spec.current == .amps5)
        #expect(spec.voltage == .volts50)
        #expect(spec.maxWatts == 240)
        #expect(spec.eprCapable == true)
        #expect(spec.plug == .typeC)
        #expect(spec.latency == .under10ns)
        #expect(spec.termination == .vconnNotRequired)
        #expect(spec.vdoVersion == 0)
        #expect(spec.vdoVersionIsValid)
        #expect(spec.hardwareVersion == 2)
        #expect(spec.firmwareVersion == 5)
    }

    @Test func realCableFixtureDecodesFromLittleEndianMetadata() throws {
        let nodes = FixtureLoader.array("PortStates")
        func findSOPPrime(_ node: [String: Any]) -> [String: Any]? {
            if (node["IOObjectClass"] as? String) == "IOPortTransportComponentCCUSBPDSOPp" { return node }
            for child in IORegistryParser.children(node) {
                if let found = findSOPPrime(child) { return found }
            }
            return nil
        }
        let cableNode = nodes.compactMap { findSOPPrime($0) }.first
        let spec = try #require(IORegistryParser.parseCable(cableNode ?? [:]))
        #expect(spec.kind == .passive)
        #expect(spec.speed == .usb4Gen3)
        #expect(spec.current == .amps5)
        #expect(spec.maxWatts == 240)
        #expect(spec.rawVDOs[3] == 0x250A2643)
    }

    @Test func threeAmpUSB2CableIsSixtyWatts() throws {
        let value = vdo(latency: 1, voltage: 0, current: 1, speed: 0)
        let spec = CableVDOParser.decode(cableVDO: value, kind: .passive)
        #expect(spec.speed == .usb2)
        #expect(spec.current == .amps3)
        #expect(spec.voltage == .volts20)
        #expect(spec.maxWatts == 60)
        #expect(spec.eprCapable == false)
    }

    @Test func activeCableReadsVDOVersionAndVDO2() throws {
        let value = vdo(version: 3, plug: 3, epr: 0, latency: 2, termination: 3,
                        voltage: 0, current: 2, speed: 2, vbusThroughCable: 1, sopPrime: 1)
        // VDO2 (PD 3.3 Table 6.48): optical (bit 10), re-timer (bit 9), USB4
        // supported (bit 8 clear), USB2/USB3 supported (bits 5/4 clear), two lanes
        // (bit 3), USB4 asymmetric mode (bit 1), Gen2+ (bit 0).
        let vdo2: UInt32 = (1 << 10) | (1 << 9) | (0 << 8) | (0 << 5) | (0 << 4) | (1 << 3) | (1 << 1) | 1
        let spec = CableVDOParser.decode(cableVDO: value, kind: .active, activeVDO1: value, activeVDO2: vdo2)
        #expect(spec.kind == .active)
        #expect(spec.vdoVersion == 3)
        #expect(spec.vdoVersionIsValid)
        #expect(spec.speed == .gen2)
        #expect(spec.current == .amps5)
        #expect(spec.maxWatts == 100)
        #expect(spec.plug == .captive)
        #expect(spec.termination == .bothEndsActive)
        #expect(spec.vbusThroughCable == true)
        #expect(spec.sopPrimeController == true)
        #expect(spec.active?.copper == false)
        #expect(spec.active?.retimer == true)
        #expect(spec.active?.usb4Supported == true)
        #expect(spec.active?.usb2Supported == true)
        #expect(spec.active?.usb3Supported == true)
        #expect(spec.active?.twoLanes == true)
        #expect(spec.active?.asymmetricMode == true)
        #expect(spec.active?.gen2OrHigher == true)
    }

    @Test func eprCableIsTwoHundredFortyWattsAtEightyGigabits() throws {
        let value = vdo(version: 0, epr: 1, voltage: 3, current: 2, speed: 4)
        let spec = CableVDOParser.decode(cableVDO: value, kind: .passive)
        #expect(spec.eprCapable == true)
        #expect(spec.voltage == .volts50)
        #expect(spec.current == .amps5)
        #expect(spec.speed == .usb4Gen4)
        #expect(spec.maxWatts == 240)
    }

    @Test func deprecatedVoltageCodeIsTreatedAsTwentyVolts() throws {
        let spec = CableVDOParser.decode(cableVDO: vdo(voltage: 1, current: 2, speed: 2), kind: .passive)
        #expect(spec.voltage == .volts30Deprecated)
        #expect(spec.voltage.negotiableVolts == 20)
        #expect(spec.maxWatts == 100)
    }

    @Test func invalidFieldsStayUnknownInsteadOfZero() throws {
        let spec = CableVDOParser.decode(cableVDO: vdo(voltage: 0, current: 0, speed: 7), kind: .passive)
        #expect(spec.current == .unknown)
        #expect(spec.current.amps == nil)
        #expect(spec.speed == .unknown)
        #expect(spec.maxWatts == nil)
        #expect(CableVDOParser.decode(vdos: [littleEndian(0x250A2643)], kind: .passive,
                                      vendorID: nil, productID: nil) == nil)
    }

    @Test func noEmarkerHasTheUSBCFallbackMessage() throws {
        let spec = CableSpec.noEmarker
        #expect(spec.kind == .absent)
        #expect(spec.current == .amps3)
        #expect(spec.summary.contains("3 A / 60 W"))
        #expect(spec.speed == .unknown)
    }
}
