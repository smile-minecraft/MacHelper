import CoreWLAN
import Foundation

/// The Wi-Fi link as CoreWLAN reports it. The network name needs Location Services permission
/// on current macOS, so `ssid` is usually nil; signal, noise and rate do not need it.
public struct WiFiReading: Sendable, Hashable {
    public var interfaceName: String
    public var isPoweredOn: Bool
    public var ssid: String?
    /// dBm; nil when not associated.
    public var rssi: Int?
    public var noise: Int?
    /// Current transmit rate in Mbps.
    public var transmitRateMbps: Double?
    public var standard: WiFiStandard?

    public var isAssociated: Bool { rssi != nil }

    public enum Quality: Sendable, Hashable { case excellent, good, fair, weak }

    /// Usual RSSI bands: -55 dBm and above is excellent, below -75 dBm is weak.
    public var quality: Quality? {
        guard let rssi else { return nil }
        switch rssi {
        case (-55)...: return .excellent
        case (-67)...: return .good
        case (-75)...: return .fair
        default: return .weak
        }
    }
}

public enum WiFiStandard: Int, Sendable, Hashable {
    case a = 1, b, g, n, ac, ax, be

    /// "Wi-Fi 6 (802.11ax)"; the older letters have no generation name.
    public var title: String {
        switch self {
        case .a: "802.11a"
        case .b: "802.11b"
        case .g: "802.11g"
        case .n: "Wi-Fi 4 (802.11n)"
        case .ac: "Wi-Fi 5 (802.11ac)"
        case .ax: "Wi-Fi 6 (802.11ax)"
        case .be: "Wi-Fi 7 (802.11be)"
        }
    }
}

public enum WiFiSampler {
    /// nil on a Mac without Wi-Fi hardware.
    public static func sample() -> WiFiReading? {
        guard let i = CWWiFiClient.shared().interface(), let name = i.interfaceName else { return nil }
        let on = i.powerOn()
        let rssi = i.rssiValue()
        let associated = on && rssi != 0
        let rate = i.transmitRate()
        let ssid = i.ssid()
        return WiFiReading(interfaceName: name,
                           isPoweredOn: on,
                           ssid: ssid?.isEmpty == false ? ssid : nil,
                           rssi: associated ? rssi : nil,
                           noise: associated && i.noiseMeasurement() != 0 ? i.noiseMeasurement() : nil,
                           transmitRateMbps: associated && rate > 0 ? rate : nil,
                           standard: associated ? WiFiStandard(rawValue: i.activePHYMode().rawValue) : nil)
    }
}
