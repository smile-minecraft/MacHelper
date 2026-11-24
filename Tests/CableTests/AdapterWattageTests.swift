import Testing
@testable import Cable

/// The recommended wattage is what the diagnosis compares the live adapter against, so a
/// missing or wrong entry produces (or hides) an "adapter is smaller than recommended" finding.
@Suite struct AdapterWattageTests {
    private func watts(_ model: String?) -> Int? {
        IORegistryPowerParser.recommendedAdapterWatts(model: model)
    }

    @Test func portableModelIdentifiersMapToTheirAdapter() {
        let expected: [String: Int] = [
            "MacBookPro15,1": 87, "MacBookPro15,3": 87,
            "MacBookPro15,2": 61, "MacBookPro15,4": 61, "MacBookPro16,2": 61, "MacBookPro16,3": 61,
            "MacBookPro16,1": 96, "MacBookPro16,4": 96,
            "MacBookPro18,1": 140, "MacBookPro18,2": 140,
            "MacBookPro18,3": 67, "MacBookPro18,4": 67,
            "MacBookAir8,1": 30, "MacBookAir8,2": 30, "MacBookAir9,1": 30,
        ]
        for (model, expectedWatts) in expected {
            #expect(watts(model) == expectedWatts, "\(model)")
        }
    }

    @Test func appleSiliconAndUnnamedModelsKeepTheFamilyDefault() {
        // Identifiers the table does not name must behave exactly as before the identifier table.
        #expect(watts("MacBookPro17,1") == 96)
        #expect(watts("MacBookAir10,1") == 35)
        #expect(watts("Mac14,10") == nil)
        #expect(watts("Mac16,10") == nil)
        #expect(watts("MacPro7,1") == nil)
        #expect(watts(nil) == nil)
        #expect(watts("") == nil)
    }

    @Test func identifierLookupIgnoresCaseAndSurroundingWhitespace() {
        #expect(watts("macbookpro15,1") == 87)
        #expect(watts(" MacBookAir9,1\n") == 30)
    }

    @Test func theBundledIntelAdapterIsNoLongerReportedAsTooSmall() {
        // A 15-inch 2018 model with its own 87 W adapter used to be told to buy a bigger one.
        let power = PowerState(
            machineModel: "MacBookPro15,1",
            batteryInstalled: true,
            adapterWatts: 87,
            recommendedAdapterWatts: watts("MacBookPro15,1"),
            externalConnected: true,
            isCharging: true
        )
        #expect(!ChargingDiagnosis.evaluate(power: power).contains { $0.id == "charging.adapter.underpowered" })

        // A 61 W charger on the same model is still flagged.
        var small = power
        small.adapterWatts = 61
        #expect(ChargingDiagnosis.evaluate(power: small).contains { $0.id == "charging.adapter.underpowered" })
    }

    @Test func m1ProMaxFourteenInchUses67WAndSixteenInchUses140W() {
        let fourteen = PowerState(
            machineModel: "MacBookPro18,3",
            batteryInstalled: true,
            adapterWatts: 67,
            recommendedAdapterWatts: watts("MacBookPro18,3"),
            externalConnected: true,
            isCharging: true
        )
        #expect(!ChargingDiagnosis.evaluate(power: fourteen).contains { $0.id == "charging.adapter.underpowered" })

        var fourteenSmall = fourteen
        fourteenSmall.adapterWatts = 45
        #expect(ChargingDiagnosis.evaluate(power: fourteenSmall).contains { $0.id == "charging.adapter.underpowered" })

        let sixteen = PowerState(
            machineModel: "MacBookPro18,1",
            batteryInstalled: true,
            adapterWatts: 140,
            recommendedAdapterWatts: watts("MacBookPro18,1"),
            externalConnected: true,
            isCharging: true
        )
        #expect(!ChargingDiagnosis.evaluate(power: sixteen).contains { $0.id == "charging.adapter.underpowered" })

        var sixteenSmall = sixteen
        sixteenSmall.adapterWatts = 96
        #expect(ChargingDiagnosis.evaluate(power: sixteenSmall).contains { $0.id == "charging.adapter.underpowered" })
    }
}
