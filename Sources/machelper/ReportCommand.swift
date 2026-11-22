import ArgumentParser
import CleanEngine
import Diagnostics
import DiskScan
import Foundation
import Metrics
import Security
import SMCKit
import Storage

struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Generate a redacted whole-Mac diagnostic report for AI agents (read-only).",
        discussion: """
        Redaction is on by default: the username, home path, host names, IP/MAC addresses, emails,
        personal volume names and serial numbers are replaced with markers. Use --no-redact only when
        the user explicitly asked for real paths and host names.

        --format picks text, markdown or json (--json is shorthand for json). Nothing is removed and
        no setting is changed. Optional sections: \(SystemReport.allSections.joined(separator: ", ")).
        """
    )
    @OptionGroup var output: OutputOptions

    @Option(name: .long, help: "text, markdown or json (default: text).")
    var format = "text"

    @Option(name: .customLong("output"), help: "Write the report to this file instead of stdout.")
    var outputPath: String?

    @Option(name: .long, help: "History window: 1h, 24h or 7d (default: 24h).")
    var range = "24h"

    @Option(name: .long, help: "Comma-separated sections, or all (default: all).")
    var sections = "all"

    @Flag(name: .long, help: "Also list every mounted volume (a little slower).")
    var includeDisk = false

    @Flag(name: .long, help: "Leave personal values in the report. Only with the user's explicit approval.")
    var noRedact = false

    func validate() throws {
        guard ["text", "markdown", "json"].contains(format) else {
            throw ValidationError("--format must be text, markdown or json")
        }
        guard let seconds = Stats.parse(range), [3600, 86_400, 7 * 86_400].contains(seconds) else {
            throw ValidationError("--range must be 1h, 24h or 7d")
        }
        let chosen = sections.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let unknown = chosen.filter { $0 != "all" && !SystemReport.allSections.contains($0) }
        guard unknown.isEmpty else { throw ValidationError("Unknown section(s): \(unknown.joined(separator: ", "))") }
    }

    func run() throws {
        let seconds = Stats.parse(range) ?? 86_400
        var input = SystemReport.Inputs()
        input.commandName = AgentCommand.onPath ? "machelper" : (AgentCommand.appCopy ?? "machelper")
        input.redacted = !noRedact
        input.selectedSections = sections.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        input.rangeSeconds = seconds
        input.includeDiskDetail = includeDisk

        let system = SystemSnapshot.current()
        let smc = try? SMC()
        let cpuSampler = CPUSampler()
        let diskSampler = DiskSampler()
        let netSampler = NetworkSampler()
        let powerSampler = PowerSampler(smc: smc)

        // Rates need two readings; one short gap is enough and keeps the whole report fast.
        _ = cpuSampler.sample(); _ = diskSampler.sample(); _ = netSampler.sample(); _ = powerSampler?.sample()
        Thread.sleep(forTimeInterval: 0.25)

        let memory = MemorySampler.sample()
        let cores = cpuSampler.coreKinds
        input.chip = ChipFamily.current.description
        input.macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
        input.architecture = sysctlString("hw.machine") ?? "unknown"
        input.hostName = Host.current().name ?? ProcessInfo.processInfo.hostName
        input.uptimeSeconds = system.uptimeSeconds
        input.totalRAMBytes = memory?.totalBytes
        input.totalCores = cores.isEmpty ? nil : cores.count
        input.performanceCores = cores.filter { $0 == .performance }.count
        input.efficiencyCores = cores.filter { $0 == .efficiency }.count

        input.cpuTotal = cpuSampler.sample()?.total
        input.gpu = GPUSampler.sample().map { SystemReport.GPUSample(name: $0.name, utilization: $0.utilization) }
        input.memoryUsedBytes = memory?.usedBytes
        input.memoryTotalBytes = memory?.totalBytes
        input.memoryPressure = memory.map { Self.pressureName($0.pressure) }
        input.swapUsedBytes = memory?.swapUsedBytes ?? system.swapUsedBytes.map { UInt64(max($0, 0)) }
        if let disk = diskSampler.sample() {
            input.diskFreeBytes = Double(disk.availableBytes)
            input.diskTotalBytes = Double(disk.totalBytes)
            input.diskReadBytesPerSecond = disk.readBytesPerSecond
            input.diskWriteBytesPerSecond = disk.writeBytesPerSecond
        }
        input.diskPurgeableBytes = Self.purgeableBytes()
        let net = netSampler.sample()
        input.networkInBytesPerSecond = net?.inBytesPerSecond
        input.networkOutBytesPerSecond = net?.outBytesPerSecond
        let temperatures = HIDTemperatureSensors()?.read() ?? []
        input.hottestCelsius = temperatures.map(\.celsius).max()
        input.temperatureSensorCount = temperatures.count
        input.fans = (smc.flatMap { FanDriver(smc: $0) }?.readFans() ?? []).map {
            SystemReport.FanSample(id: $0.id, rpm: $0.actualRPM, mode: $0.mode.rawValue)
        }
        let power = powerSampler?.sample()
        input.powerSystemWatts = power?.systemWatts
        input.powerCPUWatts = power?.cpuWatts
        input.powerGPUWatts = power?.gpuWatts
        let battery = BatterySampler.sample()
        input.batteryCharge = battery?.charge
        input.batteryWatts = battery?.watts
        input.batteryCycleCount = battery?.cycleCount

        // Everything below is optional evidence. Run it concurrently under one shared budget so a
        // slow Homebrew or a busy history database cannot add seconds to the report.
        let hours = seconds / 3600
        let healthBox = ResultBox<HealthReport>()
        let countBox = ResultBox<Int>()
        let snapshotsBox = ResultBox<LocalSnapshots>()
        let cleanupBox = ResultBox<[SystemReport.CleanupRuleInput]>()
        let securityBox = ResultBox<[SystemReport.SecurityInput]>()
        let startupBox = ResultBox<[SystemReport.StartupItemInput]>()
        let unsignedBox = ResultBox<[String]>()
        let updatesBox = ResultBox<[SystemReport.UpdateInput]>()
        let volumesBox = ResultBox<[SystemReport.VolumeSample]>()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        func launch(_ work: @escaping () -> Void) {
            group.enter()
            queue.async { work(); group.leave() }
        }

        launch {
            guard FileManager.default.fileExists(atPath: MetricsHistory.defaultURL.path),
                  let history = try? MetricsHistory(readOnly: true) else { return }
            healthBox.value = try? HealthCheck.run(history: history, hours: hours, system: system)
            countBox.value = try? history.count()
        }
        launch { snapshotsBox.value = LocalSnapshots.query(for: URL(fileURLWithPath: "/")) }
        launch { cleanupBox.value = Self.collectCleanup() }
        launch {
            securityBox.value = SecurityAudit.run().map {
                SystemReport.SecurityInput(id: $0.id, state: $0.state.rawValue, detail: $0.detail)
            }
        }
        launch {
            let items = StartupItems.list(installed: [])
            startupBox.value = items.map {
                SystemReport.StartupItemInput(label: $0.label, scope: $0.scope.rawValue,
                                              programMissing: $0.programMissing)
            }
            unsignedBox.value = Self.unsignedLabels(items)
        }
        let wantsUpdates = input.selectedSections.contains("all") || input.selectedSections.contains("updates")
        if wantsUpdates {
            launch {
                let result = HomebrewUpdates.outdated(
                    greedy: false, refresh: false,
                    excludingAppBundleNames: [Bundle.main.bundleURL.lastPathComponent],
                    excludingTokens: [HomebrewUpdates.appCaskToken])
                updatesBox.value = (try? result.get())?.map { SystemReport.UpdateInput(name: $0.name) } ?? []
            }
        }
        if includeDisk {
            launch {
                volumesBox.value = DiskVolumeSampler().sample().map {
                    SystemReport.VolumeSample(name: $0.name ?? $0.role.rawValue, role: $0.role.rawValue,
                                              mountPoint: $0.mountPoint.path,
                                              totalBytes: $0.totalBytes, availableBytes: $0.availableBytes)
                }
            }
        }
        _ = group.wait(timeout: .now() + 2)

        input.healthReport = healthBox.value
        input.historySampleCount = countBox.value
        if let snapshots = snapshotsBox.value {
            switch snapshots {
            case .none: input.snapshotsCount = 0
            case .list(let dates, let total):
                input.snapshotsCount = total
                input.snapshotsNewest = dates.max()
            case .unavailable: input.snapshotsAvailable = false
            }
        }
        input.cleanupRules = cleanupBox.value ?? []
        if let checks = securityBox.value { input.securityChecks = checks }
        if let items = startupBox.value { input.startupItems = items }
        input.unsignedStartupLabels = unsignedBox.value ?? []
        if wantsUpdates { input.updates = updatesBox.value ?? [] }
        if includeDisk { input.volumes = volumesBox.value ?? [] }

        let payload = SystemReport.build(input, redactor: ReportRedactor(), now: Date())
        let kind: String = output.json ? "json" : format
        let data: Data
        switch kind {
        case "json": data = try Output.encoder.encode(payload) + Data("\n".utf8)
        case "markdown": data = Data(SystemReport.markdown(payload).utf8)
        default: data = Data(SystemReport.text(payload).utf8)
        }

        guard let outputPath else {
            FileHandle.standardOutput.write(data)
            return
        }
        let url = URL(fileURLWithPath: expandTilde(outputPath))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if kind == "json" {
            struct Written: Encodable {
                let schemaVersion = 1
                let output: String
                let bytes: Int
                let redacted: Bool
            }
            try Output.json(Written(output: url.path, bytes: data.count, redacted: payload.redacted))
        } else {
            Output.line("Report written to \(url.path) (\(data.count) bytes\(payload.redacted ? ", redacted" : "")).")
        }
    }

    // MARK: - Collectors

    private static func pressureName(_ pressure: MemoryReading.Pressure) -> String {
        switch pressure {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }

    /// Bytes Finder counts as purgeable on the startup volume: all available capacity minus what is
    /// available for important usage.
    private static func purgeableBytes() -> Double? {
        let url = URL(fileURLWithPath: "/")
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey,
                                                       .volumeAvailableCapacityForImportantUsageKey])
        guard let all = values?.volumeAvailableCapacity,
              let important = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(max(Int64(all) - important, 0))
    }

    /// A whole clean preview can be slow on a big cache folder. The caller shares a deadline with
    /// the other collectors; `CleanScanner` can stop between rules, leaving a coherent partial plan.
    private static func collectCleanup() -> [SystemReport.CleanupRuleInput] {
        let rules = (try? RuleSet.load()) ?? []
        let box = ResultBox<CleanPlan>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = CleanScanner(rules: rules).scan(progress: { _, _ in }, shouldStop: { false })
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.8)
        return (box.value?.results ?? []).map {
            SystemReport.CleanupRuleInput(ruleID: $0.rule.id, category: $0.rule.category,
                                          risk: $0.rule.risk.rawValue,
                                          candidateCount: $0.candidates.count,
                                          reclaimableBytes: $0.totalSize,
                                          skippedReason: $0.skippedReason)
        }
    }

    /// A launch item whose program cannot be shown to carry a signature is flagged, never changed.
    private static func unsignedLabels(_ items: [StartupItem]) -> [String] {
        items.compactMap { item in
            guard let program = item.program, program.hasPrefix("/"), !ignoredPaths.contains(program) else { return nil }
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: program) as CFURL, [], &code) == errSecSuccess,
                  let code else { return item.programMissing ? nil : item.label }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  info != nil else { return item.label }
            return nil
        }
    }

    /// Scripts and interpreters are never signed, and shell jobs are expected here.
    private static let ignoredPaths: Set<String> = ["/bin/sh", "/bin/bash", "/usr/bin/osascript",
                                                    "/usr/bin/python3", "/usr/bin/ruby", "/usr/bin/perl"]

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: T?
        var value: T? {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }
}
