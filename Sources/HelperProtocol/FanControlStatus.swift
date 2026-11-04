import FanControl
import Foundation
import SMCKit

/// Snapshot of the Helper's fan control loop, returned to the app.
public struct FanControlStatus: Codable, Sendable, Equatable {
    public struct FanState: Codable, Sendable, Equatable, Identifiable {
        public var id: Int { reading.id }
        public var reading: FanReading
        /// RPM the Helper is commanding; nil = firmware has control.
        public var commandedRPM: Double?

        public init(reading: FanReading, commandedRPM: Double?) {
            self.reading = reading
            self.commandedRPM = commandedRPM
        }
    }

    public var policy: FanPolicy
    public var fans: [FanState]
    /// Temperature the curve is evaluated at (per the policy's source).
    public var controlCelsius: Double?
    public var hottestCelsius: Double?
    /// Where temperatures come from ("hid", "smc", or "none").
    public var sensorSource: String
    /// True while the over-temperature safety valve holds control at the firmware.
    public var safetyTripped: Bool
    public var lastError: String?
    public var strategy: String
    public var canControl: Bool

    public init(policy: FanPolicy, fans: [FanState], controlCelsius: Double?, hottestCelsius: Double?,
                sensorSource: String, safetyTripped: Bool, lastError: String?, strategy: String, canControl: Bool) {
        self.policy = policy
        self.fans = fans
        self.controlCelsius = controlCelsius
        self.hottestCelsius = hottestCelsius
        self.sensorSource = sensorSource
        self.safetyTripped = safetyTripped
        self.lastError = lastError
        self.strategy = strategy
        self.canControl = canControl
    }
}
