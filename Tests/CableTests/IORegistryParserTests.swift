import Foundation
import Testing
@testable import Cable

@Suite struct IORegistryParserTests {
    private let ports = FixtureLoader.array("Ports")
    private let states = FixtureLoader.array("PortStates")
    private let devices = FixtureLoader.array("USBDevices")
    private let modes = FixtureLoader.array("DisplayModes").compactMap { dict -> DisplayModeInfo? in
        guard let width = dict["width"] as? Int, let height = dict["height"] as? Int else { return nil }
        return DisplayModeInfo(
            vendorID: dict["vendorID"] as? Int,
            productID: dict["productID"] as? Int,
            width: width,
            height: height,
            refreshHz: dict["refreshHz"] as? Double,
            pixelWidth: dict["pixelWidth"] as? Int,
            pixelHeight: dict["pixelHeight"] as? Int
        )
    }

    @Test func fixtureParsesLivePortsAndCable() throws {
        let parsed = IORegistryParser.parsePorts(ports: ports, states: states)
        #expect(parsed.count == 5)
        let port2 = try #require(parsed.first { $0.number == 2 })
        #expect(port2.id == "Port-USB-C@2")
        #expect(port2.portType == "USB-C")
        #expect(port2.connected == true)
        #expect(port2.orientation == .flipped)
        #expect(port2.activeTransports.contains(.cc))
        #expect(port2.activeTransports.contains(.cio))
        #expect(port2.partner?.vendorID == 1439)
        #expect(port2.partner?.productID == 4321)
        // The CIO node exposes codes, not rates; never print "Gen2" for 10 Gbps.
        #expect(port2.negotiatedSpeed?.contains("generation code 2") == true)
        #expect(port2.negotiatedSpeed?.contains("cable speed code 3") == true)
        #expect(port2.negotiatedSpeed?.contains("Gen2") == false)
        let cable = try #require(port2.cable)
        #expect(cable.kind == .passive)
        #expect(cable.speed == .usb4Gen3)
        #expect(cable.current == .amps5)
        #expect(cable.maxWatts == 240)
        #expect(cable.vendorID == 14057)

        let port1 = try #require(parsed.first { $0.number == 1 })
        #expect(port1.connected == false)
        #expect(port1.cable == nil)
        let port5 = try #require(parsed.first { $0.number == 5 })
        #expect(port5.connected == true)
        #expect(port5.activeTransports.contains(.usb2))
        #expect(port5.activeTransports.contains(.usb3))
    }

    @Test func fixtureParsesUSBDeviceTreeAndSpeeds() throws {
        let roots = IORegistryParser.parseUSBDevices(devices)
        #expect(roots.count == 2)
        let usb2Root = try #require(roots.first { $0.name == "USB2 Hub" })
        #expect(usb2Root.isHub)
        #expect(usb2Root.negotiatedSpeedMbps == 480)
        // bcdUSB 0x210 describes the protocol, not a 480 Mbps capability.
        #expect(usb2Root.maxSpeedMbps == nil)
        let viaHub = try #require(usb2Root.children.first { $0.name == "USB2.0 Hub" })
        #expect(viaHub.isHub)
        #expect(viaHub.vendorID == 8457)
        #expect(viaHub.children.contains { $0.name == "USB2.0 Hub" })
        let downstreamHub = try #require(viaHub.children.first { $0.name == "USB2.0 Hub" })
        #expect(downstreamHub.children.contains { $0.name == "USB Storage" })

        let usb3Root = try #require(roots.first { $0.name == "USB3 Gen2 Hub" })
        #expect(usb3Root.negotiatedSpeedMbps == 10_000)
        // A 3.x device proves at least 5 Gbps; 10 Gbps negotiated raises the floor.
        #expect(usb3Root.maxSpeedMbps == 10_000)
        let gen1Hub = try #require(usb3Root.children.first { $0.name == "USB3.1 Hub" })
        #expect(gen1Hub.negotiatedSpeedMbps == 5_000)
        // bcdUSB 0x320 does not prove Gen2: the hub itself negotiated 5 Gbps.
        #expect(gen1Hub.maxSpeedMbps == 5_000)
        let lan = try #require(gen1Hub.children.first { $0.name == "USB 10_100_1000 LAN" })
        #expect(lan.maxSpeedMbps == 5_000)

        // A USB 2.0 protocol device cannot claim a SuperSpeed maximum.
        let air75 = try #require(usb2Root.children.first { $0.name == "Air75 V3" })
        #expect(air75.maxSpeedMbps == nil)
        let receiver = try #require(viaHub.children.first { $0.name == "USB Receiver" })
        #expect(receiver.maxSpeedMbps == nil)
    }

    @Test func fixtureAttributesUSBDevicesToTheirUSBCPorts() throws {
        let tree = IORegistryParser.attributeUSBPorts(
            devices: IORegistryParser.parseUSBDevices(devices),
            states: states
        )
        let usb2Root = try #require(tree.first { $0.name == "USB2 Hub" })
        let usb3Root = try #require(tree.first { $0.name == "USB3 Gen2 Hub" })
        // The Mac's own root hubs match no port transport state.
        #expect(usb2Root.portNumber == nil)
        #expect(usb2Root.isBuiltIn)
        #expect(usb3Root.portNumber == nil)
        #expect(usb3Root.isBuiltIn)

        let viaUSB2Hub = try #require(usb2Root.children.first { $0.name == "USB2.0 Hub" && $0.vendorID == 8457 })
        #expect(viaUSB2Hub.portNumber == 5)
        #expect(!viaUSB2Hub.isBuiltIn)
        // Every descendant of a matched hub inherits the port.
        let downstreamHub = try #require(viaUSB2Hub.children.first { $0.name == "USB2.0 Hub" })
        #expect(downstreamHub.portNumber == 5)
        #expect(downstreamHub.children.first { $0.name == "USB Storage" }?.portNumber == 5)
        #expect(viaUSB2Hub.children.first { $0.name == "Air75 V3 Dongle" }?.portNumber == 5)
        #expect(viaUSB2Hub.children.first { $0.name == "USB Receiver" }?.portNumber == 5)

        // The keyboard sits directly on port 6 while both VIA hubs share port 5.
        #expect(usb2Root.children.first { $0.name == "Air75 V3" }?.portNumber == 6)
        let viaUSB3Hub = try #require(usb3Root.children.first { $0.name == "USB3.1 Hub" })
        #expect(viaUSB3Hub.portNumber == 5)
        #expect(viaUSB3Hub.children.first { $0.name == "USB 10_100_1000 LAN" }?.portNumber == 5)
    }

    @Test func identicalDevicesNeedTheReportedNameToPickAPort() {
        // Two identical receivers: only the name in the port state tells them apart.
        let devices: [[String: Any]] = [
            ["IOObjectClass": "IOUSBHostDevice", "USB Product Name": "Receiver A", "idVendor": 1133, "idProduct": 50503, "locationID": 1],
            ["IOObjectClass": "IOUSBHostDevice", "USB Product Name": "Receiver B", "idVendor": 1133, "idProduct": 50503, "locationID": 2],
        ]
        let hint: [[String: Any]] = [[
            "IOObjectClass": "IOPortTransportStateUSB2",
            "ParentPortNumber": 6,
            "ParentPortTypeDescription": "USB-C",
            "Vendor ID": 1133,
            "Product ID": 50503,
            "Product": "Receiver B",
        ]]
        let tree = IORegistryParser.attributeUSBPorts(
            devices: IORegistryParser.parseUSBDevices(devices),
            states: hint
        )
        #expect(tree.first { $0.name == "Receiver B" }?.portNumber == 6)
        #expect(tree.first { $0.name == "Receiver A" }?.portNumber == nil)
        #expect(tree.first { $0.name == "Receiver A" }?.isBuiltIn == true)
    }

    @Test func malformedPortStatesAttributeNothing() {
        let tree = IORegistryParser.attributeUSBPorts(
            devices: IORegistryParser.parseUSBDevices(devices),
            states: [
                ["IOObjectClass": "IOPortTransportStateUSB2", "ParentPortNumber": "broken"],
                ["IOObjectClass": "IOPortTransportStateUSB3", "ParentPortTypeDescription": "USB-A", "ParentPortNumber": 3, "Vendor ID": 8457, "Product ID": 2082],
                ["IOObjectClass": "IOPortTransportStateCC", "ParentPortNumber": 5, "Vendor ID": 8457, "Product ID": 2082],
            ]
        )
        #expect(tree.allSatisfy { $0.portNumber == nil })
    }

    @Test func fixtureParsesDisplayThroughItsRealPort() throws {
        let displays = IORegistryDisplayParser.parseDisplays(states: states, modes: modes)
        #expect(displays.count == 1)
        let display = try #require(displays.first)
        #expect(display.name == "MPG 274U E16M")
        #expect(display.manufacturer == "MSI")
        #expect(display.width == 2560)
        #expect(display.height == 1440)
        #expect(display.refreshHz == 144)
        #expect(display.pixelWidth == 5120)
        #expect(display.connectionType == "HDMI")
        #expect(display.portNumber == 1)
        #expect(display.linkRate?.contains("HBR3") == true)
    }

    @Test func fixtureParsesThunderboltAndDesktopPower() throws {
        let tb = IORegistryThunderboltParser.parse(states)
        #expect(tb.count == 1)
        #expect(tb.first?.name == "TBU405Pro")
        #expect(tb.first?.portNumber == 2)

        let power = IORegistryPowerParser.parse(FixtureLoader.dictionary("Power"), model: "Mac16,10")
        #expect(power.isDesktopWithoutBattery)
        #expect(power.batteryInstalled == false)
        #expect(power.adapterFamilyCode == 0)
        #expect(power.adapterWatts == nil)
        #expect(power.systemPowerInWatts.map { $0 > 0 } == true)
    }

    @Test func missingOrMalformedPropertiesStayUnknown() throws {
        #expect(IORegistryParser.parseCable([:]) == nil)
        let port = IORegistryParser.parsePorts(
            ports: [["PortNumber": "broken", "PortTypeDescription": "USB-C", "Description": "Port-USB-C@?"]],
            states: [["ParentPortNumber": "broken", "Active": "yes"]]
        )
        #expect(port.count == 1)
        #expect(port.first?.number == nil)
        #expect(port.first?.connected == nil)
        #expect(port.first?.cable == nil)
        #expect(IORegistryParser.parseUSBDevices([["USB Product Name": 42]]).isEmpty)
        #expect(IORegistryDisplayParser.parseDisplays(states: [["IOObjectClass": 1]]).isEmpty)
    }

    @Test func notChargingReasonBitsAreDecoded() throws {
        #expect(IORegistryPowerParser.decodeNotChargingReason(nil).isEmpty)
        #expect(IORegistryPowerParser.decodeNotChargingReason(0).isEmpty)
        #expect(IORegistryPowerParser.decodeNotChargingReason(1).contains("Battery fully charged"))
        #expect(IORegistryPowerParser.decodeNotChargingReason(128).contains("VBUS not present"))
        #expect(IORegistryPowerParser.decodeNotChargingReason(272).contains { $0.contains("Temperature above maximum") })
        #expect(IORegistryPowerParser.decodeNotChargingReason(1 << 15).contains { $0.contains("Predictive charging") })
    }

    @Test func usbTwoOnlyPortNamesItsDeviceAndHighFaultBitsSurvive() {
        let ports = IORegistryParser.parsePorts(ports: FixtureLoader.array("Ports"), states: FixtureLoader.array("PortStates"))
        // Port 6 has only a USB 2.0 keyboard and an idle USB3 state.
        #expect(ports.first { $0.number == 6 }?.deviceName == "Air75 V3")
        #expect(IORegistryPowerParser.decodeNotChargingReason(Int(bitPattern: UInt(1) << 63)).contains("Battery or charger fault"))
    }
}
