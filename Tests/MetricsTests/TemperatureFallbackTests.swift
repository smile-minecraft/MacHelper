import SMCKit
import Testing
@testable import Metrics

/// Intel Macs have no HID temperature sensors, so the SMC keys are the only source there. The
/// CLI asks the shared merge rule for readings instead of reading HID on its own; these pin that
/// rule's two ends — no source at all is an empty list, and no HID source is the SMC's job.
@Suite struct TemperatureFallbackTests {
    @Test func withoutAnySourceThereAreNoReadings() {
        #expect(TemperatureSources.readings(hid: nil, smc: nil, smcKeys: []) == nil)
        #expect(TemperatureSources.readings(hid: nil, smc: nil, smcKeys: ["TC0P", "TG0P"]) == nil)
    }

    @Test func withoutHIDTheSMCKeysAreTheSource() throws {
        // The branch Intel Macs take. Runs on any Mac with readable SMC temperature keys.
        guard let smc = try? SMC() else { return }
        let keys = SMCTemperatures.discoverKeys(smc)
        guard !keys.isEmpty else { return }
        let readings = try #require(TemperatureSources.readings(hid: nil, smc: smc, smcKeys: keys))
        #expect(!readings.isEmpty)
        let names = Set(keys.map(\.description))
        #expect(readings.allSatisfy { names.contains($0.name) }, "every reading comes from the discovered keys")
        #expect(readings.allSatisfy { $0.celsius > 5 && $0.celsius < 130 })
    }

    @Test func intelSMCKeyNamesKeepTheirCategory() {
        #expect(SMCTemperatures.category(for: "TC0P") == .cpu)
        #expect(SMCTemperatures.category(for: "TG0P") == .gpu)
        #expect(SMCTemperatures.category(for: "TB0T") == .battery)
        #expect(SMCTemperatures.category(for: "TH0P") == .storage)
        #expect(SMCTemperatures.category(for: "TM0P") == .memory)
        #expect(SMCTemperatures.category(for: "TA0P") == .other)
    }
}
