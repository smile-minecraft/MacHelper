import FanControl
import Foundation
import HelperProtocol
import Metrics
import os
import SMCKit

private let engineLog = Logger(subsystem: HelperConstants.helperBundleIdentifier, category: "fan")

/// Runs the fan policy inside the root Helper. All state lives on one serial queue.
///
/// Safety rules (not configurable from the app):
/// - every target is clamped to the fan's own min/max (FanDriver + CurveController)
/// - hottest sensor ≥ SafetyLimits.releaseAboveCelsius → firmware control until it drops below resumeBelowCelsius
/// - heartbeat-guarded policies (fixed speed) revert to automatic when the app stops pinging
/// - sleep → firmware control; wake → controllers reset and Ftst re-asserted where needed
/// - SIGTERM / startup after a crash → firmware control (main.swift)
final class FanControlEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.machelper.helper.fan-control")
    private let driver: FanDriver
    private let hid: HIDTemperatureSensors?
    private let smcGPUKeys: [FourCC]
    /// SMC temperature keys, used when HID sensors are unavailable to the daemon.
    private let smcTemperatureKeys: [FourCC]
    private var sensorSource = "none"
    private let limits = SafetyLimits.standard
    private let tickInterval: TimeInterval = 1

    private var policy: FanPolicy = .automatic
    private var controllers: [Int: CurveController] = [:]
    private var commanded: [Int: Double] = [:]
    private var lastHeartbeat = Date()
    private var lastTick = Date()
    private var safetyTripped = false
    private var asleep = false
    private var lastError: String?
    private var lastControlCelsius: Double?
    private var lastHottest: Double?
    private var timer: DispatchSourceTimer?

    private static let policyURL = URL(fileURLWithPath: "/Library/Application Support/MacHelper/fan-policy.json")

    init(driver: FanDriver) {
        self.driver = driver
        hid = HIDTemperatureSensors()
        let keys = SMCTemperatures.discoverKeys(driver.smc)
        smcTemperatureKeys = keys
        smcGPUKeys = keys.filter { SMCTemperatures.category(for: $0) == .gpu }
        engineLog.notice("Temperature sensors: HID \(self.hid == nil ? "unavailable" : "ok", privacy: .public), SMC keys \(keys.count, privacy: .public)")
    }

    // MARK: Lifecycle

    func start() {
        queue.sync {
            if let saved = Self.loadPolicy() {
                // A fixed speed needs a live app; never resurrect it without one.
                policy = saved.requiresHeartbeat ? .automatic : saved
                engineLog.notice("Loaded persisted policy: \(String(describing: self.policy.mode), privacy: .public)")
            }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + tickInterval, repeating: tickInterval, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    // MARK: XPC entry points

    func apply(_ newPolicy: FanPolicy) throws {
        let validated = try newPolicy.validated()
        try queue.sync {
            guard driver.strategy.canControl || validated.mode == .automatic else {
                throw FanPolicyError.invalid("this Mac's fans cannot be controlled (\(driver.strategy))")
            }
            policy = validated
            controllers.removeAll()
            lastHeartbeat = Date()
            lastError = nil
            Self.savePolicy(validated)
            engineLog.notice("Applied policy: \(String(describing: validated.mode), privacy: .public)")
            tick()
        }
    }

    func heartbeat() {
        queue.async { self.lastHeartbeat = Date() }
    }

    func status() -> FanControlStatus {
        queue.sync {
            FanControlStatus(
                policy: policy,
                fans: driver.readFans().map { .init(reading: $0, commandedRPM: commanded[$0.id]) },
                controlCelsius: lastControlCelsius,
                hottestCelsius: lastHottest,
                sensorSource: sensorSource,
                safetyTripped: safetyTripped,
                lastError: lastError,
                strategy: driver.strategy.description,
                canControl: driver.strategy.canControl
            )
        }
    }

    func willSleep() {
        queue.sync {
            asleep = true
            releaseAll(reason: "system sleep")
        }
    }

    func didWake() {
        queue.async {
            self.asleep = false
            self.controllers.removeAll()
            self.lastTick = Date()
            engineLog.notice("Wake: resuming policy")
            self.tick()
        }
    }

    // MARK: Control loop (queue only)

    private func tick() {
        guard !asleep else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        let temps = readTemperatures()
        let hottest = temps.map(\.celsius).max()
        lastHottest = hottest

        // Safety valve with hysteresis.
        if let h = hottest {
            if !safetyTripped, h >= limits.releaseAboveCelsius {
                safetyTripped = true
                engineLog.notice("Safety valve: \(h, privacy: .public) °C, handing fans to firmware")
            } else if safetyTripped, h < limits.resumeBelowCelsius {
                safetyTripped = false
                controllers.removeAll()
            }
        }

        // Heartbeat guard.
        if policy.requiresHeartbeat, now.timeIntervalSince(lastHeartbeat) > HelperTiming.heartbeatTimeout {
            lastError = "App heartbeat lost; fans returned to automatic"
            engineLog.notice("Heartbeat lost; reverting to automatic")
            policy = .automatic
            Self.savePolicy(policy)
        }

        if safetyTripped || policy.mode == .automatic {
            lastControlCelsius = nil
            releaseAll(reason: nil)
            return
        }

        let fans = driver.readFans()
        switch policy.mode {
        case .automatic:
            break
        case .fixed(let fraction):
            lastControlCelsius = nil
            for f in fans {
                command(fan: f, rpm: f.minRPM + fraction * (f.maxRPM - f.minRPM))
            }
        case .curve(let settings):
            let source = sourceTemperature(settings.source, temps: temps)
            lastControlCelsius = source
            for f in fans {
                var controller = controllers[f.id] ?? CurveController(settings: settings, limits: limits)
                let cmd = controller.step(FanTickInput(
                    sourceCelsius: source ?? .nan,
                    hottestCelsius: hottest ?? .nan,
                    fanMinRPM: f.minRPM, fanMaxRPM: f.maxRPM,
                    // While we hold the fan, F0Tg is our own value, not the firmware's request.
                    firmwareTargetRPM: commanded[f.id] == nil && f.mode == .automatic ? f.targetRPM : nil,
                    dt: dt))
                controllers[f.id] = controller
                switch cmd {
                case .automatic: release(fan: f.id)
                case .manual(let rpm): command(fan: f, rpm: rpm)
                }
            }
        }
    }

    private func readTemperatures() -> [TemperatureReading] {
        if let h = hid?.read(), !h.isEmpty {
            sensorSource = "hid"
            return h
        }
        let smc = SMCTemperatures.read(driver.smc, keys: smcTemperatureKeys)
        sensorSource = smc.isEmpty ? "none" : "smc"
        return smc
    }

    private func sourceTemperature(_ source: TemperatureSource, temps: [TemperatureReading]) -> Double? {
        let cpu = temps.filter { $0.category == .cpu }.map(\.celsius).max()
        let hottest = temps.map(\.celsius).max()
        switch source {
        case .cpu: return cpu ?? hottest
        case .gpu:
            let gpuHID = temps.filter { $0.category == .gpu }.map(\.celsius).max()
            let gpuSMC = SMCTemperatures.read(driver.smc, keys: smcGPUKeys).map(\.celsius).max()
            return gpuHID ?? gpuSMC ?? hottest
        case .hottest: return hottest
        }
    }

    private func command(fan: FanReading, rpm: Double) {
        // Skip redundant SMC writes; re-write if the firmware took the fan back (e.g. after wake).
        if let last = commanded[fan.id], abs(last - rpm) < 10, fan.mode == .manual { return }
        do {
            try driver.setManual(fan: fan.id, rpm: rpm)
            commanded[fan.id] = rpm
        } catch {
            lastError = "Fan \(fan.id): \(error)"
            engineLog.error("setManual failed: \(String(describing: error), privacy: .public)")
            release(fan: fan.id)
        }
    }

    private func release(fan: Int) {
        guard commanded[fan] != nil else { return }
        do {
            try driver.setAutomatic(fan: fan)
        } catch {
            lastError = "Fan \(fan): \(error)"
        }
        commanded[fan] = nil
    }

    private func releaseAll(reason: String?) {
        guard !commanded.isEmpty else { return }
        if let reason { engineLog.notice("Releasing fans: \(reason, privacy: .public)") }
        driver.restoreAllAutomatic()
        commanded.removeAll()
        controllers.removeAll()
    }

    // MARK: Persistence

    private static func loadPolicy() -> FanPolicy? {
        guard let data = try? Data(contentsOf: policyURL) else { return nil }
        return try? JSONDecoder().decode(FanPolicy.self, from: data).validated()
    }

    private static func savePolicy(_ policy: FanPolicy) {
        do {
            try FileManager.default.createDirectory(at: policyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(policy).write(to: policyURL, options: .atomic)
        } catch {
            engineLog.error("Could not persist policy: \(String(describing: error), privacy: .public)")
        }
    }
}
