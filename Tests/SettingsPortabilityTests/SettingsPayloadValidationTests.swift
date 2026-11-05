import CleanEngine
import FanControl
import Foundation
import SettingsPortability
import Testing

private func isValid(_ validation: SectionValidation) -> Bool {
    if case .valid = validation { return true }
    return false
}

@Suite struct SettingsPayloadValidationTests {
    @Test func customRulesRejectEntriesThatWouldNotLoad() {
        let relative = Data(#"""
        {"schemaVersion":1,"rules":[
          {"id":"a","title":"Relative","category":"caches","risk":"low","paths":["relative/path"],"selectedByDefault":true}
        ]}
        """#.utf8)
        guard case .invalid(let relativeReason) = CleanRulesPayload.validated(relative) else {
            Issue.record("Expected a rule with a relative path to be invalid")
            return
        }
        #expect(relativeReason.contains("absolute"))

        let noPaths = Data(#"""
        {"schemaVersion":1,"rules":[
          {"id":"b","title":"Empty","category":"caches","risk":"low","paths":[]}
        ]}
        """#.utf8)
        guard case .invalid(let emptyReason) = CleanRulesPayload.validated(noPaths) else {
            Issue.record("Expected a rule without paths to be invalid")
            return
        }
        #expect(emptyReason.contains("paths"))
    }

    @Test func customRulesAreNeverPreselected() throws {
        let data = Data(#"""
        {"schemaVersion":1,"rules":[
          {"id":"a","title":"Alpha","category":"caches","risk":"low","paths":["~/Library/Caches/a"],"selectedByDefault":true},
          {"id":"b","title":"Beta","category":"logs","risk":"medium","paths":["~/Library/Logs/b"],"selectedByDefault":true}
        ]}
        """#.utf8)

        guard case .valid(let payload) = CleanRulesPayload.validated(data) else {
            Issue.record("Expected both rules to be valid")
            return
        }
        let decoded = try JSONDecoder().decode(CleanRulesPayload.self, from: payload.data)
        #expect(decoded.rules.count == 2)
        #expect(decoded.rules.allSatisfy { !$0.selectedByDefault })
        #expect(payload.details.count == 2)
    }

    @Test func fanSettingsRejectValuesOutsideTheAllowedRanges() throws {
        let fixed = try JSONEncoder().encode(FanSettingsPayload(basePolicy: FanPolicy(mode: .fixed(fraction: 1.5))))
        guard case .invalid(let fixedReason) = FanSettingsPayload.validated(fixed, hasFans: true) else {
            Issue.record("Expected a fixed speed above 100% to be invalid")
            return
        }
        #expect(fixedReason.contains("fraction"))

        let curve = try JSONEncoder().encode(FanSettingsPayload(basePolicy: FanPolicy(mode: .curve(CurveSettings(
            curve: FanCurve(points: [.init(celsius: 20, fraction: 0), .init(celsius: 200, fraction: 1)]))))))
        guard case .invalid(let curveReason) = FanSettingsPayload.validated(curve, hasFans: true) else {
            Issue.record("Expected a curve point above the allowed temperature to be invalid")
            return
        }
        #expect(curveReason.contains("range"))
    }

    @Test func fanSettingsAreIncompatibleWithoutFans() throws {
        let data = try JSONEncoder().encode(FanSettingsPayload(
            autoEnabled: true,
            autoRules: [FanAutoRule(trigger: .onBattery, target: .quiet)],
            basePolicy: .automatic))

        if case .incompatible(let reason) = FanSettingsPayload.validated(data, hasFans: false) {
            #expect(reason.contains("fans"))
        } else {
            Issue.record("Expected fan settings to be incompatible on a Mac without fans")
        }
        #expect(isValid(FanSettingsPayload.validated(data, hasFans: true)))
    }

    @Test func pathListsRejectRelativeEntries() throws {
        let valid = try JSONEncoder().encode(PathListPayload(paths: [
            "  ~/Library/Caches/com.example.app  ",
            "~/Library/Caches/com.example.app",
            "/Users/Shared/scratch",
        ]))
        guard case .valid(let payload) = PathListPayload.validated(valid) else {
            Issue.record("Expected absolute paths to be valid")
            return
        }
        let normalized = try JSONDecoder().decode(PathListPayload.self, from: payload.data)
        #expect(normalized.paths == ["~/Library/Caches/com.example.app", "/Users/Shared/scratch"])

        let relative = try JSONEncoder().encode(PathListPayload(paths: ["relative/path"]))
        guard case .invalid(let reason) = PathListPayload.validated(relative) else {
            Issue.record("Expected a relative path to be invalid")
            return
        }
        #expect(reason.contains("absolute"))
    }
}
