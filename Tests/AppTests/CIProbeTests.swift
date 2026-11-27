import Foundation
import Testing

// Temporary: proves the CI rerun and reporting. Removed before merging.
@Suite struct CIProbeTests {
    @Test func failsOnlyTheFirstTime() throws {
        let marker = FileManager.default.temporaryDirectory
            .appending(path: "machelper-ci-probe-first-run-done")
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
            return
        }
        try Data().write(to: marker)
        Issue.record("first run of the flaky probe")
    }
}
