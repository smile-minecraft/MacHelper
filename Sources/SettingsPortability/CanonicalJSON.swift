import Foundation

/// Canonical encoding for section payloads: sorted keys, no whitespace. Validation returns these
/// bytes so comparing two values is a byte comparison.
enum CanonicalJSON {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
