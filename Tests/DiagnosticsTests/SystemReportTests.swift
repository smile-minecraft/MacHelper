import Foundation
import Testing
@testable import Diagnostics

@Suite struct ReportRedactorTests {
    private let profile = RedactionProfile(
        username: "alice",
        homeDirectory: "/Users/alice",
        hostNames: ["Alikes-MacBook-Pro.local", "Alikes-MacBook-Pro"])

    private var redactor: ReportRedactor { ReportRedactor(profile: profile) }

    @Test func scrubsHomePathsAndBareUsername() {
        let text = "home /Users/alice/Downloads/scan.txt, file:///Users/alice/.zshrc, owner alice, other /Users/bob/notes"
        let out = redactor.redact(text)
        #expect(out.contains("~/Downloads/scan.txt"))
        #expect(out.contains("file://~/.zshrc"))
        #expect(out.contains("<redacted-user>"))
        #expect(out.contains("/Users/<redacted-user>/notes"))
        #expect(!out.contains("alice"))
        #expect(!out.contains("/Users/bob"))
    }

    @Test func scrubsHostnamesAndNetworkAddresses() {
        let text = "host Alikes-MacBook-Pro.local and Alikes-MacBook-Pro; ipv4 10.0.0.5, lan 192.168.1.20, " +
                   "loop 127.0.0.1; v6 2001:db8:85a3::8a2e:370:7334, lo ::1, link fe80::1234%en0"
        let out = redactor.redact(text)
        #expect(!out.contains("Alikes"))
        #expect(out.contains("<redacted-host>"))
        #expect(out.contains("127.0.0.1"))
        #expect(out.contains("::1"))
        #expect(!out.contains("10.0.0.5"))
        #expect(!out.contains("192.168.1.20"))
        #expect(!out.contains("2001:db8"))
        #expect(!out.contains("fe80"))
        #expect(out.components(separatedBy: "<redacted-ip>").count - 1 >= 3)
    }

    @Test func scrubsEmailsVolumesAndHardwareIDs() {
        let text = "mail alice@example.com, volume /Volumes/MyPrivateDrive/Photos, " +
                   "system /Volumes/Macintosh HD/System, uuid 550E8400-E29B-41D4-A716-446655440000, " +
                   "Serial Number: C02ZX1Y2Z3T4, wifi aa:bb:cc:dd:ee:ff, eth 11:22:33:44:55:66, cisco 0011.2233.4455"
        let out = redactor.redact(text)
        #expect(out.contains("<redacted-email>"))
        #expect(out.contains("/Volumes/<redacted-volume>/Photos"))
        #expect(out.contains("/Volumes/Macintosh HD/System"))
        #expect(out.contains("<redacted-id>"))
        #expect(!out.contains("{{SERIAL_pz2tkj08}}"))
        #expect(!out.contains("550E8400-E29B"))
        #expect(out.components(separatedBy: "<redacted-mac>").count - 1 == 3)
        #expect(!out.contains("0011.2233.4455"))
    }

    @Test func scrubsSpacedVolumeNamesWithoutHidingTheSystemVolume() {
        let text = "src /Volumes/Alice Backup/docs, quoted \"/Volumes/My Drive\", " +
                   "system /Volumes/Macintosh HD/Applications"
        let out = redactor.redact(text)
        #expect(out.contains("/Volumes/<redacted-volume>/docs"))
        #expect(!out.contains("Alice Backup"))
        #expect(out.contains("\"/Volumes/<redacted-volume>\""))
        #expect(!out.contains("My Drive"))
        #expect(out.contains("/Volumes/Macintosh HD/Applications"))
        #expect(redactor.redact(out) == out)
    }

    @Test func redactionIsIdempotentAndKeepsTechnicalNumbers() {
        let text = "chip Apple M4 Pro, macOS 15.2 (24C101), CPU 87.5%, temp 92.3 C, fan 1840 rpm, " +
                   "power 21.7 W, battery 83%, disk 512.5 GB free, score 74, coverage 0.83, " +
                   "ip 10.0.0.5, user alice"
        let once = redactor.redact(text)
        #expect(redactor.redact(once) == once)
        for token in ["Apple M4 Pro", "15.2", "87.5%", "92.3", "1840 rpm", "21.7 W",
                      "83%", "512.5 GB", "score 74", "0.83"] {
            #expect(once.contains(token), "lost technical value: \(token)")
        }
        #expect(!once.contains("10.0.0.5"))
        #expect(!once.contains("alice"))
    }

    @Test func emptyTextStaysEmpty() {
        #expect(redactor.redact("") == "")
    }
}

@Suite struct SystemReportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let profile = RedactionProfile(
        username: "alice",
        homeDirectory: "/Users/alice",
        hostNames: ["Alikes-MacBook-Pro.local", "Alikes-MacBook-Pro"])

    private var redactor: ReportRedactor { ReportRedactor(profile: profile) }

    private func baseInput() -> SystemReport.Inputs {
        var input = SystemReport.Inputs()
        input.chip = "Apple M4 Pro"
        input.macOSVersion = "macOS 15.2"
        input.architecture = "arm64"
        input.hostName = "Alikes-MacBook-Pro"
        input.totalRAMBytes = 36 * 1_000_000_000
        input.diskFreeBytes = 500e9
        input.diskTotalBytes = 1_000e9
        input.cpuTotal = 0.37
        input.memoryUsedBytes = 18 * 1_000_000_000
        input.memoryTotalBytes = 36 * 1_000_000_000
        return input
    }

    private func json(_ payload: SystemReport.Payload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func jsonHasSchemaVersionOneAndRedactionByDefault() throws {
        let payload = SystemReport.build(baseInput(), redactor: redactor, now: now)
        let object = try json(payload)
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["redacted"] as? Bool == true)
        #expect(object["suggestedActions"] as? [[String: Any]] != nil)
        #expect(object["availableTools"] as? [[String: Any]] != nil)
        let system = try #require(object["system"] as? [String: Any])
        #expect(system["chip"] as? String == "Apple M4 Pro")
        #expect(system["host"] as? String == "<redacted-host>")
        #expect(system["macOSVersion"] as? String == "macOS 15.2")
    }

    @Test func markdownRendersSectionsFindingsAndActions() {
        var input = baseInput()
        input.cleanupRules = [.init(ruleID: "ai.claude-cache", category: "ai", risk: "low",
                                    candidateCount: 4, reclaimableBytes: 6_000_000_000)]
        let payload = SystemReport.build(input, redactor: redactor, now: now)
        let markdown = SystemReport.markdown(payload)
        #expect(markdown.hasPrefix("# MacHelper diagnostic report"))
        #expect(markdown.contains("## System"))
        #expect(markdown.contains("## Live metrics"))
        #expect(markdown.contains("## Cleanup preview (nothing removed)"))
        #expect(markdown.contains("## Findings"))
        #expect(markdown.contains("## Suggested actions"))
        #expect(markdown.contains("## Available tools"))
        #expect(markdown.contains("`machelper clean --max-risk low --json`"))
        #expect(markdown.contains("<redacted-host>"))
        #expect(!SystemReport.text(payload).contains("## "))
    }

    @Test func findingsAreGeneratedForLowDiskHeatSwapAndReclaimableCache() {
        var input = baseInput()
        input.diskFreeBytes = 8e9
        input.hottestCelsius = 98
        input.temperatureSensorCount = 12
        input.memoryPressure = "critical"
        input.swapUsedBytes = 5_000_000_000
        input.cleanupRules = [.init(ruleID: "ai.claude-cache", category: "ai", risk: "low",
                                    candidateCount: 4, reclaimableBytes: 6_000_000_000)]
        input.securityChecks = [.init(id: "gatekeeper", state: "off"), .init(id: "filevault", state: "on")]
        input.startupItems = [.init(label: "com.example.helper", scope: "userAgent", programMissing: true)]
        input.updates = [.init(name: "OBS")]

        let payload = SystemReport.build(input, redactor: redactor, now: now)
        let ids = Set(payload.findings.map(\.id))
        #expect(ids.isSuperset(of: ["disk.low", "thermal.hot", "memory.swap", "memory.pressure",
                                    "clean.reclaimable", "security.gatekeeper", "startup.broken",
                                    "updates.available"]))
        #expect(!ids.contains("security.filevault"))
        #expect(payload.findings.first?.severity == "critical")
        #expect(payload.findings.first(where: { $0.id == "disk.low" })?.severity == "critical")
        let cleanup = payload.cleanupPreview
        #expect(cleanup?.candidateCount == 4)
        #expect(cleanup?.reclaimableBytes == 6_000_000_000)
        #expect(cleanup?.categories.first?.category == "ai")
    }

    @Test func suggestedActionsStayPreviewFirstAndRedacted() throws {
        var input = baseInput()
        input.diskFreeBytes = 8e9
        input.cleanupRules = [.init(ruleID: "dev.npm", category: "developer", risk: "low",
                                    candidateCount: 2, reclaimableBytes: 1_000_000_000)]
        let payload = SystemReport.build(input, redactor: redactor, now: now)
        let actions = Dictionary(uniqueKeysWithValues: payload.suggestedActions.map { ($0.id, $0) })
        let preview = try #require(actions["clean.preview"])
        #expect(preview.command == "machelper clean --max-risk low --json")
        #expect(preview.previewOnly)
        #expect(!preview.requiresUserApproval)
        let apply = try #require(actions["clean.apply"])
        #expect(!apply.previewOnly)
        #expect(apply.requiresUserApproval)
        #expect(actions["analyze"]?.command == "machelper analyze ~ --json --depth 2")
        #expect(payload.suggestedActions.allSatisfy { !$0.command.contains("alice") })
        #expect(payload.availableTools.count >= 20)
        #expect(payload.availableTools.allSatisfy { ["read-only", "preview-by-default"].contains($0.safety) })
    }

    @Test func sectionSelectionAndNoRedactAreRespected() {
        var input = baseInput()
        input.selectedSections = ["hardware"]
        input.redacted = false
        let payload = SystemReport.build(input, redactor: redactor, now: now)
        #expect(payload.redacted == false)
        #expect(payload.system != nil)
        #expect(payload.system?.host == "Alikes-MacBook-Pro")
        #expect(payload.liveMetrics == nil)
        #expect(payload.health == nil)
        #expect(payload.cleanupPreview == nil)
        #expect(payload.availableTools.isEmpty)
    }

    @Test func externalVolumeNamesAreRedactedOnlyWhenRequested() {
        var input = baseInput()
        input.includeDiskDetail = true
        input.volumes = [
            .init(name: "Macintosh HD", role: "startup", mountPoint: "/",
                  totalBytes: 1_000_000_000_000, availableBytes: 500_000_000_000),
            .init(name: "ClientSSD", role: "external", mountPoint: "/Volumes/ClientSSD",
                  totalBytes: 2_000_000_000_000, availableBytes: 1_000_000_000_000),
            .init(name: "Alice Backup", role: "external", mountPoint: "/Volumes/Alice Backup",
                  totalBytes: 3_000_000_000_000, availableBytes: 1_500_000_000_000),
        ]

        let redacted = SystemReport.build(input, redactor: redactor, now: now)
        let volumes = redacted.diskDetail?.volumes
        #expect(volumes?.count == 3)
        #expect(volumes?[0].name == "Macintosh HD")
        #expect(volumes?[1].name == "<redacted-volume>")
        #expect(volumes?[2].name == "<redacted-volume>")
        #expect(volumes?[1].mountPoint == "/Volumes/<redacted-volume>")
        #expect(volumes?[2].mountPoint == "/Volumes/<redacted-volume>")

        input.redacted = false
        let plain = SystemReport.build(input, redactor: redactor, now: now)
        #expect(plain.diskDetail?.volumes[1].name == "ClientSSD")
        #expect(plain.diskDetail?.volumes[2].name == "Alice Backup")
        #expect(plain.diskDetail?.volumes[2].mountPoint == "/Volumes/Alice Backup")
    }

    @Test func commandNamePathIsRedactedInActionsAndTools() {
        var input = baseInput()
        input.commandName = "/Users/alice/Apps/MacHelper.app/Contents/MacOS/machelper"
        let payload = SystemReport.build(input, redactor: redactor, now: now)
        #expect(payload.suggestedActions.allSatisfy { !$0.command.contains("alice") })
        #expect(payload.availableTools.allSatisfy { !$0.example.contains("alice") })
        #expect(payload.suggestedActions.allSatisfy { $0.command.hasPrefix("~/Apps/MacHelper.app/") })
        #expect(payload.availableTools.allSatisfy { $0.example.hasPrefix("~/Apps/MacHelper.app/") })
    }

    @Test func absentHistoryDegradesWithoutFindings() {
        var input = baseInput()
        input.healthReport = nil
        let payload = SystemReport.build(input, redactor: redactor, now: now)
        let health = payload.health
        #expect(health?.history == nil)
        #expect(health?.score == 100)
        #expect(health?.summary.contains("Score 100/100") == true)
    }
}
