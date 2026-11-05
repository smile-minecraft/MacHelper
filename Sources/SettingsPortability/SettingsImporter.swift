import Foundation

/// What importing one category will do, as shown before the user confirms.
public enum ImportStatus: Equatable, Sendable {
    /// The incoming value differs and will replace the current one.
    case overwrite(summary: String)
    /// The current value is already identical.
    case unchanged
    /// This Mac cannot use the category.
    case incompatible(reason: String)
    /// The content is malformed, unknown, or outside the allowed ranges.
    case invalid(reason: String)
}

/// The preview of an import. Entries are ordered by category key so the same file always produces
/// the same plan.
public struct ImportPlan: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let section: String
        public let status: ImportStatus
        /// Validated bytes for an overwrite. Kept internal so a caller cannot apply data that never
        /// went through validation.
        let payload: Data?
    }

    public let entries: [Entry]
    public let schemaVersion: Int
    public let appVersion: String
    public let machineIdentifier: String
    public let exportedAt: Date
    public let excludedContents: [String]
}

public enum SettingsImportError: Error, Equatable, CustomStringConvertible {
    /// Applying one category failed. Sections that were already written were restored; any section
    /// that could not be restored is listed in `rollbackFailures`.
    case applyFailed(section: String, reason: String, rollbackFailures: [String])

    public var description: String {
        switch self {
        case .applyFailed(let section, let reason, let rollbackFailures):
            var text = "Importing \(section) failed: \(reason)"
            if !rollbackFailures.isEmpty {
                text += ". Could not restore: \(rollbackFailures.joined(separator: "; "))"
            }
            return text
        }
    }
}

/// Reads an archive, validates every category, and applies the result all at once or not at all.
public struct SettingsImporter {
    private let sections: [String: any SettingsSection]

    public init(sections: [any SettingsSection]) {
        var byID: [String: any SettingsSection] = [:]
        for section in sections { byID[section.id] = section }
        self.sections = byID
    }

    /// Validates the file and every category without writing anything.
    public func plan(for data: Data) throws -> ImportPlan {
        let archive = try SettingsArchive.decode(data)
        var entries: [ImportPlan.Entry] = []
        for (key, incoming) in archive.sections.sorted(by: { $0.key < $1.key }) {
            if let section = sections[key] {
                entries.append(entry(section: key, section, validation: section.validate(incoming), incoming: incoming))
            } else {
                entries.append(ImportPlan.Entry(section: key,
                                                status: .invalid(reason: "Unknown category: \(key)"),
                                                payload: nil))
            }
        }
        return ImportPlan(entries: entries, schemaVersion: archive.schemaVersion,
                          appVersion: archive.appVersion, machineIdentifier: archive.machineIdentifier,
                          exportedAt: archive.exportedAt, excludedContents: archive.excludedContents)
    }

    /// Builds one preview entry. A snapshot failure counts as an overwrite: the real guard is that
    /// apply re-snapshots every target before writing anything.
    private func entry(section key: String,
                       _ section: any SettingsSection,
                       validation: SectionValidation,
                       incoming: Data) -> ImportPlan.Entry {
        switch validation {
        case .valid(let payload):
            let current = try? section.snapshot()
            return current == payload.data
                ? ImportPlan.Entry(section: key, status: .unchanged, payload: nil)
                : ImportPlan.Entry(section: key, status: .overwrite(summary: payload.summary), payload: payload.data)
        case .incompatible(let reason):
            return ImportPlan.Entry(section: key, status: .incompatible(reason: reason), payload: nil)
        case .invalid(let reason):
            return ImportPlan.Entry(section: key, status: .invalid(reason: reason), payload: nil)
        }
    }

    /// Writes every overwrite entry in `plan`. Snapshots every target first, applies in plan order,
    /// and restores the snapshots in reverse order if any apply fails. Incompatible, invalid and
    /// unchanged entries are left alone.
    public func apply(_ plan: ImportPlan) throws {
        var targets: [(id: String, section: any SettingsSection, payload: Data)] = []
        for entry in plan.entries {
            guard case .overwrite = entry.status else { continue }
            guard let section = sections[entry.section], let payload = entry.payload else {
                throw SettingsImportError.applyFailed(
                    section: entry.section,
                    reason: "the plan has no section for category \(entry.section)",
                    rollbackFailures: [],
                )
            }
            targets.append((entry.section, section, payload))
        }

        var snapshots: [String: Data] = [:]
        for target in targets {
            do { snapshots[target.id] = try target.section.snapshot() }
            catch {
                throw SettingsImportError.applyFailed(
                    section: target.id,
                    reason: String(describing: error),
                    rollbackFailures: [],
                )
            }
        }

        var appliedIDs: [String] = []
        do {
            for target in targets {
                try target.section.apply(target.payload)
                appliedIDs.append(target.id)
            }
        } catch {
            let failedID = targets[appliedIDs.count].id
            // The failed category is restored too, because apply may have written part of its value.
            var toRestore = appliedIDs
            if !toRestore.contains(failedID) { toRestore.append(failedID) }
            var rollbackFailures: [String] = []
            for id in toRestore.reversed() {
                guard let section = sections[id], let snapshot = snapshots[id] else { continue }
                do { try section.restore(snapshot) }
                catch { rollbackFailures.append(id) }
            }
            throw SettingsImportError.applyFailed(section: failedID, reason: String(describing: error),
                                                  rollbackFailures: rollbackFailures)
        }
    }
}
