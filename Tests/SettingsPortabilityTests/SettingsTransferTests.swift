import Foundation
import SettingsPortability
import Testing

private let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)

private enum TestFailure: Error, Equatable {
    case expected
}

/// A storage-free stand-in for one category, so the importer can be exercised without UserDefaults,
/// files or hardware. With no fixed validation it accepts whatever the archive carries, which makes
/// it useful for round trips.
private final class FakeSection: SettingsSection {
    let id: String
    var value: Data
    var validation: SectionValidation?
    var applyError: Error?
    private(set) var applied: [Data] = []
    private(set) var restored: [Data] = []

    init(id: String, value: String = "", validation: SectionValidation? = nil) {
        self.id = id
        self.value = Data(value.utf8)
        self.validation = validation
    }

    func snapshot() throws -> Data { value }

    func validate(_ data: Data) -> SectionValidation {
        validation ?? .valid(SettingsPayload(data: data, summary: "\(id) changes"))
    }

    func apply(_ data: Data) throws {
        if let applyError { throw applyError }
        applied.append(data)
        value = data
    }

    func restore(_ snapshot: Data) throws {
        restored.append(snapshot)
        value = snapshot
    }
}

private func archive(_ sections: [String: String], schemaVersion: Int = 1) throws -> Data {
    try SettingsArchive(schemaVersion: schemaVersion, appVersion: "9.9.9", machineIdentifier: "Mac16,1",
                        exportedAt: exportedAt, sections: sections.mapValues { Data($0.utf8) }).encoded()
}

private func reason(of status: ImportStatus) -> String? {
    switch status {
    case .incompatible(let reason), .invalid(let reason): reason
    default: nil
    }
}

@Suite struct SettingsTransferTests {
    @Test func exportsSelectedCategoriesWithMetadata() throws {
        let monitor = FakeSection(id: SettingsCategory.monitor.rawValue, value: "monitor-value")
        let alerts = FakeSection(id: SettingsCategory.alerts.rawValue, value: "alerts-value")
        let fans = FakeSection(id: SettingsCategory.fans.rawValue, value: "fans-value")
        let exporter = SettingsExporter(appVersion: "9.9.9", machineIdentifier: "Mac16,1", now: { exportedAt })

        let data = try exporter.export([SettingsCategory.monitor.rawValue, SettingsCategory.fans.rawValue],
                                       from: [monitor, alerts, fans])
        let archive = try SettingsArchive.decode(data)

        #expect(archive.format == SettingsArchive.formatIdentifier)
        #expect(archive.schemaVersion == SettingsArchive.currentSchemaVersion)
        #expect(archive.appVersion == "9.9.9")
        #expect(archive.machineIdentifier == "Mac16,1")
        #expect(archive.exportedAt == exportedAt)
        #expect(archive.excludedContents.contains("history"))
        #expect(archive.sections.keys.sorted() == [SettingsCategory.fans.rawValue, SettingsCategory.monitor.rawValue])
        #expect(archive.sections[SettingsCategory.monitor.rawValue] == Data("monitor-value".utf8))
    }

    @Test func roundTripsExportedValues() throws {
        let source = FakeSection(id: SettingsCategory.monitor.rawValue, value: "monitor-value")
        let data = try SettingsExporter(appVersion: "9.9.9", machineIdentifier: "Mac16,1", now: { exportedAt })
            .export([source.id], from: [source])

        let target = FakeSection(id: SettingsCategory.monitor.rawValue, value: "other-value")
        let importer = SettingsImporter(sections: [target])
        try importer.apply(try importer.plan(for: data))

        #expect(target.value == Data("monitor-value".utf8))
    }

    @Test func rejectsNewerSchemaVersionWithoutTouchingSettings() throws {
        let section = FakeSection(id: SettingsCategory.monitor.rawValue, value: "original")
        let importer = SettingsImporter(sections: [section])

        #expect(throws: SettingsArchiveError.unsupportedVersion(2)) {
            _ = try importer.plan(for: try archive(["monitor": "new"], schemaVersion: 2))
        }
        #expect(section.value == Data("original".utf8))
        #expect(section.applied.isEmpty)
    }

    @Test func rejectsCorruptOrIncompleteFiles() throws {
        let section = FakeSection(id: SettingsCategory.monitor.rawValue, value: "original")
        let importer = SettingsImporter(sections: [section])
        let incomplete = Data(#"""
        {"format":"com.machelper.settings","schemaVersion":1,"appVersion":"9.9.9","machineIdentifier":"Mac16,1","exportedAt":"2023-11-14T22:13:20Z"}
        """#.utf8)

        #expect(throws: SettingsArchiveError.self) {
            _ = try importer.plan(for: Data("not a settings file".utf8))
        }
        #expect(throws: SettingsArchiveError.self) {
            _ = try importer.plan(for: incomplete)
        }
        let foreign = try SettingsArchive(format: "com.example.other", appVersion: "9.9.9",
                                          machineIdentifier: "Mac16,1", exportedAt: exportedAt, sections: [:]).encoded()
        #expect(throws: SettingsArchiveError.self) {
            _ = try importer.plan(for: foreign)
        }
        #expect(section.value == Data("original".utf8))
    }

    @Test func planReportsOverwriteUnchangedInvalidAndIncompatible() throws {
        let overwrite = FakeSection(id: "a-overwrite", value: "old",
                                    validation: .valid(SettingsPayload(data: Data("new".utf8), summary: "2 menu bar items")))
        let unchanged = FakeSection(id: "b-unchanged", value: "same",
                                    validation: .valid(SettingsPayload(data: Data("same".utf8), summary: "same values")))
        let incompatible = FakeSection(id: "c-incompatible", validation: .incompatible("This Mac has no fans"))
        let invalid = FakeSection(id: "d-invalid", validation: .invalid("Rule has no paths"))
        let importer = SettingsImporter(sections: [overwrite, unchanged, incompatible, invalid])

        let plan = try importer.plan(for: try archive([
            "a-overwrite": "new", "b-unchanged": "same", "c-incompatible": "x", "d-invalid": "y", "e-unknown": "z",
        ]))

        #expect(plan.appVersion == "9.9.9")
        #expect(plan.entries.map(\.section) == ["a-overwrite", "b-unchanged", "c-incompatible", "d-invalid", "e-unknown"])
        guard plan.entries.count == 5 else { return }
        #expect(plan.entries[0].status == .overwrite(summary: "2 menu bar items"))
        #expect(plan.entries[1].status == .unchanged)
        #expect(reason(of: plan.entries[2].status)?.contains("fans") == true)
        #expect(reason(of: plan.entries[3].status)?.contains("paths") == true)
        #expect(reason(of: plan.entries[4].status)?.contains("category") == true)
        #expect(overwrite.value == Data("old".utf8))
    }

    @Test func appliesValidCategoriesAndSkipsRejectedOnes() throws {
        let good = FakeSection(id: "good", value: "old",
                               validation: .valid(SettingsPayload(data: Data("new".utf8), summary: "changes")))
        let incompatible = FakeSection(id: "incompatible", value: "keep", validation: .incompatible("no fans"))
        let invalid = FakeSection(id: "invalid", value: "keep", validation: .invalid("bad value"))
        let importer = SettingsImporter(sections: [good, incompatible, invalid])

        let plan = try importer.plan(for: try archive(["good": "new", "incompatible": "x", "invalid": "y"]))
        #expect(good.applied.isEmpty)
        try importer.apply(plan)

        #expect(good.value == Data("new".utf8))
        #expect(incompatible.value == Data("keep".utf8))
        #expect(invalid.value == Data("keep".utf8))
        #expect(incompatible.applied.isEmpty)
        #expect(invalid.applied.isEmpty)
    }

    @Test func restoresEverySectionWhenALaterApplyFails() throws {
        let first = FakeSection(id: "a", value: "a-original",
                                validation: .valid(SettingsPayload(data: Data("a-new".utf8), summary: "a")))
        let second = FakeSection(id: "b", value: "b-original",
                                 validation: .valid(SettingsPayload(data: Data("b-new".utf8), summary: "b")))
        second.applyError = TestFailure.expected
        let importer = SettingsImporter(sections: [first, second])
        let plan = try importer.plan(for: try archive(["a": "a-new", "b": "b-new"]))

        do {
            try importer.apply(plan)
            Issue.record("Expected the second section to fail")
        } catch let error as SettingsImportError {
            guard case .applyFailed(let section, _, let rollbackFailures) = error else {
                Issue.record("Unexpected import error: \(error)")
                return
            }
            #expect(section == "b")
            #expect(rollbackFailures.isEmpty)
        }

        #expect(first.value == Data("a-original".utf8))
        #expect(second.value == Data("b-original".utf8))
        #expect(first.restored == [Data("a-original".utf8)])
    }

    @Test func cancellingAfterThePlanLeavesEverySettingUntouched() throws {
        let section = FakeSection(id: "monitor", value: "original",
                                  validation: .valid(SettingsPayload(data: Data("new".utf8), summary: "new")))
        let importer = SettingsImporter(sections: [section])
        let plan = try importer.plan(for: try archive(["monitor": "new"]))

        #expect(section.value == Data("original".utf8))
        #expect(section.applied.isEmpty)

        try importer.apply(plan)
        #expect(section.value == Data("new".utf8))
    }

    @Test func importingTheSameFileTwiceReportsNoChanges() throws {
        let section = FakeSection(id: "monitor", value: "original",
                                  validation: .valid(SettingsPayload(data: Data("new".utf8), summary: "new")))
        let importer = SettingsImporter(sections: [section])
        let data = try archive(["monitor": "new"])

        try importer.apply(try importer.plan(for: data))
        #expect(section.applied.count == 1)

        let secondPlan = try importer.plan(for: data)
        #expect(secondPlan.entries.map(\.status) == [.unchanged])
        try importer.apply(secondPlan)
        #expect(section.applied.count == 1)
    }
}
