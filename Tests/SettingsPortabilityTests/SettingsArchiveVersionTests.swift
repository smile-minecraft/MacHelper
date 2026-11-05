import Foundation
import SettingsPortability
import Testing

@Suite struct SettingsArchiveVersionTests {
    /// A newer writer may reshape the container. The version has to be read before the rest of the
    /// document, so the app can report a newer file instead of calling it unreadable.
    @Test func newerSchemaVersionWithDifferentContainerIsUnsupported() throws {
        let data = Data(#"""
        {"format":"com.machelper.settings","schemaVersion":2,"document":{"sections":[]}}
        """#.utf8)

        #expect(throws: SettingsArchiveError.unsupportedVersion(2)) {
            _ = try SettingsArchive.decode(data)
        }
    }
}
