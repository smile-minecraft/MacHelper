import Foundation

/// A USB data rate decoded from a PD Cable VDO's USB Highest Speed field.
public enum CableSpeed: String, Codable, Sendable, CaseIterable {
    case unknown
    case usb2
    case gen1
    case gen2
    case usb4Gen3
    case usb4Gen4

    /// Nominal signalling rate in gigabits per second.
    public var gigabitsPerSecond: Double? {
        switch self {
        case .unknown, .usb2: return nil
        case .gen1: return 5
        case .gen2: return 10
        case .usb4Gen3: return 40
        case .usb4Gen4: return 80
        }
    }

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .usb2: return "USB 2.0"
        case .gen1: return "USB 3.2 Gen1 (5 Gbps)"
        case .gen2: return "USB 3.2 / USB4 Gen2 (10 Gbps)"
        case .usb4Gen3: return "USB4 Gen3 (40 Gbps)"
        case .usb4Gen4: return "USB4 Gen4 (80 Gbps)"
        }
    }
}

public enum CableCurrent: String, Codable, Sendable {
    case unknown
    case amps3
    case amps5

    public var amps: Int? {
        switch self {
        case .unknown: return nil
        case .amps3: return 3
        case .amps5: return 5
        }
    }
}

/// Raw voltage code from the Cable VDO. PD 3.1 deprecates codes 01b and 10b:
/// a receiver must treat them as 20 V, which ``negotiableVolts`` does.
public enum CableVoltage: String, Codable, Sendable {
    case unknown
    case volts20
    case volts30Deprecated
    case volts40Deprecated
    case volts50

    public var code: Int? {
        switch self {
        case .unknown: return nil
        case .volts20: return 0
        case .volts30Deprecated: return 1
        case .volts40Deprecated: return 2
        case .volts50: return 3
        }
    }

    /// Voltage a PD source may negotiate over this cable.
    public var negotiableVolts: Int? {
        switch self {
        case .unknown: return nil
        case .volts20, .volts30Deprecated, .volts40Deprecated: return 20
        case .volts50: return 50
        }
    }
}

public enum CableLatency: String, Codable, Sendable {
    case unknown
    case under10ns
    case ns10To20
    case ns20To30
    case ns30To40
    case ns40To50
    case ns50To60
    case ns60To70
    case over70ns
    case active100ns
    case active200ns
    case active300ns

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .under10ns: return "<10 ns (~1 m)"
        case .ns10To20: return "10–20 ns (~2 m)"
        case .ns20To30: return "20–30 ns (~3 m)"
        case .ns30To40: return "30–40 ns (~4 m)"
        case .ns40To50: return "40–50 ns (~5 m)"
        case .ns50To60: return "50–60 ns (~6 m)"
        case .ns60To70: return "60–70 ns (~7 m)"
        case .over70ns: return ">70 ns (>~7 m)"
        case .active100ns: return "~100 ns (~100 m, active)"
        case .active200ns: return "~200 ns (~200 m, active)"
        case .active300ns: return "~300 ns (~300 m, active)"
        }
    }
}

public enum CableTermination: String, Codable, Sendable {
    case unknown
    case vconnNotRequired
    case vconnRequired
    case oneEndActive
    case bothEndsActive
}

public enum CablePlug: String, Codable, Sendable {
    case unknown
    case typeA
    case typeB
    case typeC
    case captive
}

public enum CableKind: String, Codable, Sendable {
    case unknown
    case passive
    case active
    /// SOP' did not answer Discover Identity: no e-marker in the cable.
    case absent

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown cable"
        case .passive: return "Passive cable"
        case .active: return "Active cable"
        case .absent: return "No e-marker"
        }
    }
}

/// Extra fields carried by Active Cable VDO2 (PD 3.1 Table 6.48).
public struct ActiveCableDetails: Sendable, Codable, Hashable {
    public var vdo2: UInt32?
    public var maximumOperatingCelsius: Int?
    public var shutdownCelsius: Int?
    public var copper: Bool?
    public var retimer: Bool?
    public var usb4Supported: Bool?
    public var usb2Supported: Bool?
    public var usb3Supported: Bool?
    public var twoLanes: Bool?
    public var opticallyIsolated: Bool?
    public var asymmetricMode: Bool?
    public var gen2OrHigher: Bool?

    public init(
        vdo2: UInt32? = nil,
        maximumOperatingCelsius: Int? = nil,
        shutdownCelsius: Int? = nil,
        copper: Bool? = nil,
        retimer: Bool? = nil,
        usb4Supported: Bool? = nil,
        usb2Supported: Bool? = nil,
        usb3Supported: Bool? = nil,
        twoLanes: Bool? = nil,
        opticallyIsolated: Bool? = nil,
        asymmetricMode: Bool? = nil,
        gen2OrHigher: Bool? = nil
    ) {
        self.vdo2 = vdo2
        self.maximumOperatingCelsius = maximumOperatingCelsius
        self.shutdownCelsius = shutdownCelsius
        self.copper = copper
        self.retimer = retimer
        self.usb4Supported = usb4Supported
        self.usb2Supported = usb2Supported
        self.usb3Supported = usb3Supported
        self.twoLanes = twoLanes
        self.opticallyIsolated = opticallyIsolated
        self.asymmetricMode = asymmetricMode
        self.gen2OrHigher = gen2OrHigher
    }
}

/// A decoded cable identity. Every optional is genuinely unknown when the source
/// did not provide it; no zero/default is substituted for a missing hardware value.
public struct CableSpec: Sendable, Codable, Hashable {
    public var kind: CableKind
    public var vendorID: Int?
    public var productID: Int?
    public var productTypeDescription: String?
    public var hardwareVersion: Int?
    public var firmwareVersion: Int?
    public var vdoVersion: Int?
    public var vdoVersionIsValid: Bool
    public var speed: CableSpeed
    public var current: CableCurrent
    public var voltage: CableVoltage
    public var eprCapable: Bool?
    public var latency: CableLatency
    public var termination: CableTermination
    public var plug: CablePlug
    public var sbuSupported: Bool?
    public var sbuActive: Bool?
    public var vbusThroughCable: Bool?
    public var sopPrimeController: Bool?
    public var active: ActiveCableDetails?
    public var rawVDOs: [UInt32]
    public var maxWatts: Int?
    public var summary: String

    public init(
        kind: CableKind = .unknown,
        vendorID: Int? = nil,
        productID: Int? = nil,
        productTypeDescription: String? = nil,
        hardwareVersion: Int? = nil,
        firmwareVersion: Int? = nil,
        vdoVersion: Int? = nil,
        vdoVersionIsValid: Bool = false,
        speed: CableSpeed = .unknown,
        current: CableCurrent = .unknown,
        voltage: CableVoltage = .unknown,
        eprCapable: Bool? = nil,
        latency: CableLatency = .unknown,
        termination: CableTermination = .unknown,
        plug: CablePlug = .unknown,
        sbuSupported: Bool? = nil,
        sbuActive: Bool? = nil,
        vbusThroughCable: Bool? = nil,
        sopPrimeController: Bool? = nil,
        active: ActiveCableDetails? = nil,
        rawVDOs: [UInt32] = [],
        maxWatts: Int? = nil,
        summary: String = "Cable identity unknown"
    ) {
        self.kind = kind
        self.vendorID = vendorID
        self.productID = productID
        self.productTypeDescription = productTypeDescription
        self.hardwareVersion = hardwareVersion
        self.firmwareVersion = firmwareVersion
        self.vdoVersion = vdoVersion
        self.vdoVersionIsValid = vdoVersionIsValid
        self.speed = speed
        self.current = current
        self.voltage = voltage
        self.eprCapable = eprCapable
        self.latency = latency
        self.termination = termination
        self.plug = plug
        self.sbuSupported = sbuSupported
        self.sbuActive = sbuActive
        self.vbusThroughCable = vbusThroughCable
        self.sopPrimeController = sopPrimeController
        self.active = active
        self.rawVDOs = rawVDOs
        self.maxWatts = maxWatts
        self.summary = summary
    }

    /// SOP' is silent for a non-electronic-marked cable. The USB-C fallback is 3 A / 60 W.
    public static var noEmarker: CableSpec {
        CableSpec(
            kind: .absent,
            current: .amps3,
            summary: "No e-marker: at most 3 A / 60 W; data rate unknown."
        )
    }
}

public enum Transport: String, Codable, Sendable, CaseIterable {
    case cc
    case usb2
    case usb3
    case cio
    case displayPort = "displayPort"
    case pcie
    case other
}

public enum PlugOrientation: String, Codable, Sendable {
    case unknown
    case normal
    case flipped
}

public struct PartnerIdentity: Sendable, Codable, Hashable {
    public var vendorID: Int?
    public var productID: Int?
    public var productName: String?

    public init(vendorID: Int? = nil, productID: Int? = nil, productName: String? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
    }
}

public struct PowerContract: Sendable, Codable, Hashable {
    public var volts: Double?
    public var amps: Double?
    public var watts: Double?

    public init(volts: Double? = nil, amps: Double? = nil, watts: Double? = nil) {
        self.volts = volts
        self.amps = amps
        self.watts = watts
    }
}

public struct PortStatus: Sendable, Codable, Hashable {
    public var id: String
    public var number: Int?
    public var portType: String
    /// nil when IORegistry did not report a connection state.
    public var connected: Bool?
    public var orientation: PlugOrientation
    public var activeTransports: [Transport]
    public var negotiatedSpeed: String?
    public var partner: PartnerIdentity?
    public var powerContract: PowerContract?
    public var cable: CableSpec?
    public var deviceName: String?

    public init(
        id: String,
        number: Int? = nil,
        portType: String = "Unknown",
        connected: Bool? = nil,
        orientation: PlugOrientation = .unknown,
        activeTransports: [Transport] = [],
        negotiatedSpeed: String? = nil,
        partner: PartnerIdentity? = nil,
        powerContract: PowerContract? = nil,
        cable: CableSpec? = nil,
        deviceName: String? = nil
    ) {
        self.id = id
        self.number = number
        self.portType = portType
        self.connected = connected
        self.orientation = orientation
        self.activeTransports = activeTransports
        self.negotiatedSpeed = negotiatedSpeed
        self.partner = partner
        self.powerContract = powerContract
        self.cable = cable
        self.deviceName = deviceName
    }
}

public struct USBDeviceNode: Sendable, Codable, Hashable {
    public var locationID: UInt64?
    public var parentLocationID: UInt64?
    public var name: String
    public var vendorName: String?
    public var vendorID: Int?
    public var productID: Int?
    public var deviceClass: Int?
    public var isHub: Bool
    public var portNumber: Int?
    public var negotiatedSpeedMbps: Int?
    public var maxSpeedMbps: Int?
    public var children: [USBDeviceNode]

    public init(
        locationID: UInt64? = nil,
        parentLocationID: UInt64? = nil,
        name: String = "Unknown device",
        vendorName: String? = nil,
        vendorID: Int? = nil,
        productID: Int? = nil,
        deviceClass: Int? = nil,
        isHub: Bool = false,
        portNumber: Int? = nil,
        negotiatedSpeedMbps: Int? = nil,
        maxSpeedMbps: Int? = nil,
        children: [USBDeviceNode] = []
    ) {
        self.locationID = locationID
        self.parentLocationID = parentLocationID
        self.name = name
        self.vendorName = vendorName
        self.vendorID = vendorID
        self.productID = productID
        self.deviceClass = deviceClass
        self.isHub = isHub
        self.portNumber = portNumber
        self.negotiatedSpeedMbps = negotiatedSpeedMbps
        self.maxSpeedMbps = maxSpeedMbps
        self.children = children
    }
}

public struct ThunderboltDevice: Sendable, Codable, Hashable {
    public var name: String
    public var vendorID: Int?
    public var deviceID: Int?
    public var generation: Int?
    public var cableSpeed: Int?
    public var cableGeneration: Int?
    public var portNumber: Int?

    public init(
        name: String = "Unknown Thunderbolt device",
        vendorID: Int? = nil,
        deviceID: Int? = nil,
        generation: Int? = nil,
        cableSpeed: Int? = nil,
        cableGeneration: Int? = nil,
        portNumber: Int? = nil
    ) {
        self.name = name
        self.vendorID = vendorID
        self.deviceID = deviceID
        self.generation = generation
        self.cableSpeed = cableSpeed
        self.cableGeneration = cableGeneration
        self.portNumber = portNumber
    }
}

public struct DisplayModeInfo: Sendable, Codable, Hashable {
    public var vendorID: Int?
    public var productID: Int?
    public var width: Int
    public var height: Int
    public var refreshHz: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(
        vendorID: Int? = nil,
        productID: Int? = nil,
        width: Int,
        height: Int,
        refreshHz: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.width = width
        self.height = height
        self.refreshHz = refreshHz
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct DisplayInfo: Sendable, Codable, Hashable {
    public var id: String
    public var name: String
    public var manufacturer: String?
    public var width: Int?
    public var height: Int?
    public var refreshHz: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var connectionType: String?
    public var portNumber: Int?
    public var tunneled: Bool?
    public var linkRate: String?

    public init(
        id: String,
        name: String = "Unknown display",
        manufacturer: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        refreshHz: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        connectionType: String? = nil,
        portNumber: Int? = nil,
        tunneled: Bool? = nil,
        linkRate: String? = nil
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.width = width
        self.height = height
        self.refreshHz = refreshHz
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.connectionType = connectionType
        self.portNumber = portNumber
        self.tunneled = tunneled
        self.linkRate = linkRate
    }
}

/// Sanitized `AppleSmartBattery` inputs for the pure diagnosis function.
public struct PowerState: Sendable, Codable, Hashable {
    public var machineModel: String?
    public var batteryInstalled: Bool?
    public var designCapacity: Int?
    public var adapterWatts: Double?
    public var adapterVolts: Double?
    public var adapterAmps: Double?
    public var adapterDescription: String?
    public var adapterFamilyCode: Int?
    public var recommendedAdapterWatts: Int?
    public var externalConnected: Bool?
    public var isCharging: Bool?
    public var notChargingReasonRaw: Int?
    public var notChargingReasons: [String]
    public var temperatureCelsius: Double?
    public var systemPowerInWatts: Double?
    public var chargeLimitPercent: Int?
    public var optimizedCharging: Bool?

    public init(
        machineModel: String? = nil,
        batteryInstalled: Bool? = nil,
        designCapacity: Int? = nil,
        adapterWatts: Double? = nil,
        adapterVolts: Double? = nil,
        adapterAmps: Double? = nil,
        adapterDescription: String? = nil,
        adapterFamilyCode: Int? = nil,
        recommendedAdapterWatts: Int? = nil,
        externalConnected: Bool? = nil,
        isCharging: Bool? = nil,
        notChargingReasonRaw: Int? = nil,
        notChargingReasons: [String] = [],
        temperatureCelsius: Double? = nil,
        systemPowerInWatts: Double? = nil,
        chargeLimitPercent: Int? = nil,
        optimizedCharging: Bool? = nil
    ) {
        self.machineModel = machineModel
        self.batteryInstalled = batteryInstalled
        self.designCapacity = designCapacity
        self.adapterWatts = adapterWatts
        self.adapterVolts = adapterVolts
        self.adapterAmps = adapterAmps
        self.adapterDescription = adapterDescription
        self.adapterFamilyCode = adapterFamilyCode
        self.recommendedAdapterWatts = recommendedAdapterWatts
        self.externalConnected = externalConnected
        self.isCharging = isCharging
        self.notChargingReasonRaw = notChargingReasonRaw
        self.notChargingReasons = notChargingReasons
        self.temperatureCelsius = temperatureCelsius
        self.systemPowerInWatts = systemPowerInWatts
        self.chargeLimitPercent = chargeLimitPercent
        self.optimizedCharging = optimizedCharging
    }

    /// A desktop can expose an `AppleSmartBattery` service with `AdapterDetails.FamilyCode = 0`.
    /// BatteryInstalled and the machine model are checked before any charging advice is produced.
    public var isDesktopWithoutBattery: Bool {
        if batteryInstalled == false { return true }
        let model = machineModel?.lowercased() ?? ""
        if ["macmini", "macpro", "macstudio", "imac"].contains(where: { model.contains($0) }) { return true }
        if batteryInstalled == nil, let designCapacity, designCapacity <= 0 { return true }
        return false
    }
}

public enum FindingSeverity: String, Codable, Sendable {
    case info
    case warning
    case problem
}

public struct ChargingFinding: Sendable, Codable, Hashable {
    public var id: String
    public var severity: FindingSeverity
    public var title: String
    public var reason: String
    public var recommendation: String

    public init(id: String, severity: FindingSeverity, title: String, reason: String, recommendation: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.reason = reason
        self.recommendation = recommendation
    }
}

public struct CableSnapshot: Sendable, Codable {
    public var schemaVersion = 1
    public var generatedAt: Date
    public var machineModel: String?
    public var ports: [PortStatus]
    public var cables: [CableSpec]
    public var usbDevices: [USBDeviceNode]
    public var thunderboltDevices: [ThunderboltDevice]
    public var displays: [DisplayInfo]
    public var power: PowerState
    public var findings: [ChargingFinding]

    public init(
        generatedAt: Date = Date(),
        machineModel: String? = nil,
        ports: [PortStatus] = [],
        cables: [CableSpec] = [],
        usbDevices: [USBDeviceNode] = [],
        thunderboltDevices: [ThunderboltDevice] = [],
        displays: [DisplayInfo] = [],
        power: PowerState = PowerState(),
        findings: [ChargingFinding] = []
    ) {
        self.generatedAt = generatedAt
        self.machineModel = machineModel
        self.ports = ports
        self.cables = cables
        self.usbDevices = usbDevices
        self.thunderboltDevices = thunderboltDevices
        self.displays = displays
        self.power = power
        self.findings = findings
    }
}
