import Cable
import Foundation
import IOKit
import Observation

/// Value-comparable projection of `CableSnapshot` excluding `generatedAt`, so SwiftUI only
/// invalidates when ports, cables, devices, displays, power or diagnostic findings actually change.
struct CableSnapshotContent: Equatable, Sendable {
    var machineModel: String?
    var ports: [PortStatus]
    var cables: [CableSpec]
    var usbDevices: [USBDeviceNode]
    var thunderboltDevices: [ThunderboltDevice]
    var displays: [DisplayInfo]
    var power: PowerState
    var findings: [ChargingFinding]

    init(snapshot: CableSnapshot) {
        machineModel = snapshot.machineModel
        ports = snapshot.ports.sorted { lhs, rhs in
            let l = lhs.number ?? Int.max
            let r = rhs.number ?? Int.max
            if l != r { return l < r }
            return lhs.id < rhs.id
        }
        cables = snapshot.cables
        usbDevices = snapshot.usbDevices
        thunderboltDevices = snapshot.thunderboltDevices.sorted { lhs, rhs in
            let l = lhs.portNumber ?? Int.max
            let r = rhs.portNumber ?? Int.max
            if l != r { return l < r }
            return lhs.name < rhs.name
        }
        displays = snapshot.displays.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id < rhs.id
        }
        // Desktop Macs without a battery do not render live system power draw here; clearing
        // fluctuating raw telemetry avoids pointless redraws when nothing hardware-wise changed.
        var normalizedPower = snapshot.power
        if normalizedPower.isDesktopWithoutBattery {
            normalizedPower.systemPowerInWatts = nil
        }
        power = normalizedPower
        findings = Self.sortFindings(snapshot.findings)
    }

    static func sortFindings(_ items: [ChargingFinding]) -> [ChargingFinding] {
        items.enumerated()
            .sorted { lhs, rhs in
                let lr = severityRank(lhs.element.severity)
                let rr = severityRank(rhs.element.severity)
                if lr != rr { return lr < rr }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func severityRank(_ severity: FindingSeverity) -> Int {
        switch severity {
        case .problem: 0
        case .warning: 1
        case .info: 2
        }
    }

    var connectedPorts: [PortStatus] {
        ports.filter { $0.connected == true }
    }

    var unconnectedPorts: [PortStatus] {
        ports.filter { $0.connected != true }
    }

    var usbDeviceCount: Int {
        Self.countDevices(usbDevices)
    }

    private static func countDevices(_ nodes: [USBDeviceNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + countDevices($1.children) }
    }

    /// Highest rated connected e-marked cable for the summary header.
    var strongestConnectedCable: CableSpec? {
        connectedPorts.compactMap(\.cable)
            .filter { $0.kind == .passive || $0.kind == .active }
            .max { lhs, rhs in
                let lw = lhs.maxWatts ?? 0
                let rw = rhs.maxWatts ?? 0
                if lw != rw { return lw < rw }
                return (lhs.speed.gigabitsPerSecond ?? 0) < (rhs.speed.gigabitsPerSecond ?? 0)
            }
    }
}

/// Shared pure helpers for Cable UI formatting and bottleneck rules.
enum CableFormatting {
    /// Only flags a USB device when the descriptor proves USB 3 capability (`maxSpeedMbps` is
    /// non-nil and >= 5 Gbps) yet the negotiated link fell back to USB 2.0 or slower.
    /// `maxSpeedMbps == nil` means capability is unknown and is never flagged.
    static func isSpeedBelowCapability(_ node: USBDeviceNode) -> Bool {
        guard let maximum = node.maxSpeedMbps,
              let negotiated = node.negotiatedSpeedMbps,
              maximum >= 5_000,
              negotiated <= 480 else { return false }
        return negotiated < maximum
    }

    static func usbSpeed(_ mbps: Int?) -> String {
        guard let mbps else { return String(localized: "Speed unknown") }
        if mbps >= 1_000 {
            if mbps % 1_000 == 0 {
                return "\(mbps / 1_000) Gbps"
            }
            return String(format: "%.1f Gbps", Double(mbps) / 1_000.0)
        }
        return "\(mbps) Mbps"
    }

    static func hexID(_ value: Int) -> String {
        String(format: "0x%04X", value & 0xFFFF)
    }

    static func refreshRate(_ hz: Double) -> String {
        if abs(hz - hz.rounded()) < 0.05 {
            return "\(Int(hz.rounded())) Hz"
        }
        return String(format: "%.1f Hz", hz)
    }

    static func cableKindLabel(_ kind: CableKind) -> String {
        switch kind {
        case .passive: String(localized: "Passive cable")
        case .active: String(localized: "Active cable")
        case .absent: String(localized: "No e-marker")
        case .unknown: String(localized: "Unknown cable")
        }
    }

    static func cableSpeedLabel(_ speed: CableSpeed) -> String {
        switch speed {
        case .unknown: String(localized: "Unknown")
        case .usb2: "USB 2.0"
        case .gen1: "USB 3.2 Gen1 (5 Gbps)"
        case .gen2: "USB 3.2 / USB4 Gen2 (10 Gbps)"
        case .usb4Gen3: "USB4 Gen3 (40 Gbps)"
        case .usb4Gen4: "USB4 Gen4 (80 Gbps)"
        }
    }

    static func cableCurrentLabel(_ current: CableCurrent) -> String? {
        guard let amps = current.amps else { return nil }
        return "\(amps) A"
    }

    static func cableVoltageLabel(_ voltage: CableVoltage) -> String? {
        guard let volts = voltage.negotiableVolts else { return nil }
        return "\(volts) V"
    }

    static func cablePlugLabel(_ plug: CablePlug) -> String? {
        switch plug {
        case .typeC: "USB-C"
        case .typeA: "USB-A"
        case .typeB: "USB-B"
        case .captive: String(localized: "Captive")
        case .unknown: nil
        }
    }

    static func cableLatencyLabel(_ latency: CableLatency) -> String? {
        latency == .unknown ? nil : latency.displayName
    }

    static func orientationLabel(_ orientation: PlugOrientation) -> String? {
        switch orientation {
        case .normal: String(localized: "Normal")
        case .flipped: String(localized: "Flipped")
        case .unknown: nil
        }
    }

    static func transportLabel(_ transport: Transport) -> String {
        switch transport {
        case .cc: "USB-C PD"
        case .usb2: "USB 2"
        case .usb3: "USB 3"
        case .cio: "Thunderbolt / USB4"
        case .displayPort: "DisplayPort"
        case .pcie: "PCIe"
        case .other: String(localized: "Other")
        }
    }

    static func portDisplayTitle(_ port: PortStatus) -> String {
        if let number = port.number {
            return String(localized: "Port \(number)")
        }
        return port.id
    }

    static func thunderboltCodes(_ device: ThunderboltDevice) -> String? {
        var parts: [String] = []
        if let gen = device.generation {
            parts.append(String(localized: "Generation code \(gen)"))
        }
        if let speed = device.cableSpeed {
            parts.append(String(localized: "Cable speed code \(speed)"))
        }
        if let cableGen = device.cableGeneration {
            parts.append(String(localized: "Cable generation code \(cableGen)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Manages background cable snapshots, IOKit hot-plug triggers, and visibility-gated polling.
/// Stops all sampling and releases IOKit notification ports immediately when the page is hidden.
@MainActor
@Observable
final class CableModel {
    private(set) var content: CableSnapshotContent?
    private(set) var loading = false
    private(set) var refreshing = false
    private(set) var isMonitoring = false

    /// Instrumentation counters (non-observed so reading or bumping them never forces a view redraw).
    @ObservationIgnored private(set) var snapshotCallCount = 0
    @ObservationIgnored private(set) var appliedUpdateCount = 0

    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let useIOKitNotifications: Bool
    @ObservationIgnored private let reader: @Sendable () -> CableSnapshot
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: IOKitCableWatcher?
    @ObservationIgnored private var isInFlight = false
    @ObservationIgnored private var pendingRefresh = false

    init(
        pollInterval: Duration = .seconds(3),
        useIOKitNotifications: Bool = true,
        reader: @escaping @Sendable () -> CableSnapshot = { CableReader.snapshot() }
    ) {
        self.pollInterval = pollInterval
        self.useIOKitNotifications = useIOKitNotifications
        self.reader = reader
    }

    func setVisible(_ visible: Bool) {
        guard visible != isMonitoring else { return }
        isMonitoring = visible
        if visible {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    func refreshNow() {
        Task { await performSample(userInitiated: true) }
    }

    // MARK: - Private lifecycle

    private func startMonitoring() {
        if useIOKitNotifications {
            let watcher = IOKitCableWatcher { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleHotPlugRefresh()
                }
            }
            watcher.start()
            self.watcher = watcher
        }

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.performSample(userInitiated: false)
            while !Task.isCancelled, self.isMonitoring {
                do {
                    try await Task.sleep(for: self.pollInterval)
                } catch {
                    break
                }
                guard !Task.isCancelled, self.isMonitoring else { break }
                await self.performSample(userInitiated: false)
            }
        }
    }

    private func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        watcher?.stop()
        watcher = nil
        pendingRefresh = false
        refreshing = false
        loading = false
    }

    private func scheduleHotPlugRefresh() {
        guard isMonitoring else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.isMonitoring else { return }
            await self.performSample(userInitiated: false)
        }
    }

    private func performSample(userInitiated: Bool) async {
        guard isMonitoring || userInitiated else { return }
        if isInFlight {
            pendingRefresh = true
            return
        }
        isInFlight = true
        if content == nil { loading = true }
        if userInitiated { refreshing = true }

        defer {
            isInFlight = false
            loading = false
            refreshing = false
            if pendingRefresh, isMonitoring {
                pendingRefresh = false
                Task { [weak self] in
                    await self?.performSample(userInitiated: false)
                }
            }
        }

        snapshotCallCount += 1
        let reader = self.reader
        let snapshot = await Self.captureOffMain(reader)
        guard !Task.isCancelled else { return }
        guard isMonitoring || userInitiated else { return }
        apply(snapshot)
    }

    private nonisolated static func captureOffMain(_ reader: @escaping @Sendable () -> CableSnapshot) async -> CableSnapshot {
        await Task.detached(priority: .utility) { reader() }.value
    }

    @discardableResult
    func apply(_ snapshot: CableSnapshot) -> Bool {
        let next = CableSnapshotContent(snapshot: snapshot)
        guard next != content else { return false }
        content = next
        appliedUpdateCount += 1
        return true
    }
}

/// Lightweight IOKit observer for USB device and USB-C port attach/detach events.
/// All IOKit objects are owned and torn down on a single serial dispatch queue.
private final class IOKitCableWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.machelper.cable.iokit", qos: .utility)
    private let onChange: @Sendable () -> Void
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var stopped = false

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            guard !stopped, notifyPort == nil else { return }
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            notifyPort = port
            IONotificationPortSetDispatchQueue(port, queue)

            let classes = ["IOUSBHostDevice", "IOPortTransportStateCC"]
            let types = [kIOMatchedNotification, kIOTerminatedNotification]
            let refCon = Unmanaged.passUnretained(self).toOpaque()

            for className in classes {
                for notificationType in types {
                    guard let matching = IOServiceMatching(className) else { continue }
                    var iterator = io_iterator_t(0)
                    let result = IOServiceAddMatchingNotification(
                        port,
                        notificationType,
                        matching,
                        Self.callback,
                        refCon,
                        &iterator
                    )
                    if result == KERN_SUCCESS {
                        Self.drain(iterator)
                        iterators.append(iterator)
                    }
                }
            }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            for iterator in iterators {
                IOObjectRelease(iterator)
            }
            iterators.removeAll()
            if let port = notifyPort {
                IONotificationPortSetDispatchQueue(port, nil)
                IONotificationPortDestroy(port)
                notifyPort = nil
            }
        }
    }

    deinit {
        if notifyPort != nil || !iterators.isEmpty {
            for iterator in iterators { IOObjectRelease(iterator) }
            if let port = notifyPort {
                IONotificationPortSetDispatchQueue(port, nil)
                IONotificationPortDestroy(port)
            }
        }
    }

    private static let callback: IOServiceMatchingCallback = { refCon, iterator in
        IOKitCableWatcher.drain(iterator)
        guard let refCon else { return }
        let watcher = Unmanaged<IOKitCableWatcher>.fromOpaque(refCon).takeUnretainedValue()
        guard !watcher.stopped else { return }
        watcher.onChange()
    }

    private static func drain(_ iterator: io_iterator_t) {
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            IOObjectRelease(entry)
        }
    }
}
