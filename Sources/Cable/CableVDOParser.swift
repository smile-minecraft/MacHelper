import Foundation

/// Decodes USB Power Delivery Discover Identity cable VDOs.
///
/// Bit layout (PD 3.1 Table 6.45 "Passive Cable VDO", Table 6.47 "Active Cable VDO1",
/// Table 6.48 "Active Cable VDO2"; unchanged in PD 3.2/3.3):
///
/// ```text
/// 31..28 Hardware Version   27..24 Firmware Version   23..21 VDO Version
/// 20     Reserved           19..18 Plug Type          17     EPR capable
/// 16..13 Cable Latency      12..11 Termination        10..9  Maximum VBUS voltage
/// 8..7   Reserved (passive) / SBU flags (active)
/// 6..5   VBUS current       4      VBUS through cable (active) / reserved (passive)
/// 3      SOP'' controller (active) / reserved (passive)   2..0 USB highest speed
/// ```
///
/// Codes: current 01b = 3 A, 10b = 5 A; voltage 00b = 20 V, 11b = 50 V
/// (01b/10b are deprecated and receivers shall assume 20 V); speed
/// 000b = USB2, 001b = 5 Gbps, 010b = 10 Gbps, 011b = USB4 Gen3 40 Gbps,
/// 100b = USB4 Gen4 80 Gbps. VDO Version is 000b for passive cables and
/// 011b for SVDM 2.1 v1.3 active cables.
public enum CableVDOParser {
    /// Decodes the fourth VDO (index 3) returned by SOP'.
    public static func decode(
        cableVDO: UInt32,
        kind: CableKind = .unknown,
        vendorID: Int? = nil,
        productID: Int? = nil,
        productTypeDescription: String? = nil,
        activeVDO1: UInt32? = nil,
        activeVDO2: UInt32? = nil,
        rawVDOs: [UInt32] = []
    ) -> CableSpec {
        let version = bits(cableVDO, 21...23)
        let expectedVersion = kind == .active ? 3 : 0
        let voltage = decodeVoltage(bits(cableVDO, 9...10))
        let current = decodeCurrent(bits(cableVDO, 5...6))
        let speed = decodeSpeed(bits(cableVDO, 0...2))
        let epr = bit(cableVDO, 17)
        let termination = decodeTermination(bits(cableVDO, 11...12), active: kind == .active)
        let plug = decodePlug(bits(cableVDO, 18...19))
        let latency = decodeLatency(bits(cableVDO, 13...16), active: kind == .active)
        let volts = voltage.negotiableVolts
        let amps = current.amps
        let watts: Int? = {
            guard let volts, let amps else { return nil }
            // EPR cable voltage code 11b means 48 V negotiable (50 V absolute maximum),
            // so a 5 A EPR cable is rated 240 W, not 250 W.
            if voltage == .volts50, current == .amps5 { return 240 }
            return volts * amps
        }()

        var activeDetails: ActiveCableDetails?
        var sbuSupported: Bool?
        var sbuActive: Bool?
        var vbusThroughCable: Bool?
        var sopPrimeController: Bool?
        if kind == .active {
            let vdo1 = activeVDO1 ?? cableVDO
            sbuSupported = bit(vdo1, 8) == 0 ? true : (bit(vdo1, 8) == 1 ? false : nil)
            sbuActive = bit(vdo1, 8) == 0 ? bit(vdo1, 7) == 1 : nil
            vbusThroughCable = bit(vdo1, 4) == 1
            sopPrimeController = bit(vdo1, 3) == 1
            if let vdo2 = activeVDO2 {
                activeDetails = ActiveCableDetails(
                    vdo2: vdo2,
                    maximumOperatingCelsius: Int(bits(vdo2, 24...31)),
                    shutdownCelsius: Int(bits(vdo2, 16...23)),
                    copper: bit(vdo2, 10) == 0,
                    retimer: bit(vdo2, 9) == 1,
                    usb4Supported: bit(vdo2, 8) == 0,
                    usb2Supported: bit(vdo2, 5) == 0,
                    usb3Supported: bit(vdo2, 4) == 0,
                    twoLanes: bit(vdo2, 3) == 1,
                    opticallyIsolated: bit(vdo2, 2) == 1,
                    asymmetricMode: bit(vdo2, 1) == 1,
                    gen2OrHigher: bit(vdo2, 0) == 1
                )
            } else {
                activeDetails = ActiveCableDetails()
            }
        }

        let spec = CableSpec(
            kind: kind,
            vendorID: vendorID,
            productID: productID,
            productTypeDescription: productTypeDescription,
            hardwareVersion: Int(bits(cableVDO, 28...31)),
            firmwareVersion: Int(bits(cableVDO, 24...27)),
            vdoVersion: Int(version),
            vdoVersionIsValid: version == expectedVersion,
            speed: speed,
            current: current,
            voltage: voltage,
            eprCapable: epr == 1,
            latency: latency,
            termination: termination,
            plug: plug,
            sbuSupported: sbuSupported,
            sbuActive: sbuActive,
            vbusThroughCable: vbusThroughCable,
            sopPrimeController: sopPrimeController,
            active: activeDetails,
            rawVDOs: rawVDOs.isEmpty ? [cableVDO] : rawVDOs,
            maxWatts: watts,
            summary: "\(kind.displayName), \(speed.displayName), \(amps.map { "\($0) A" } ?? "current unknown")"
        )
        return spec
    }

    /// Decodes a VDO array in wire order. IORegistry exposes each 4-byte VDO as
    /// little-endian `Data`; index 3 is the cable VDO, index 4/5 active VDO2/3.
    public static func decode(vdos: [Data], kind: CableKind, vendorID: Int?, productID: Int?) -> CableSpec? {
        let words = vdos.compactMap { data -> UInt32? in
            guard data.count >= 4 else { return nil }
            var value: UInt32 = 0
            for byte in data.prefix(4).reversed() { value = (value << 8) | UInt32(byte) }
            return value
        }
        guard words.count > 3 else { return nil }
        let active1: UInt32? = kind == .active && words.count > 4 ? words[4] : nil
        let active2: UInt32? = kind == .active && words.count > 5 ? words[5] : nil
        return decode(
            cableVDO: active1 ?? words[3],
            kind: kind,
            vendorID: vendorID,
            productID: productID,
            activeVDO1: active1,
            activeVDO2: active2,
            rawVDOs: words
        )
    }

    private static func bit(_ value: UInt32, _ position: Int) -> UInt32 {
        (value >> UInt32(position)) & 1
    }

    private static func bits(_ value: UInt32, _ range: ClosedRange<Int>) -> UInt32 {
        let width = UInt32(range.upperBound - range.lowerBound + 1)
        return (value >> UInt32(range.lowerBound)) & ((1 << width) - 1)
    }

    private static func decodeSpeed(_ code: UInt32) -> CableSpeed {
        switch code {
        case 0: return .usb2
        case 1: return .gen1
        case 2: return .gen2
        case 3: return .usb4Gen3
        case 4: return .usb4Gen4
        default: return .unknown
        }
    }

    private static func decodeCurrent(_ code: UInt32) -> CableCurrent {
        switch code {
        case 1: return .amps3
        case 2: return .amps5
        default: return .unknown
        }
    }

    private static func decodeVoltage(_ code: UInt32) -> CableVoltage {
        switch code {
        case 0: return .volts20
        case 1: return .volts30Deprecated
        case 2: return .volts40Deprecated
        case 3: return .volts50
        default: return .unknown
        }
    }

    private static func decodeLatency(_ code: UInt32, active: Bool) -> CableLatency {
        switch code {
        case 1: return .under10ns
        case 2: return .ns10To20
        case 3: return .ns20To30
        case 4: return .ns30To40
        case 5: return .ns40To50
        case 6: return .ns50To60
        case 7: return .ns60To70
        case 8: return active ? .active100ns : .over70ns
        case 9: return active ? .active200ns : .unknown
        case 10: return active ? .active300ns : .unknown
        default: return .unknown
        }
    }

    private static func decodeTermination(_ code: UInt32, active: Bool) -> CableTermination {
        if active {
            switch code {
            case 2: return .oneEndActive
            case 3: return .bothEndsActive
            default: return .unknown
            }
        }
        switch code {
        case 0: return .vconnNotRequired
        case 1: return .vconnRequired
        default: return .unknown
        }
    }

    private static func decodePlug(_ code: UInt32) -> CablePlug {
        switch code {
        case 0: return .typeA
        case 1: return .typeB
        case 2: return .typeC
        case 3: return .captive
        default: return .unknown
        }
    }
}
