import Testing
@testable import SMCKit

@Suite struct ThermalReadingTests {
    @Test func zeroAndInvalidTemperaturesAreUnavailable() {
        #expect(SMCThermal.celsius(0) == nil)
        #expect(SMCThermal.celsius(-1) == nil)
        #expect(SMCThermal.celsius(.nan) == nil)
        #expect(SMCThermal.celsius(.infinity) == nil)
        #expect(SMCThermal.celsius(150) == nil)
        #expect(SMCThermal.celsius(55.5) == 55.5)
    }

    @Test func gpuKeysAreRecognized() {
        #expect(SMCThermal.isGPUKey(FourCC("Tg0G")))
        #expect(SMCThermal.isGPUKey(FourCC("Tg0k")))
        #expect(!SMCThermal.isGPUKey(FourCC("TPD0")))
        #expect(!SMCThermal.isGPUKey(FourCC("Te0S")))
    }
}

@Suite struct PowerRailTests {
    @Test func zeroAndInvalidWattsAreUnavailable() {
        #expect(SMCPowerRail.normalizedWatts(0) == nil)
        #expect(SMCPowerRail.normalizedWatts(-1) == nil)
        #expect(SMCPowerRail.normalizedWatts(.nan) == nil)
        #expect(SMCPowerRail.normalizedWatts(.infinity) == nil)
        #expect(SMCPowerRail.normalizedWatts(12.5) == 12.5)
    }

    @Test func cpuPowerFallbackIsLimitedToBaseM4() {
        #expect(ChipFamily.parse(brand: "Apple M4").isBaseM4)
        #expect(!ChipFamily.parse(brand: "Apple M4 Pro").isBaseM4)
        #expect(!ChipFamily.parse(brand: "Apple M3").isBaseM4)
    }
}
