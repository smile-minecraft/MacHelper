import Foundation
import Metrics
import SMCKit
import Storage

/// Hardware samplers for the background recorder. Readings are turned into history columns
/// by the shared mapping in `Metrics`, so both writers persist the same meaning.
struct MonitorHardwareSampler {
    private let cpu = CPUSampler()
    private let network = NetworkSampler()
    private let disk = DiskSampler()
    private let processes = ProcessSampler()
    private let smc = try? SMC()
    private let hid = HIDTemperatureSensors()
    private let fanDriver: FanDriver?
    private let power: PowerSampler?
    private let temperatureKeys: [FourCC]
    private let lastReadings = LastReadings()

    init() {
        fanDriver = smc.map { FanDriver(smc: $0) }
        power = smc.flatMap { PowerSampler(smc: $0) }
        temperatureKeys = smc.map { SMCTemperatures.discoverKeys($0) } ?? []
    }

    func sample(_ module: String) -> [String: Double] {
        switch module {
        case "cpu":
            let reading = cpu.sample()
            lastReadings.cpu = reading
            return reading.map(MonitorHistorySample.cpu) ?? [:]
        case "gpu":
            return GPUSampler.sample().first.map(MonitorHistorySample.gpu) ?? [:]
        case "memory":
            return MemorySampler.sample().map(MonitorHistorySample.memory) ?? [:]
        case "disk":
            return disk.sample().map(MonitorHistorySample.disk) ?? [:]
        case "network":
            return network.sample().map(MonitorHistorySample.network) ?? [:]
        case "battery":
            return BatterySampler.sample().map(MonitorHistorySample.battery) ?? [:]
        case "temperature":
            let readings = temperatureReadings()
            lastReadings.temperatures = readings
            return readings.map(MonitorHistorySample.temperature) ?? [:]
        case "fan":
            return fanDriver.map { MonitorHistorySample.fan($0.readFans()) } ?? [:]
        case "power":
            return power?.sample().map(MonitorHistorySample.power) ?? [:]
        default:
            return [:]
        }
    }

    /// The top twenty by CPU and by memory; the minute accumulator keeps the top ten of each.
    /// Only names, CPU, and memory cross into history; the path stays in this process.
    func sampleProcesses() -> ProcessUsageReadings {
        let snapshot = processes.sample(top: 20)
        func reading(_ usage: ProcessUsage) -> ProcessUsageReading {
            ProcessUsageReading(pid: usage.pid, name: usage.name, cpu: usage.cpu, memoryBytes: usage.memoryBytes)
        }
        return ProcessUsageReadings(byCPU: snapshot.byCPU.map(reading),
                                    byMemory: snapshot.byMemory.map(reading),
                                    hiddenCount: snapshot.hiddenCount)
    }

    /// Individual values for the series history, derived from the sample the recorder just
    /// took in this tick. Sampling the CPU here again would consume its tick delta twice.
    func sampleSeries(_ module: String) -> [String: Double] {
        switch module {
        case "cpu":
            guard let reading = lastReadings.cpu else { return [:] }
            return SeriesValues.cpu(performance: reading.performance, efficiency: reading.efficiency)
        case "temperature":
            guard let readings = lastReadings.temperatures else { return [:] }
            return SeriesValues.temperature(readings.map { (name: $0.name, celsius: $0.celsius) })
        default:
            return [:]
        }
    }

    /// HID when it exposes sensors, otherwise the SMC keys the app also discovers.
    private func temperatureReadings() -> [TemperatureReading]? {
        TemperatureSources.readings(hid: hid, smc: smc, smcKeys: temperatureKeys)
    }
}

/// The reading behind the series values for the current tick. `MonitorHardwareSampler` is a
/// struct so the recorder can hold it as a value; this reference keeps the cache shared
/// between `sample` and `sampleSeries`.
private final class LastReadings {
    var cpu: CPUReading?
    var temperatures: [TemperatureReading]?
}
