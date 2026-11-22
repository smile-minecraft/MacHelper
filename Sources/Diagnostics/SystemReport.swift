import Foundation

/// The whole-Mac diagnostic payload an agent can read in one call.
///
/// This type owns the data shape and the pure assembly logic: it never samples hardware itself, so
/// the same code path runs in tests with fixed inputs. The CLI collects live readings and hands them
/// to `build`.
public enum SystemReport {
    public static let schemaVersion = 1
    public static let allSections = ["hardware", "metrics", "health", "storage", "clean",
                                     "security", "startup", "updates", "tools"]
    public static let hostMarker = "<redacted-host>"

    // MARK: - Inputs

    /// Everything the builder needs. Properties have defaults so a caller can fill in only the
    /// sections it managed to read; a failed sampler must not fail the whole report.
    public struct Inputs: Sendable {
        public var commandName = "machelper"
        public var redacted = true
        public var selectedSections: [String] = allSections
        public var rangeSeconds: TimeInterval = 86_400
        public var includeDiskDetail = false

        public var chip = ""
        public var macOSVersion = ""
        public var architecture = ""
        public var hostName: String?
        public var uptimeSeconds: Double?
        public var totalRAMBytes: UInt64?
        public var totalCores: Int?
        public var performanceCores: Int?
        public var efficiencyCores: Int?

        public var cpuTotal: Double?
        public var cpuPerformance: Double?
        public var cpuEfficiency: Double?
        public var gpu: [GPUSample] = []
        public var memoryUsedBytes: UInt64?
        public var memoryTotalBytes: UInt64?
        public var memoryPressure: String?
        public var swapUsedBytes: UInt64?
        public var diskFreeBytes: Double?
        public var diskTotalBytes: Double?
        public var diskPurgeableBytes: Double?
        public var diskReadBytesPerSecond: Double?
        public var diskWriteBytesPerSecond: Double?
        public var networkInBytesPerSecond: Double?
        public var networkOutBytesPerSecond: Double?
        public var hottestCelsius: Double?
        public var temperatureSensorCount: Int?
        public var fans: [FanSample] = []
        public var powerSystemWatts: Double?
        public var powerCPUWatts: Double?
        public var powerGPUWatts: Double?
        public var batteryCharge: Double?
        public var batteryWatts: Double?
        public var batteryCycleCount: Int?

        public var healthReport: HealthReport?
        public var historySampleCount: Int?
        public var snapshotsCount: Int?
        public var snapshotsAvailable = true
        public var snapshotsNewest: Date?

        public var cleanupRules: [CleanupRuleInput] = []
        public var securityChecks: [SecurityInput]?
        public var startupItems: [StartupItemInput]?
        public var unsignedStartupLabels: [String] = []
        public var updates: [UpdateInput]?
        public var volumes: [VolumeSample] = []

        public init() {}
    }

    /// Plain summary values: the builder needs no knowledge of CleanEngine's live plan types.
    public struct CleanupRuleInput: Sendable {
        public var ruleID: String
        public var category: String
        public var risk: String
        public var candidateCount: Int
        public var reclaimableBytes: UInt64
        public var skippedReason: String?
        public init(ruleID: String, category: String, risk: String, candidateCount: Int,
                    reclaimableBytes: UInt64, skippedReason: String? = nil) {
            self.ruleID = ruleID
            self.category = category
            self.risk = risk
            self.candidateCount = candidateCount
            self.reclaimableBytes = reclaimableBytes
            self.skippedReason = skippedReason
        }
    }

    public struct SecurityInput: Sendable {
        public var id: String
        public var state: String
        public var detail: String?
        public init(id: String, state: String, detail: String? = nil) {
            self.id = id
            self.state = state
            self.detail = detail
        }
    }

    public struct StartupItemInput: Sendable {
        public var label: String
        public var scope: String
        public var programMissing: Bool
        public init(label: String, scope: String, programMissing: Bool) {
            self.label = label
            self.scope = scope
            self.programMissing = programMissing
        }
    }

    public struct UpdateInput: Sendable {
        public var name: String
        public init(name: String) { self.name = name }
    }

    public struct GPUSample: Sendable {
        public var name: String
        public var utilization: Double
        public init(name: String, utilization: Double) {
            self.name = name
            self.utilization = utilization
        }
    }

    public struct FanSample: Sendable {
        public var id: Int
        public var rpm: Double
        public var mode: String
        public init(id: Int, rpm: Double, mode: String) {
            self.id = id
            self.rpm = rpm
            self.mode = mode
        }
    }

    public struct VolumeSample: Sendable {
        public var name: String
        public var role: String
        public var mountPoint: String
        public var totalBytes: Int64?
        public var availableBytes: Int64?
        public init(name: String, role: String, mountPoint: String, totalBytes: Int64?, availableBytes: Int64?) {
            self.name = name
            self.role = role
            self.mountPoint = mountPoint
            self.totalBytes = totalBytes
            self.availableBytes = availableBytes
        }
    }

    // MARK: - Payload

    public struct Payload: Codable, Sendable {
        public let schemaVersion = 1
        public let redacted: Bool
        public let generatedAt: Date
        public let sections: [String]
        public let system: System?
        public let liveMetrics: LiveMetrics?
        public let health: Health?
        public let storage: Storage?
        public let cleanupPreview: CleanupPreview?
        public let security: Security?
        public let startup: Startup?
        public let updates: Updates?
        public let diskDetail: DiskDetail?
        public let findings: [Finding]
        public let suggestedActions: [SuggestedAction]
        public let availableTools: [ToolCapability]
    }

    public struct System: Codable, Sendable {
        public let chip: String
        public let macOSVersion: String
        public let architecture: String
        public let host: String
        public let uptimeSeconds: Double?
        public let totalRAMBytes: UInt64?
        public let cpuCores: CPUCores
    }

    public struct CPUCores: Codable, Sendable {
        public let total: Int?
        public let performance: Int?
        public let efficiency: Int?
    }

    public struct LiveMetrics: Codable, Sendable {
        public let cpu: CPU
        public let gpu: [GPU]
        public let memory: Memory
        public let disk: Disk
        public let network: Network
        public let thermal: Thermal
        public let fans: [Fan]
        public let power: Power
        public let battery: Battery?
    }

    public struct CPU: Codable, Sendable {
        public let total: Double?
        public let performance: Double?
        public let efficiency: Double?
    }

    public struct GPU: Codable, Sendable {
        public let name: String
        public let utilization: Double
    }

    public struct Memory: Codable, Sendable {
        public let usedBytes: UInt64?
        public let totalBytes: UInt64?
        public let pressure: String?
        public let swapUsedBytes: UInt64?
    }

    public struct Disk: Codable, Sendable {
        public let freeBytes: Double?
        public let totalBytes: Double?
        public let purgeableBytes: Double?
        public let readBytesPerSecond: Double?
        public let writeBytesPerSecond: Double?
    }

    public struct Network: Codable, Sendable {
        public let inBytesPerSecond: Double?
        public let outBytesPerSecond: Double?
    }

    public struct Thermal: Codable, Sendable {
        public let hottestCelsius: Double?
        public let sensorCount: Int?
    }

    public struct Fan: Codable, Sendable {
        public let id: Int
        public let rpm: Double
        public let mode: String
    }

    public struct Power: Codable, Sendable {
        public let systemWatts: Double?
        public let cpuWatts: Double?
        public let gpuWatts: Double?
    }

    public struct Battery: Codable, Sendable {
        public let charge: Double
        public let watts: Double?
        public let cycleCount: Int?
    }

    public struct Health: Codable, Sendable {
        public let score: Int
        public let level: String
        public let summary: String
        public let findings: [HealthFinding]
        public let history: HistoryCoverage?
    }

    public struct HealthFinding: Codable, Sendable {
        public let id: String
        public let severity: String
        public let title: String
        public let detail: String
    }

    public struct HistoryCoverage: Codable, Sendable {
        public let windowHours: Double
        public let coverage: Double
        public let sampleCount: Int
        public let peakCPU: Double?
        public let peakMemory: Double?
        public let peakTemperature: Double?
        public let peakPower: Double?
    }

    public struct Storage: Codable, Sendable {
        public let startupVolume: Volume
        public let snapshots: Snapshots
    }

    public struct Volume: Codable, Sendable {
        public let totalBytes: Double
        public let usedBytes: Double
        public let availableBytes: Double
        public let purgeableBytes: Double?
    }

    public struct Snapshots: Codable, Sendable {
        public let readable: Bool
        public let count: Int?
        public let newestDate: Date?
    }

    public struct CleanupPreview: Codable, Sendable {
        public let candidateCount: Int
        public let reclaimableBytes: UInt64
        public let selectedReclaimableBytes: UInt64
        public let categories: [CleanupGroup]
        public let rules: [CleanupRuleSummary]
    }

    public struct CleanupGroup: Codable, Sendable {
        public let category: String
        public let risk: String
        public let ruleIDs: [String]
        public let candidateCount: Int
        public let reclaimableBytes: UInt64
    }

    public struct CleanupRuleSummary: Codable, Sendable {
        public let ruleID: String
        public let category: String
        public let risk: String
        public let candidateCount: Int
        public let reclaimableBytes: UInt64
        public let skippedReason: String?
    }

    public struct Security: Codable, Sendable {
        public let checks: [SecuritySummary]
    }

    public struct SecuritySummary: Codable, Sendable {
        public let id: String
        public let state: String
        public let detail: String?
    }

    public struct Startup: Codable, Sendable {
        public let userAgents: Int
        public let globalAgents: Int
        public let daemons: Int
        public let brokenItems: Int
        public let unsignedItems: Int
        public let problemItems: [StartupSummary]
    }

    public struct StartupSummary: Codable, Sendable {
        public let label: String
        public let scope: String
        public let reason: String
    }

    public struct Updates: Codable, Sendable {
        public let outdatedCount: Int
        public let apps: [String]
    }

    public struct DiskDetail: Codable, Sendable {
        public let volumes: [VolumeSummary]
    }

    public struct VolumeSummary: Codable, Sendable {
        public let name: String
        public let role: String
        public let mountPoint: String
        public let totalBytes: Int64?
        public let availableBytes: Int64?
    }

    public struct Finding: Codable, Sendable, Identifiable {
        public let id: String
        public let severity: String
        public let area: String
        public let title: String
        public let detail: String
    }

    public struct SuggestedAction: Codable, Sendable, Identifiable {
        public let id: String
        public let reason: String
        public let command: String
        public let previewOnly: Bool
        public let risk: String
        public let requiresUserApproval: Bool
    }

    public struct ToolCapability: Codable, Sendable, Identifiable {
        public let command: String
        public let purpose: String
        public let safety: String
        public let example: String
        public var id: String { command }
    }

    // MARK: - Assembly

    public static func build(_ input: Inputs, redactor: ReportRedactor = ReportRedactor(),
                             now: Date = Date()) -> Payload {
        func cleaned(_ value: String?) -> String? {
            guard let value else { return nil }
            return input.redacted ? redactor.redact(value) : value
        }
        func cleaned(_ value: String) -> String { cleaned(value as String?) ?? value }

        let wanted: Set<String> = input.selectedSections.contains("all")
            ? Set(allSections) : Set(input.selectedSections)
        func includes(_ section: String) -> Bool { wanted.contains(section) }

        let system: System? = includes("hardware") ? System(
            chip: cleaned(input.chip.isEmpty ? "unknown" : input.chip),
            macOSVersion: cleaned(input.macOSVersion.isEmpty ? "unknown" : input.macOSVersion),
            architecture: input.architecture.isEmpty ? "unknown" : input.architecture,
            host: input.redacted ? hostMarker : cleaned(input.hostName ?? "unknown"),
            uptimeSeconds: input.uptimeSeconds,
            totalRAMBytes: input.totalRAMBytes,
            cpuCores: CPUCores(total: input.totalCores, performance: input.performanceCores,
                               efficiency: input.efficiencyCores)) : nil

        let liveMetrics: LiveMetrics? = includes("metrics") ? LiveMetrics(
            cpu: CPU(total: input.cpuTotal, performance: input.cpuPerformance, efficiency: input.cpuEfficiency),
            gpu: input.gpu.map { GPU(name: cleaned($0.name), utilization: $0.utilization) },
            memory: Memory(usedBytes: input.memoryUsedBytes, totalBytes: input.memoryTotalBytes,
                           pressure: input.memoryPressure, swapUsedBytes: input.swapUsedBytes),
            disk: Disk(freeBytes: input.diskFreeBytes, totalBytes: input.diskTotalBytes,
                       purgeableBytes: input.diskPurgeableBytes,
                       readBytesPerSecond: input.diskReadBytesPerSecond,
                       writeBytesPerSecond: input.diskWriteBytesPerSecond),
            network: Network(inBytesPerSecond: input.networkInBytesPerSecond,
                             outBytesPerSecond: input.networkOutBytesPerSecond),
            thermal: Thermal(hottestCelsius: input.hottestCelsius, sensorCount: input.temperatureSensorCount),
            fans: input.fans.map { Fan(id: $0.id, rpm: $0.rpm, mode: $0.mode) },
            power: Power(systemWatts: input.powerSystemWatts, cpuWatts: input.powerCPUWatts,
                         gpuWatts: input.powerGPUWatts),
            battery: input.batteryCharge.map {
                Battery(charge: $0, watts: input.batteryWatts, cycleCount: input.batteryCycleCount)
            }) : nil

        let health: Health? = includes("health") ? buildHealth(input, cleaned) : nil
        let storage: Storage? = includes("storage") ? buildStorage(input) : nil
        let cleanup: CleanupPreview? = includes("clean") ? buildCleanup(input, cleaned) : nil
        let security: Security? = includes("security") ? input.securityChecks.map {
            Security(checks: $0.map { SecuritySummary(id: $0.id, state: $0.state, detail: cleaned($0.detail)) })
        } : nil
        let startup: Startup? = includes("startup") ? buildStartup(input, cleaned) : nil
        let updates: Updates? = includes("updates") ? input.updates.map {
            Updates(outdatedCount: $0.count, apps: $0.map { cleaned($0.name) })
        } : nil
        let diskDetail: DiskDetail? = input.includeDiskDetail && !input.volumes.isEmpty ? DiskDetail(
            volumes: input.volumes.map { volume in
                let name = input.redacted && volume.mountPoint != "/"
                    && volume.name.caseInsensitiveCompare("Macintosh HD") != .orderedSame
                    ? "<redacted-volume>" : cleaned(volume.name)
                return VolumeSummary(name: name, role: volume.role, mountPoint: cleaned(volume.mountPoint),
                                     totalBytes: volume.totalBytes, availableBytes: volume.availableBytes)
            }) : nil

        let findings = buildFindings(input, cleanup, security, startup, cleaned)
        return Payload(
            redacted: input.redacted,
            generatedAt: now,
            sections: input.selectedSections,
            system: system,
            liveMetrics: liveMetrics,
            health: health,
            storage: storage,
            cleanupPreview: cleanup,
            security: security,
            startup: startup,
            updates: updates,
            diskDetail: diskDetail,
            findings: findings,
            suggestedActions: buildActions(input, cleanup, findings, cleaned),
            availableTools: includes("tools") ? toolCatalog(command: cleaned(input.commandName)) : [])
    }

    private static func buildHealth(_ input: Inputs, _ cleaned: (String) -> String) -> Health? {
        let report = input.healthReport
        let memory: HealthScore.Memory? = switch input.memoryPressure {
        case "critical": .critical
        case "warning": .warning
        case "normal": .normal
        default: nil
        }
        let score = HealthScore.compute(report: report, freeBytes: input.diskFreeBytes, memory: memory)
        let level: String = switch score.level {
        case .good: "good"
        case .attention: "attention"
        case .critical: "critical"
        }
        let findings = (report?.findings ?? []).map {
            HealthFinding(id: $0.id,
                          severity: $0.severity == .critical ? "critical" : $0.severity == .warning ? "warning" : "info",
                          title: cleaned($0.title), detail: cleaned($0.detail))
        }
        let history = report.map {
            HistoryCoverage(windowHours: $0.windowHours, coverage: $0.coverage,
                            sampleCount: input.historySampleCount ?? Int(($0.coverage * $0.windowHours * 60).rounded()),
                            peakCPU: $0.cpu.maximum, peakMemory: $0.memory.maximum,
                            peakTemperature: $0.temperature.maximum, peakPower: $0.power.maximum)
        }
        let window = report.map { " \(Int($0.windowHours)) h" } ?? ""
        let summary = "Score \(score.value)/100 (\(level)); \(findings.count) finding(s) from history\(window)."
        return Health(score: score.value, level: level, summary: summary, findings: findings, history: history)
    }

    private static func buildStorage(_ input: Inputs) -> Storage? {
        guard let total = input.diskTotalBytes, total > 0 else { return nil }
        let available = max(input.diskFreeBytes ?? 0, 0)
        return Storage(
            startupVolume: Volume(totalBytes: total, usedBytes: max(total - available, 0),
                                  availableBytes: available, purgeableBytes: input.diskPurgeableBytes),
            snapshots: Snapshots(readable: input.snapshotsAvailable, count: input.snapshotsCount,
                                 newestDate: input.snapshotsNewest))
    }

    private static func buildCleanup(_ input: Inputs, _ cleaned: (String) -> String) -> CleanupPreview? {
        guard !input.cleanupRules.isEmpty else { return nil }
        var groups: [String: (category: String, risk: String, ids: Set<String>, count: Int, bytes: UInt64)] = [:]
        var rules: [CleanupRuleSummary] = []
        var totalCount = 0
        var totalBytes: UInt64 = 0
        var selectedBytes: UInt64 = 0
        for rule in input.cleanupRules {
            let key = "\(rule.category)|\(rule.risk)"
            var group = groups[key] ?? (rule.category, rule.risk, [], 0, 0)
            group.ids.insert(rule.ruleID)
            group.count += rule.candidateCount
            group.bytes += rule.reclaimableBytes
            groups[key] = group
            totalCount += rule.candidateCount
            totalBytes += rule.reclaimableBytes
            if rule.risk == "low" { selectedBytes += rule.reclaimableBytes }
            rules.append(CleanupRuleSummary(ruleID: rule.ruleID, category: rule.category,
                                            risk: rule.risk, candidateCount: rule.candidateCount,
                                            reclaimableBytes: rule.reclaimableBytes,
                                            skippedReason: rule.skippedReason.map(cleaned)))
        }
        let sortedGroups = groups.values.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.category < $1.category
        }.map {
            CleanupGroup(category: $0.category, risk: $0.risk, ruleIDs: $0.ids.sorted(),
                         candidateCount: $0.count, reclaimableBytes: $0.bytes)
        }
        return CleanupPreview(
            candidateCount: totalCount,
            reclaimableBytes: totalBytes,
            selectedReclaimableBytes: selectedBytes,
            categories: sortedGroups,
            rules: rules.sorted { $0.reclaimableBytes > $1.reclaimableBytes })
    }

    private static func buildStartup(_ input: Inputs, _ cleaned: (String) -> String) -> Startup? {
        guard let items = input.startupItems else { return nil }
        let unsigned = Set(input.unsignedStartupLabels)
        let broken = items.filter(\.programMissing)
        var problems = broken.map {
            StartupSummary(label: cleaned($0.label), scope: $0.scope, reason: "program missing")
        }
        problems += items.filter { unsigned.contains($0.label) }.map {
            StartupSummary(label: cleaned($0.label), scope: $0.scope, reason: "unsigned or invalid signature")
        }
        return Startup(
            userAgents: items.filter { $0.scope == "userAgent" }.count,
            globalAgents: items.filter { $0.scope == "systemAgent" }.count,
            daemons: items.filter { $0.scope == "systemDaemon" }.count,
            brokenItems: broken.count,
            unsignedItems: items.filter { unsigned.contains($0.label) }.count,
            problemItems: problems)
    }

    // MARK: - Findings

    private static func buildFindings(_ input: Inputs, _ cleanup: CleanupPreview?, _ security: Security?,
                                      _ startup: Startup?, _ cleaned: (String) -> String) -> [Finding] {
        var found: [Finding] = []
        func add(_ id: String, _ severity: String, _ area: String, _ title: String, _ detail: String) {
            found.append(Finding(id: id, severity: severity, area: area,
                                 title: cleaned(title), detail: cleaned(detail)))
        }
        if let free = input.diskFreeBytes {
            switch DiskSpaceLevels.level(freeBytes: free) {
            case .critical:
                add("disk.low", "critical", "storage", "Startup disk almost full",
                    "\(bytes(free)) free. macOS needs room for updates, swap and caches.")
            case .low:
                add("disk.low", "warning", "storage", "Startup disk getting full",
                    "\(bytes(free)) free on the startup volume.")
            case .healthy: break
            }
        }
        if let hot = input.hottestCelsius, hot >= 95 {
            add("thermal.hot", "warning", "thermal", "Running hot",
                String(format: "The hottest sensor reads %.0f °C; the system may slow down to cool off.", hot))
        }
        if input.memoryPressure == "critical" {
            add("memory.pressure", "warning", "memory", "Memory pressure is critical",
                "Apps are being compressed to keep the Mac responsive.")
        } else if input.memoryPressure == "warning" {
            add("memory.pressure", "info", "memory", "Memory pressure is elevated",
                "Memory is tighter than usual right now.")
        }
        if let swap = input.swapUsedBytes, swap >= 4_000_000_000 {
            add("memory.swap", "warning", "memory", "A lot of memory is on disk",
                "\(bytes(Double(swap))) of swap is in use; a restart clears it.")
        }
        if let cleanup, cleanup.reclaimableBytes >= 5_000_000_000 {
            add("clean.reclaimable", "info", "clean", "Regenerable data can be reclaimed",
                "\(bytes(Double(cleanup.reclaimableBytes))) across \(cleanup.candidateCount) preview candidates.")
        }
        for check in security?.checks ?? [] where check.state == "off" {
            let severe = ["gatekeeper", "sip", "firewall"].contains(check.id)
            add("security.\(check.id)", severe ? "warning" : "info", "security",
                "\(check.id) is off", "The \(check.id) protection is currently disabled.")
        }
        if let startup, startup.brokenItems > 0 {
            add("startup.broken", "warning", "startup", "Broken startup items found",
                "\(startup.brokenItems) startup item(s) point to a program that no longer exists.")
        }
        if let updates = input.updates, updates.count > 0 {
            add("updates.available", "info", "updates", "Homebrew apps have updates",
                "\(updates.count) cask(s) have a newer version available.")
        }
        if let report = input.healthReport {
            for finding in report.findings where finding.severity >= .warning && finding.id != "disk.low" {
                let severity = finding.severity == .critical ? "critical" : "warning"
                add("health.\(finding.id)", severity, "health", finding.title, finding.detail)
            }
        }
        let rank = ["critical": 0, "warning": 1, "info": 2]
        return found.sorted { (rank[$0.severity] ?? 3, $0.id) < (rank[$1.severity] ?? 3, $1.id) }
    }

    // MARK: - Suggested actions

    private static func buildActions(_ input: Inputs, _ cleanup: CleanupPreview?, _ findings: [Finding],
                                     _ cleaned: (String) -> String) -> [SuggestedAction] {
        let c = cleaned(input.commandName)
        var actions: [SuggestedAction] = []
        func add(_ id: String, _ reason: String, _ command: String, _ previewOnly: Bool,
                 _ risk: String, _ approval: Bool) {
            actions.append(SuggestedAction(id: id, reason: reason, command: command,
                                           previewOnly: previewOnly, risk: risk,
                                           requiresUserApproval: approval))
        }
        add("status", "Refresh the live CPU, memory, disk, network, sensor and power readings.",
            "\(c) status --json", true, "low", false)
        add("doctor", "Read the recorded health history and its findings.",
            "\(c) doctor --json", true, "low", false)
        add("security", "Inspect Gatekeeper, FileVault, firewall, SIP, XProtect and auto-updates.",
            "\(c) security --json", true, "low", false)
        add("startup", "Review launch agents, daemons and broken items.",
            "\(c) startup --json", true, "low", false)
        add("updates", "List Homebrew apps that have a newer version.",
            "\(c) updates --json", true, "low", false)
        if findings.contains(where: { $0.id == "disk.low" }) {
            add("analyze", "See which folders and files use the startup disk.",
                "\(c) analyze ~ --json --depth 2", true, "low", false)
            add("purge", "Preview rebuildable project build artifacts.",
                "\(c) purge --json", true, "low", false)
        }
        if findings.contains(where: { $0.id == "thermal.hot" }) {
            add("stats", "Check when the Mac got hot and what else spiked then.",
                "\(c) stats --range 1h --json", true, "low", false)
        }
        if let cleanup, cleanup.reclaimableBytes > 0 {
            add("insights", "Find large files that look unused before cleaning anything.",
                "\(c) insights ~ --json", true, "low", false)
            add("clean.preview", "Preview the safe, low-risk cleanup plan. Removes nothing.",
                "\(c) clean --max-risk low --json", true, "low", false)
            add("clean.apply", "Apply the low-risk plan after the user has approved the preview.",
                "\(c) clean --max-risk low --yes --json", false, "low", true)
        }
        if findings.contains(where: { $0.id == "startup.broken" }) {
            add("login-items", "Check background items registered with macOS, not just plists.",
                "\(c) login-items --json", true, "low", false)
        }
        return actions
    }

    /// Machine-readable catalog so an agent can chain tools without reading the whole SKILL.md.
    /// `command` comes from the caller so a redacted app-bundle path never leaks into an example.
    public static func toolCatalog(command: String = "machelper") -> [ToolCapability] {
        [
            ToolCapability(command: "report", purpose: "Redacted whole-Mac diagnostic report in one call",
                           safety: "read-only", example: "\(command) report --json"),
            ToolCapability(command: "status", purpose: "Live CPU, GPU, memory, disk, network, temperatures, fans, power, battery",
                           safety: "read-only", example: "\(command) status --json"),
            ToolCapability(command: "doctor", purpose: "Health check from recorded history plus live swap and uptime",
                           safety: "read-only", example: "\(command) doctor --json"),
            ToolCapability(command: "stats", purpose: "Recorded per-minute metric history and peaks",
                           safety: "read-only", example: "\(command) stats --range 24h --json"),
            ToolCapability(command: "analyze", purpose: "Where disk space goes in a folder or volume",
                           safety: "read-only", example: "\(command) analyze ~ --json --depth 2"),
            ToolCapability(command: "insights", purpose: "Large unused files and folders that grew",
                           safety: "read-only", example: "\(command) insights ~ --json"),
            ToolCapability(command: "duplicates", purpose: "Duplicate files in a folder",
                           safety: "read-only", example: "\(command) duplicates ~/Downloads --json"),
            ToolCapability(command: "clean", purpose: "Preview or remove items matched by declarative rules",
                           safety: "preview-by-default", example: "\(command) clean --max-risk low --json"),
            ToolCapability(command: "purge", purpose: "Preview or remove rebuildable project build artifacts",
                           safety: "preview-by-default", example: "\(command) purge --json"),
            ToolCapability(command: "optimize", purpose: "Preview or run maintenance tasks",
                           safety: "preview-by-default", example: "\(command) optimize --json"),
            ToolCapability(command: "uninstall", purpose: "Preview or remove an app and its leftovers",
                           safety: "preview-by-default", example: "\(command) uninstall \"App Name\" --json"),
            ToolCapability(command: "updates", purpose: "List or upgrade outdated Homebrew casks",
                           safety: "preview-by-default", example: "\(command) updates --json"),
            ToolCapability(command: "startup", purpose: "List or switch launch agents and daemons",
                           safety: "preview-by-default", example: "\(command) startup --json"),
            ToolCapability(command: "login-items", purpose: "List macOS-registered login and background items",
                           safety: "read-only", example: "\(command) login-items --json"),
            ToolCapability(command: "security", purpose: "Read Gatekeeper, FileVault, firewall, SIP, XProtect, auto-updates",
                           safety: "read-only", example: "\(command) security --json"),
            ToolCapability(command: "docker", purpose: "Docker disk use and reclaimable space",
                           safety: "read-only", example: "\(command) docker --json"),
            ToolCapability(command: "history", purpose: "Past cleanup operations",
                           safety: "read-only", example: "\(command) history --json"),
            ToolCapability(command: "rules", purpose: "List cleanup rule ids and categories",
                           safety: "read-only", example: "\(command) rules"),
            ToolCapability(command: "ignore", purpose: "Manage paths that must never be cleaned",
                           safety: "preview-by-default", example: "\(command) ignore add <path>"),
            ToolCapability(command: "monitor", purpose: "Sample metrics live or record them to history",
                           safety: "read-only", example: "\(command) monitor --json"),
            ToolCapability(command: "guide", purpose: "Print the full agent skill text",
                           safety: "read-only", example: "\(command) guide"),
            ToolCapability(command: "skill", purpose: "Install or check the agent skill",
                           safety: "read-only", example: "\(command) skill --json"),
        ]
    }

    // MARK: - Rendering

    public static func markdown(_ payload: Payload) -> String { render(payload, markdown: true) }
    public static func text(_ payload: Payload) -> String { render(payload, markdown: false) }

    private static func render(_ payload: Payload, markdown: Bool) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        func heading(_ title: String) {
            lines.append(markdown ? "\n## \(title)" : "\n\(title.uppercased())")
        }
        func bullet(_ text: String) { lines.append("\(markdown ? "- " : "  ")\(text)") }
        func pair(_ label: String, _ value: String) { bullet("\(label): \(value)") }

        lines.append(markdown ? "# MacHelper diagnostic report" : "MacHelper diagnostic report")
        bullet("generated \(iso.string(from: payload.generatedAt))")
        bullet("redacted \(payload.redacted ? "yes" : "NO — personal values are present")")
        bullet("sections \(payload.sections.joined(separator: ", "))")

        if let s = payload.system {
            heading("System")
            pair("chip", s.chip)
            pair("macOS", s.macOSVersion)
            pair("architecture", s.architecture)
            pair("host", s.host)
            pair("memory", s.totalRAMBytes.map { bytes(Double($0)) } ?? "unknown")
            pair("cores", "\(s.cpuCores.total.map(String.init) ?? "?") total, "
                + "\(s.cpuCores.performance.map(String.init) ?? "?") performance, "
                + "\(s.cpuCores.efficiency.map(String.init) ?? "?") efficiency")
            if let uptime = s.uptimeSeconds { pair("uptime", String(format: "%.1f h", uptime / 3600)) }
        }
        if let m = payload.liveMetrics {
            heading("Live metrics")
            pair("CPU", percent(m.cpu.total) + (m.cpu.performance.map { " (P \(percent($0)))" } ?? "")
                 + (m.cpu.efficiency.map { ", E \(percent($0)))" } ?? ""))
            if !m.gpu.isEmpty { pair("GPU", m.gpu.map { "\($0.name) \(percent($0.utilization))" }.joined(separator: ", ")) }
            pair("memory", "\(m.memory.usedBytes.map { bytes(Double($0)) } ?? "?") / "
                + "\(m.memory.totalBytes.map { bytes(Double($0)) } ?? "?")"
                + (m.memory.pressure.map { ", pressure \($0)" } ?? ""))
            pair("swap", m.memory.swapUsedBytes.map { bytes(Double($0)) } ?? "unknown")
            pair("disk", "\(m.disk.freeBytes.map { bytes($0) } ?? "?") free"
                + (m.disk.readBytesPerSecond.map { ", read \(bytes($0))/s" } ?? "")
                + (m.disk.writeBytesPerSecond.map { ", write \(bytes($0))/s" } ?? ""))
            pair("network", "in \(m.network.inBytesPerSecond.map { bytes($0) } ?? "?")/s, "
                + "out \(m.network.outBytesPerSecond.map { bytes($0) } ?? "?")/s")
            pair("temperature", m.thermal.hottestCelsius.map {
                String(format: "hottest %.0f °C across %d sensor(s)", $0, m.thermal.sensorCount ?? 0)
            } ?? "unavailable")
            if !m.fans.isEmpty { pair("fans", m.fans.map { "\($0.id): \(Int($0.rpm)) rpm (\($0.mode))" }.joined(separator: ", ")) }
            pair("power", m.power.systemWatts.map { String(format: "%.1f W system", $0) } ?? "unavailable")
            if let b = m.battery { pair("battery", String(format: "%.0f%%", b.charge) + (b.cycleCount.map { ", \($0) cycles" } ?? "")) }
        }
        if let h = payload.health {
            heading("Health")
            bullet(h.summary)
            if let history = h.history {
                pair("history", String(format: "%.0f%% of %.0f h (%d samples)",
                                       history.coverage * 100, history.windowHours, history.sampleCount))
            } else {
                bullet("No history database was available for this window.")
            }
            for f in h.findings { bullet("[\(f.severity)] \(f.title): \(f.detail)") }
        }
        if let storage = payload.storage {
            heading("Storage")
            let v = storage.startupVolume
            pair("startup volume", "\(bytes(v.totalBytes)) total, \(bytes(v.usedBytes)) used, "
                + "\(bytes(v.availableBytes)) available")
            pair("snapshots", storage.snapshots.readable
                 ? "\(storage.snapshots.count.map(String.init) ?? "?") local snapshot(s)"
                 : "could not be read")
        }
        if let cleanup = payload.cleanupPreview {
            heading("Cleanup preview (nothing removed)")
            pair("candidates", "\(cleanup.candidateCount) holding \(bytes(Double(cleanup.reclaimableBytes)))")
            pair("safe default selection", bytes(Double(cleanup.selectedReclaimableBytes)))
            for group in cleanup.categories.prefix(8) {
                bullet("\(group.category) / \(group.risk): \(group.candidateCount) item(s), "
                    + "\(bytes(Double(group.reclaimableBytes))) — \(group.ruleIDs.prefix(4).joined(separator: ", "))")
            }
        }
        if let security = payload.security {
            heading("Security")
            for check in security.checks { pair(check.id, check.state + (check.detail.map { " (\($0))" } ?? "")) }
        }
        if let startup = payload.startup {
            heading("Startup")
            pair("items", "\(startup.userAgents) user agents, \(startup.globalAgents) global agents, "
                + "\(startup.daemons) daemons")
            pair("broken", "\(startup.brokenItems); unsigned or invalid: \(startup.unsignedItems)")
        }
        if let updates = payload.updates {
            heading("Updates")
            pair("outdated Homebrew casks", "\(updates.outdatedCount)")
        }
        if let detail = payload.diskDetail {
            heading("Volumes")
            for v in detail.volumes {
                bullet("\(v.name) (\(v.role)) \(v.mountPoint): "
                    + "\(v.totalBytes.map { bytes(Double($0)) } ?? "?") total, "
                    + "\(v.availableBytes.map { bytes(Double($0)) } ?? "?") available")
            }
        }
        heading("Findings")
        if payload.findings.isEmpty {
            bullet("No issues detected.")
        } else {
            for f in payload.findings { bullet("[\(f.severity)] \(f.area): \(f.title) — \(f.detail)") }
        }
        heading("Suggested actions")
        for a in payload.suggestedActions {
            bullet("\(a.id): `\(a.command)` — \(a.reason) "
                + "(\(a.previewOnly ? "preview only" : "changes data"), risk \(a.risk), "
                + "approval \(a.requiresUserApproval ? "required" : "not required"))")
        }
        if !payload.availableTools.isEmpty {
            heading("Available tools")
            for t in payload.availableTools {
                bullet("\(t.command) [\(t.safety)]: \(t.purpose) — `\(t.example)`")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func percent(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.0f%%", value * 100)
    }

    private static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, min(value, Double(Int64.max)))), countStyle: .file)
    }
}
