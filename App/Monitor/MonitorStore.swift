import Foundation
import Metrics
import Observation
import SMCKit
import Storage

/// All hardware samplers, created once. Sampling runs off the main actor.
final class MetricSources: @unchecked Sendable {
    let smc: SMC?
    let cpu = CPUSampler()
    let power: PowerSampler?
    let hid = HIDTemperatureSensors()
    let network = NetworkSampler()
    let disk = DiskSampler()
    let fans: FanDriver?
    let smcTemperatureKeys: [FourCC]

    init() {
        let smc = try? SMC()
        self.smc = smc
        power = PowerSampler(smc: smc)
        fans = smc.map { FanDriver(smc: $0) }
        // Intel has no HID temperature sensors; fall back to SMC keys there.
        smcTemperatureKeys = (smc != nil && !ChipFamily.current.isAppleSilicon) ? SMCTemperatures.discoverKeys(smc!) : []
    }

    func isAvailable(_ m: MonitorModule) -> Bool {
        switch m {
        case .battery: BatterySampler.sample() != nil
        case .fan: (fans?.strategy.fanCount ?? 0) > 0
        case .power: power != nil || smc?.keyExists("PSTR") == true
        case .temperature: hid != nil || !smcTemperatureKeys.isEmpty
        default: true
        }
    }

    func sample(_ m: MonitorModule) -> ModuleSample? {
        switch m {
        case .cpu: cpu.sample().map(ModuleSample.cpu)
        case .gpu: GPUSampler.sample().first.map(ModuleSample.gpu)
        case .memory: MemorySampler.sample().map(ModuleSample.memory)
        case .disk: disk.sample().map(ModuleSample.disk)
        case .network: network.sample().map(ModuleSample.network)
        case .battery: BatterySampler.sample().map(ModuleSample.battery)
        case .fan: fans.map { .fan($0.readFans()) }
        case .power: power?.sample().map(ModuleSample.power)
        case .temperature:
            if let hid { .temperature(hid.read()) }
            else if let smc { .temperature(SMCTemperatures.read(smc, keys: smcTemperatureKeys)) }
            else { nil }
        }
    }
}

enum ModuleSample: Sendable {
    case cpu(CPUReading)
    case gpu(GPUReading)
    case memory(MemoryReading)
    case disk(DiskReading)
    case network(NetworkReading)
    case battery(BatteryReading)
    case temperature([TemperatureReading])
    case fan([FanReading])
    case power(PowerReading)
}

enum SeriesKey: String, CaseIterable, Sendable {
    case cpu, cpuP, cpuE, gpu, memory, diskRead, diskWrite, netIn, netOut, battery, temperature, fan, power

    /// Column in the persistent minute history, if the series is kept there.
    var historyColumn: String? {
        switch self {
        case .cpu: "cpu"
        case .gpu: "gpu"
        case .memory: "memory"
        case .diskRead: "diskRead"
        case .diskWrite: "diskWrite"
        case .netIn: "networkIn"
        case .netOut: "networkOut"
        case .battery: "battery"
        case .temperature: "temperature"
        case .fan: "fan"
        case .power: "power"
        case .cpuP, .cpuE: nil
        }
    }
}

struct ChartPoint: Hashable, Sendable {
    let date: Date
    let value: Double
}

/// Latest readings plus one hour of in-memory history per series.
/// (24 h / 7 d history comes with the GRDB Storage module.)
@MainActor
@Observable
final class MonitorStore {
    private(set) var cpu: CPUReading?
    private(set) var gpu: GPUReading?
    private(set) var memory: MemoryReading?
    private(set) var disk: DiskReading?
    private(set) var network: NetworkReading?
    private(set) var battery: BatteryReading?
    private(set) var temperatures: [TemperatureReading] = []
    private(set) var fans: [FanReading] = []
    private(set) var power: PowerReading?
    private(set) var history: [SeriesKey: [ChartPoint]] = [:]
    private(set) var processes: ProcessSnapshot?
    @ObservationIgnored private let processSampler = ProcessSampler()
    /// Persistent per-minute history (nil if the database can't be opened).
    @ObservationIgnored let persistentHistory: MetricsHistory? = try? MetricsHistory()
    @ObservationIgnored private var minute = MinuteAccumulator()
    @ObservationIgnored let alerts = AlertCenter()
    @ObservationIgnored private var processTask: Task<Void, Never>?

    let settings: MonitorSettingsStore
    let availableModules: Set<MonitorModule>
    @ObservationIgnored private let sources: MetricSources
    @ObservationIgnored private var tasks: [MonitorModule: (config: ModuleConfig, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private static let historyWindow: TimeInterval = 3600

    init(settings: MonitorSettingsStore, sources: MetricSources = MetricSources()) {
        self.settings = settings
        self.sources = sources
        availableModules = Set(MonitorModule.allCases.filter(sources.isAvailable))
        reconfigure()
        observeSettings()
    }

    /// Hottest CPU-die sensor, the number shown for "temperature".
    var cpuCelsius: Double? {
        temperatures.filter { $0.category == .cpu }.map(\.celsius).max()
    }

    var hottestCelsius: Double? { temperatures.map(\.celsius).max() }

    func isActive(_ m: MonitorModule) -> Bool {
        availableModules.contains(m) && settings[m].enabled
    }

    // MARK: Sampling lifecycle

    private func observeSettings() {
        withObservationTracking {
            _ = settings.configuration
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reconfigure()
                self?.observeSettings()
            }
        }
    }

    /// Starts, stops or restarts module loops so that exactly the enabled modules are sampled.
    func reconfigure() {
        for m in MonitorModule.allCases {
            let config = settings[m]
            let shouldRun = config.enabled && availableModules.contains(m)
            if let running = tasks[m], !shouldRun || running.config.interval != config.interval {
                running.task.cancel()
                tasks[m] = nil
            }
            if shouldRun, tasks[m] == nil {
                tasks[m] = (config, startLoop(m, interval: max(config.interval, 0.5)))
            }
        }
    }

    @ObservationIgnored private var processWatchers = 0

    /// Keeps rows from swapping places on every sample: a process already listed holds its place unless
    /// another one is clearly ahead (25 % more, plus a small absolute margin).
    private func stabilized(_ new: ProcessSnapshot) -> ProcessSnapshot {
        func rank(_ items: [ProcessUsage], previous: [ProcessUsage]?, value: (ProcessUsage) -> Double, margin: Double) -> [ProcessUsage] {
            let incumbents = Set(previous?.map(\.pid) ?? [])
            func score(_ p: ProcessUsage) -> Double { incumbents.contains(p.pid) ? value(p) * 1.25 + margin : value(p) }
            let position = Dictionary(uniqueKeysWithValues: (previous ?? []).enumerated().map { ($1.pid, $0) })
            return Array(items.sorted { a, b in
                let sa = score(a), sb = score(b)
                if abs(sa - sb) < margin, let pa = position[a.pid], let pb = position[b.pid] { return pa < pb }
                return sa > sb
            }.prefix(10))
        }
        return ProcessSnapshot(byCPU: rank(new.byCPU, previous: processes?.byCPU, value: \.cpu, margin: 0.02),
                               byMemory: rank(new.byMemory, previous: processes?.byMemory, value: { Double($0.memoryBytes) }, margin: 20_000_000),
                               hiddenCount: new.hiddenCount)
    }

    /// Per-process sampling runs only while someone looks at it (panel open, overview or monitor shown).
    /// Calls are counted: every `true` needs a matching `false`.
    func watchProcesses(_ on: Bool) {
        processWatchers = max(processWatchers + (on ? 1 : -1), 0)
        if processWatchers == 0 {
            processTask?.cancel()
            processTask = nil
            return
        }
        guard processTask == nil else { return }
        let sampler = processSampler
        processTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await Task.detached(priority: .utility) { sampler.sample(top: 20) }.value
                guard let self, !Task.isCancelled else { return }
                self.processes = self.stabilized(snapshot)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func startLoop(_ m: MonitorModule, interval: Double) -> Task<Void, Never> {
        let sources = sources
        return Task { [weak self] in
            while !Task.isCancelled {
                let sample = await Task.detached(priority: .utility) { sources.sample(m) }.value
                guard let self, !Task.isCancelled else { return }
                if let sample { self.apply(sample) }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func apply(_ sample: ModuleSample) {
        let now = Date()
        switch sample {
        case .cpu(let r):
            cpu = r
            record(.cpu, r.total, now)
            if let p = r.performance { record(.cpuP, p, now) }
            if let e = r.efficiency { record(.cpuE, e, now) }
        case .gpu(let r):
            gpu = r
            record(.gpu, r.utilization, now)
        case .memory(let r):
            memory = r
            alerts.check(cpuCelsius: nil, memory: r, disk: nil)
            if r.totalBytes > 0 { record(.memory, Double(r.usedBytes) / Double(r.totalBytes), now) }
        case .disk(let r):
            disk = r
            alerts.check(cpuCelsius: nil, memory: nil, disk: r)
            record(.diskRead, r.readBytesPerSecond, now)
            record(.diskWrite, r.writeBytesPerSecond, now)
        case .network(let r):
            network = r
            record(.netIn, r.inBytesPerSecond, now)
            record(.netOut, r.outBytesPerSecond, now)
        case .battery(let r):
            battery = r
            record(.battery, r.charge, now)
        case .temperature(let r):
            temperatures = r
            alerts.check(cpuCelsius: cpuCelsius, memory: nil, disk: nil)
            if let c = cpuCelsius { record(.temperature, c, now) }
        case .fan(let r):
            fans = r
            if let f = r.first { record(.fan, f.actualRPM, now) }
        case .power(let r):
            power = r
            if let w = r.systemWatts ?? r.gpuWatts { record(.power, w, now) }
        }
    }

    private func record(_ key: SeriesKey, _ value: Double, _ date: Date) {
        var points = history[key, default: []]
        points.append(ChartPoint(date: date, value: value))
        let cutoff = date.addingTimeInterval(-Self.historyWindow)
        if let first = points.first, first.date < cutoff {
            points.removeAll { $0.date < cutoff }
        }
        history[key] = points
        if let column = key.historyColumn, let finished = minute.add(column, value, at: date), let db = persistentHistory {
            Task.detached(priority: .background) { try? db.append(finished) }
        }
    }
}
