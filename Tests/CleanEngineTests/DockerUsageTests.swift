import Foundation
import Testing
@testable import CleanEngine

@Suite struct DockerUsageTests {
    @Test func parsesSystemDfLines() throws {
        let text = """
        {"Active":"12","Reclaimable":"7.043GB (59%)","Size":"11.75GB","TotalCount":"171","Type":"Images"}
        {"Active":"10","Reclaimable":"521.7kB (0%)","Size":"988.4MB","TotalCount":"12","Type":"Containers"}
        {"Active":"6","Reclaimable":"0B (0%)","Size":"332.7MB","TotalCount":"6","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"1.211GB","Size":"3.074GB","TotalCount":"1018","Type":"Build Cache"}
        """
        let usage = try #require(DockerUsage.parse(text))
        #expect(usage.rows.map(\.kind) == [.images, .containers, .volumes, .buildCache])
        #expect(usage.rows[0].size == 11_750_000_000)
        #expect(usage.rows[0].reclaimable == 7_043_000_000)
        #expect(usage.rows[0].totalCount == 171 && usage.rows[0].active == 12)
        #expect(usage.rows[1].reclaimable == 521_700)
        #expect(usage.rows[2].reclaimable == 0)
        #expect(usage.totalReclaimable == 7_043_000_000 + 521_700 + 1_211_000_000)
    }

    @Test func rejectsGarbage() {
        #expect(DockerUsage.parse("") == nil)
        #expect(DockerUsage.parse("Cannot connect to the Docker daemon") == nil)
        #expect(DockerUsage.bytes("12XB") == nil)
        #expect(DockerUsage.bytes("-1GB") == nil)
        #expect(DockerUsage.bytes("1.5TB") == 1_500_000_000_000)
    }

    @Test func missingCLIIsReportedNotThrown() {
        #expect(DockerUsage.read(docker: nil) == .failure(.notInstalled))
    }

    @Test func dockerTasksStayOptIn() {
        for task in MaintenanceCatalog.all where task.id.hasPrefix("docker.") {
            #expect(!task.selectedByDefault, "\(task.id) must not be selected by default")
            #expect(!task.requiresRoot)
        }
        if let images = MaintenanceCatalog.all.first(where: { $0.id == "docker.images.unused" }) {
            #expect(images.risk == .high)
        }
    }
}
