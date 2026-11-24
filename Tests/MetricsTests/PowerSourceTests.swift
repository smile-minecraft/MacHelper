import SMCKit
import Testing
@testable import Metrics

/// A GPU series is one number per sample, so a Mac that reports two accelerators (Intel iGPU
/// next to a discrete GPU) has to pick one: the one doing the work.
@Suite struct GPUSelectionTests {
    private func gpu(_ name: String, _ utilization: Double) -> GPUReading {
        GPUReading(name: name, utilization: utilization)
    }

    @Test func noReportedGPUHasNoSelection() {
        #expect(GPUSelection.busiest([]) == nil)
    }

    @Test func singleGPUIsSelectedAsIs() {
        #expect(GPUSelection.busiest([gpu("Apple M4", 0.07)]) == gpu("Apple M4", 0.07))
    }

    @Test func busiestGPUWinsWhateverTheOrder() {
        let igpu = gpu("Intel Iris Plus", 0.03)
        let dgpu = gpu("AMD Radeon Pro 5500M", 0.62)
        #expect(GPUSelection.busiest([igpu, dgpu]) == dgpu)
        #expect(GPUSelection.busiest([dgpu, igpu]) == dgpu)
    }

    @Test func idleGPUsKeepTheFirstReported() {
        // Both idle: the discrete GPU has nothing to show, so the order IOAccelerator returned
        // decides, rather than a GPU flipping the series when both read zero.
        let first = gpu("Intel Iris Plus", 0)
        let second = gpu("AMD Radeon Pro 5500M", 0)
        #expect(GPUSelection.busiest([first, second]) == first)
        #expect(GPUSelection.busiest([gpu("Intel Iris Plus", 0.2), gpu("AMD Radeon Pro 5500M", 0.2)])
                == gpu("Intel Iris Plus", 0.2))
    }
}

/// IOReport's energy model does not exist on Intel Macs. There the SMC `PSTR` rail is the only
/// measurement, and the reading has to be a whole-system wattage with no per-rail split.
@Suite struct PowerReadingSourceTests {
    @Test func eitherSourceIsEnoughToCreateASampler() {
        #expect(PowerSampler.canMeasure(ioReport: false, systemRail: true), "Intel: SMC PSTR only")
        #expect(PowerSampler.canMeasure(ioReport: true, systemRail: false))
        #expect(PowerSampler.canMeasure(ioReport: true, systemRail: true))
        #expect(!PowerSampler.canMeasure(ioReport: false, systemRail: false))
    }

    @Test func smcSystemRailAloneIsAWholeSystemReading() throws {
        let reading = try #require(PowerSampler.reading(watts: nil, systemWatts: 42.5,
                                                        cpuFallback: nil, hasSystemRail: true))
        #expect(reading.systemWatts == 42.5)
        #expect(reading.hasSystemRail == true)
        #expect(reading.cpuWatts == nil)
        #expect(reading.gpuWatts == nil)
        #expect(reading.aneWatts == nil)
        #expect(reading.dramWatts == nil)
        #expect(reading.channels.isEmpty)
    }

    @Test func systemOnlyReadingStillHasASplit() throws {
        // What the power panel draws: without per-rail channels the whole total is the
        // unmeasured "rest of system", which is still a real card instead of a skeleton.
        let reading = try #require(PowerSampler.reading(watts: nil, systemWatts: 42.5,
                                                        cpuFallback: nil, hasSystemRail: true))
        let breakdown = try #require(PowerBreakdown(reading))
        #expect(breakdown.hasSystemRail)
        #expect(breakdown.total == 42.5)
        #expect(breakdown.components.isEmpty)
        #expect(breakdown.chip == 0)
        #expect(breakdown.rest == 42.5)
    }

    @Test func energyModelChannelsSplitIntoRails() throws {
        let watts = ["CPU Energy": 3.5, "GPU Energy": 2.25, "ANE0": 0.5, "DRAM": 1.25]
        let reading = try #require(PowerSampler.reading(watts: watts, systemWatts: 20,
                                                        cpuFallback: nil, hasSystemRail: true))
        #expect(reading.cpuWatts == 3.5)
        #expect(reading.gpuWatts == 2.25)
        #expect(reading.aneWatts == 0.5)
        #expect(reading.dramWatts == 1.25)
        #expect(reading.systemWatts == 20)
        #expect(reading.channels == watts)
    }

    @Test func smcCPURailReplacesTheFrozenEnergyModelCPU() throws {
        let reading = try #require(PowerSampler.reading(watts: ["CPU Energy": 1.2, "GPU Energy": 2],
                                                        systemWatts: nil, cpuFallback: 5.4,
                                                        hasSystemRail: false))
        #expect(reading.cpuWatts == 5.4)
        #expect(reading.gpuWatts == 2)
        #expect(reading.hasSystemRail == false, "no PSTR: history keeps reading the column as GPU watts")
    }

    @Test func nothingMeasuredIsNotAZeroReading() {
        #expect(PowerSampler.reading(watts: nil, systemWatts: nil, cpuFallback: nil,
                                     hasSystemRail: false) == nil)
        #expect(PowerSampler.reading(watts: [:], systemWatts: nil, cpuFallback: nil,
                                     hasSystemRail: true) == nil,
                "the PSTR key can exist while one read fails; that is no reason to report 0 W")
        #expect(PowerSampler.reading(watts: ["CPU Energy": 0, "GPU Energy": 0], systemWatts: nil,
                                     cpuFallback: nil, hasSystemRail: false) == nil)
    }

    @Test func firstSampleOfASubscriptionWaitsForAnInterval() {
        guard let sampler = PowerSampler() else { return }
        // No SMC rail is handed in and IOReport needs two samples for a delta, so the very
        // first call has nothing to report yet.
        #expect(sampler.sample() == nil)
    }

    @Test func smcOnlySamplerReadsTheSystemRailWithoutASubscription() throws {
        // The Intel case, run here with the subscription left out: no energy model, SMC `PSTR`
        // only. Sampling must not need the subscription, and `PSTR` is one reading, so there is
        // nothing to warm up.
        guard let smc = try? SMC() else { return }
        // Skipped on a Mac without the `PSTR` rail: there is no Intel-style source to sample.
        guard let sampler = PowerSampler(smc: smc, energyModel: nil) else { return }
        let reading = try #require(sampler.sample())
        #expect(reading.hasSystemRail == true)
        #expect((reading.systemWatts ?? 0) > 0)
        #expect(reading.channels.isEmpty, "no energy model, so no per-channel breakdown")
        for watts in [reading.cpuWatts, reading.gpuWatts, reading.aneWatts, reading.dramWatts].compactMap({ $0 }) {
            #expect(watts > 0)
        }
    }
}
