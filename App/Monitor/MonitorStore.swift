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
    private let keyLock = NSLock()
    private var discoveredKeys: [FourCC]?

    /// Walking the SMC key table is slow, so it happens on first use, which is a sample taken
    /// off the main actor. On Apple Silicon `isAvailable` never needs it because HID exists.
    var smcTemperatureKeys: [FourCC] {
        keyLock.withLock {
            if let discoveredKeys { return discoveredKeys }
            let keys = smc.map { SMCTemperatures.discoverKeys($0) } ?? []
            discoveredKeys = keys
            return keys
        }
    }

    init() {
        let smc = try? SMC()
        self.smc = smc
        power = PowerSampler(smc: smc)
        fans = smc.map { FanDriver(smc: $0) }
        // HID is preferred when it works; when it does not, both writers fall back to the
        // same discovered SMC keys, so the stored temperature column keeps one meaning.
        // Discovery is deferred to `smcTemperatureKeys`.
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
        case .cpu: return cpu.sample().map(ModuleSample.cpu)
        case .gpu: return GPUSampler.sample().first.map(ModuleSample.gpu)
        case .memory: return MemorySampler.sample().map(ModuleSample.memory)
        case .disk: return disk.sample().map(ModuleSample.disk)
        case .network: return network.sample().map(ModuleSample.network)
        case .battery: return BatterySampler.sample().map(ModuleSample.battery)
        case .fan: return fans.map { .fan($0.readFans()) }
        case .power: return power?.sample().map(ModuleSample.power)
        case .temperature:
            // One merge rule shared with the background recorder: HID first, SMC GPU keys
            // only when HID has no GPU category, and never the same name twice.
            return TemperatureSources.readings(hid: hid, smc: smc, smcKeys: smcTemperatureKeys)
                .map(ModuleSample.temperature)
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
    @ObservationIgnored let persistentHistory: MetricsHistory? = {
        do {
            return try MetricsHistory()
        } catch {
            NSLog("MacHelper history database unavailable: %@", error.localizedDescription)
            return nil
        }
    }()
    @ObservationIgnored private var minute = MinuteAccumulator()
    @ObservationIgnored let alerts = AlertCenter()
    @ObservationIgnored private var processTask: Task<Void, Never>?
    @ObservationIgnored private var processHistoryTask: Task<Void, Never>?
    @ObservationIgnored private var seriesSwitchTask: Task<Void, Never>?
    @ObservationIgnored private var seriesMinute = SeriesMinuteAccumulator()
    @ObservationIgnored private var seriesCollectionEnabled = false

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
        startProcessHistoryCollection()
        startSeriesCollection()
    }

    /// Hottest CPU-die sensor, the number shown for "temperature".
    var cpuCelsius: Double? {
        MonitorHistorySample.cpuCelsius(temperatures)
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

    /// Process history is collected whether or not a view is open. Each cycle re-reads the
    /// shared switch from the database; while it is off the sampler is never called, so no
    /// process name is read at all.
    private func startProcessHistoryCollection() {
        guard let db = persistentHistory, let store = try? HistoryStore(readOnly: true) else { return }
        processHistoryTask = Task.detached(priority: .utility) {
            var accumulator = ProcessMinuteAccumulator()
            let sampler = ProcessSampler()
            while !Task.isCancelled {
                if (try? store.isProcessCollectionEnabled()) == true {
                    let readings = Self.processReadings(sampler.sample(top: 20))
                    if let finished = accumulator.add(readings) {
                        do {
                            try db.recordProcessMinute(finished)
                        } catch {
                            NSLog("MacHelper process history write failed: %@", error.localizedDescription)
                        }
                    }
                } else {
                    accumulator = ProcessMinuteAccumulator()
                }
                try? await Task.sleep(for: .seconds(MonitorAgentRecorder.processSampleInterval))
            }
        }
    }

    /// The series switch lives in the shared database. It is polled on the same cadence as
    /// the process switch; once it is off the open minute is dropped, and the store refuses
    /// a series write inside its transaction, so a stale flag cannot persist anything.
    private func startSeriesCollection() {
        guard persistentHistory != nil, let store = try? HistoryStore(readOnly: true) else { return }
        seriesSwitchTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let enabled = (try? store.isSeriesCollectionEnabled()) == true
                await self?.setSeriesCollectionEnabled(enabled)
                try? await Task.sleep(for: .seconds(MonitorAgentRecorder.processSampleInterval))
            }
        }
    }

    private func setSeriesCollectionEnabled(_ enabled: Bool) {
        guard enabled != seriesCollectionEnabled else { return }
        seriesCollectionEnabled = enabled
        if !enabled { seriesMinute = SeriesMinuteAccumulator() }
    }

    private nonisolated static func processReadings(_ snapshot: ProcessSnapshot) -> ProcessUsageReadings {
        func reading(_ usage: ProcessUsage) -> ProcessUsageReading {
            ProcessUsageReading(pid: usage.pid, name: usage.name, cpu: usage.cpu, memoryBytes: usage.memoryBytes)
        }
        return ProcessUsageReadings(byCPU: snapshot.byCPU.map(reading),
                                    byMemory: snapshot.byMemory.map(reading),
                                    hiddenCount: snapshot.hiddenCount)
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
            recordHistory(MonitorHistorySample.cpu(r), now)
            if let p = r.performance { record(.cpuP, p, now) }
            if let e = r.efficiency { record(.cpuE, e, now) }
            recordSeries(SeriesValues.cpu(performance: r.performance, efficiency: r.efficiency), now)
        case .gpu(let r):
            gpu = r
            recordHistory(MonitorHistorySample.gpu(r), now)
        case .memory(let r):
            memory = r
            alerts.check(cpuCelsius: nil, memory: r, disk: nil)
            recordHistory(MonitorHistorySample.memory(r), now)
        case .disk(let r):
            disk = r
            alerts.check(cpuCelsius: nil, memory: nil, disk: r)
            recordHistory(MonitorHistorySample.disk(r), now)
        case .network(let r):
            network = r
            recordHistory(MonitorHistorySample.network(r), now)
        case .battery(let r):
            battery = r
            recordHistory(MonitorHistorySample.battery(r), now)
        case .temperature(let r):
            temperatures = r
            alerts.check(cpuCelsius: cpuCelsius, memory: nil, disk: nil)
            recordHistory(MonitorHistorySample.temperature(r), now)
            recordSeries(SeriesValues.temperature(r.map { (name: $0.name, celsius: $0.celsius) }), now)
        case .fan(let r):
            fans = r
            recordHistory(MonitorHistorySample.fan(r), now)
        case .power(let r):
            power = r
            recordHistory(MonitorHistorySample.power(r), now)
        }
    }

    /// Persists the columns produced by the shared mapping. The in-memory series mirrors
    /// them for the live charts.
    private func recordHistory(_ values: [String: Double], _ date: Date) {
        for (column, value) in values {
            guard let key = Self.seriesByHistoryColumn[column] else { continue }
            record(key, value, date)
        }
    }

    /// Stores the individual values for the sensor and core charts. The values come from the
    /// same reading that produced the overview column, so nothing samples the hardware twice.
    private func recordSeries(_ values: [String: Double], _ date: Date) {
        guard seriesCollectionEnabled, let db = persistentHistory else { return }
        guard let finished = seriesMinute.add(values, at: date) else { return }
        Task.detached(priority: .background) {
            do {
                try db.recordSeriesMinute(finished)
            } catch {
                NSLog("MacHelper sensor series write failed: %@", error.localizedDescription)
            }
        }
    }

    private static let seriesByHistoryColumn: [String: SeriesKey] = Dictionary(
        uniqueKeysWithValues: SeriesKey.allCases.compactMap { key in
            key.historyColumn.map { ($0, key) }
        })

    private func record(_ key: SeriesKey, _ value: Double, _ date: Date) {
        var points = history[key, default: []]
        points.append(ChartPoint(date: date, value: value))
        let cutoff = date.addingTimeInterval(-Self.historyWindow)
        if let first = points.first, first.date < cutoff {
            points.removeAll { $0.date < cutoff }
        }
        history[key] = points
        if let column = key.historyColumn,
           let finished = minute.addTracked(column, value, at: date),
           let db = persistentHistory {
            Task.detached(priority: .background) {
                do {
                    try db.recordMinute(finished)
                } catch {
                    NSLog("MacHelper history write failed: %@", error.localizedDescription)
                }
            }
        }
    }
}
