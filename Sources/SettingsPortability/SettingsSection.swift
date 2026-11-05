import Foundation

/// A validated payload ready to be written, plus what the import preview shows about it.
public struct SettingsPayload: Equatable, Sendable {
    /// Canonical bytes. Validation must return the same bytes for the same input, because the
    /// importer compares them with the current value to report "no change".
    public var data: Data
    /// One line for the import plan.
    public var summary: String
    /// Optional per-item lines (imported rules, automatic fan rules).
    public var details: [String]

    public init(data: Data, summary: String, details: [String] = []) {
        self.data = data
        self.summary = summary
        self.details = details
    }
}

public enum SectionValidation: Equatable, Sendable {
    /// Valid on this Mac. The payload is what apply writes.
    case valid(SettingsPayload)
    /// This Mac cannot use the category (no controllable fans, hardware the app does not drive).
    case incompatible(String)
    /// The content is malformed, unknown, or outside the allowed ranges.
    case invalid(String)
}

/// One settings category: its current value, how to validate an imported value, and how to write
/// and restore it. The app owns the storage-backed implementations; this module orchestrates them.
public protocol SettingsSection {
    /// Stable category key used in the archive and the import plan.
    var id: String { get }

    /// The current effective value in canonical bytes. Restoring it must reproduce the current
    /// behaviour, so encode defaults when the user never changed anything.
    func snapshot() throws -> Data

    /// Checks imported bytes against the same rules the app applies to its own values. Returns
    /// canonical bytes in the valid case.
    func validate(_ data: Data) -> SectionValidation

    /// Writes a validated payload. Called only by the importer, which takes the snapshots needed
    /// for rollback first.
    func apply(_ data: Data) throws

    /// Puts back a value returned by `snapshot`.
    func restore(_ snapshot: Data) throws
}
