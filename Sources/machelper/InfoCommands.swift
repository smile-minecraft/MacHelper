import ArgumentParser
import CleanEngine
import DiskScan
import Foundation
import Metrics
import Diagnostics
import Storage
import SMCKit

struct Analyze: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan a folder or volume and show where the space goes.",
        discussion: "Sizes are allocated bytes with hard links and APFS clones counted once. Read-only."
    )

    @OptionGroup var output: OutputOptions

    @Argument(help: "Folder to scan (default: your home folder).")
    var path: String = "~"

    @Option(name: .long, help: "Tree depth to print / include in JSON.")
    var depth = 2

    @Option(name: .long, help: "Children shown per folder.")
    var top = 10

    @Option(name: .long, help: "Largest files to list.")
    var largest = 15

    func run() throws {
        let url = URL(fileURLWithPath: expandTilde(path))
        let scanner = DiskScanner()
        let result = try scanner.scan(url)
        let root = result.root

        if output.json {
            struct Node: Encodable {
                let name: String; let path: String; let size: UInt64; let files: Int; let isDirectory: Bool
                let unreadable: Bool; let children: [Node]?
            }
            func node(_ n: DiskNode, _ d: Int) -> Node {
                Node(name: n.name, path: n.path, size: n.size, files: n.isDirectory ? n.fileCount : 1,
                     isDirectory: n.isDirectory, unreadable: n.readError != 0,
                     children: d < depth && n.isDirectory ? n.children.prefix(top).map { node($0, d + 1) } : nil)
            }
            struct File: Encodable { let path: String; let size: UInt64; let modified: Date }
            struct Out: Encodable {
                let schemaVersion = 1; let root: Node; let largestFiles: [File]
                let files: Int; let directories: Int; let unreadableDirectories: Int; let seconds: Double
                /// "complete", or "partial" when some folders could not be read (grant Full Disk Access).
                let status: String
            }
            try Output.json(Out(root: node(root, 0),
                                largestFiles: root.largestFiles(limit: largest).map { File(path: $0.path, size: $0.size, modified: $0.modified) },
                                files: result.progress.files, directories: result.progress.directories,
                                unreadableDirectories: result.progress.unreadableDirectories,
                                seconds: (result.elapsed * 100).rounded() / 100,
                                status: result.progress.unreadableDirectories == 0 ? "complete" : "partial"))
            return
        }

        Output.line("\(Output.shortPath(root.path))  \(Output.bytes(root.size))  (\(result.progress.files) files, \(result.progress.directories) folders, \(String(format: "%.1f", result.elapsed)) s)")
        func printTree(_ n: DiskNode, _ d: Int, _ indent: String) {
            guard d < depth else { return }
            for c in n.children.prefix(top) {
                let pct = root.size > 0 ? Double(c.size) / Double(root.size) * 100 : 0
                Output.line("\(indent)\(Output.lpad(Output.bytes(c.size), 10)) \(Output.lpad(String(format: "%.1f%%", pct), 6))  \(c.name)\(c.isDirectory ? "/" : "")\(c.readError != 0 ? "  (unreadable)" : "")")
                if c.isDirectory { printTree(c, d + 1, indent + "    ") }
            }
        }
        printTree(root, 0, "  ")
        Output.line("\nLargest files:")
        for f in root.largestFiles(limit: largest) {
            Output.line("  \(Output.lpad(Output.bytes(f.size), 10))  \(Output.shortPath(f.path))")
        }
        if result.progress.unreadableDirectories > 0 {
            Output.line("\n\(result.progress.unreadableDirectories) folders could not be read. Grant Full Disk Access to your terminal for a complete scan.")
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show system status: CPU, GPU, memory, disk, network, temperatures, fans, power, battery.",
        discussion: "With --watch, prints one JSON object per line (NDJSON) when combined with --json."
    )

    @OptionGroup var output: OutputOptions

    @Option(name: .long, help: "Keep sampling: number of samples (0 = once).")
    var watch = 0

    @Option(name: .long, help: "Seconds between samples.")
    var interval = 1.0

    struct Snapshot: Encodable {
        let schemaVersion = 1
        let time: Date
        let chip: String
        let cpu: CPUReading?
        let gpu: [GPUReading]
        let memory: MemoryReading?
        let disk: DiskReading?
        let network: NetworkReading?
        let battery: BatteryReading?
        let power: PowerReading?
        let fans: [FanReading]
        let temperatures: [TemperatureReading]
        let hottestCelsius: Double?
    }

    func run() throws {
        let smc = try? SMC()
        let cpu = CPUSampler(), net = NetworkSampler(), disk = DiskSampler()
        let power = PowerSampler(smc: smc)
        let hid = HIDTemperatureSensors()
        let fans = smc.map { FanDriver(smc: $0) }
        // Rates need two samples.
        _ = cpu.sample(); _ = net.sample(); _ = disk.sample(); _ = power?.sample()

        let samples = max(watch, 1)
        for i in 0..<samples {
            Thread.sleep(forTimeInterval: max(interval, 0.2))
            let temps = hid?.read() ?? []
            let snap = Snapshot(time: Date(), chip: ChipFamily.current.description, cpu: cpu.sample(),
                                gpu: GPUSampler.sample(), memory: MemorySampler.sample(), disk: disk.sample(),
                                network: net.sample(), battery: BatterySampler.sample(), power: power?.sample(),
                                fans: fans?.readFans() ?? [], temperatures: temps,
                                hottestCelsius: temps.map(\.celsius).max())
            if output.json {
                if watch > 0 {
                    let e = JSONEncoder()
                    e.dateEncodingStrategy = .iso8601
                    e.outputFormatting = [.sortedKeys]
                    FileHandle.standardOutput.write(try e.encode(snap) + Data("\n".utf8))
                } else {
                    try Output.json(snap)
                }
            } else {
                if i > 0 { Output.line() }
                printHuman(snap)
            }
        }
    }

    private func printHuman(_ s: Snapshot) {
        func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a" }
        func w(_ v: Double?) -> String { v.map { String(format: "%.1f W", $0) } ?? "n/a" }
        Output.line("\(s.chip)")
        if let c = s.cpu { Output.line("CPU      \(pct(c.total))  (P \(pct(c.performance)) / E \(pct(c.efficiency)))") }
        for g in s.gpu { Output.line("GPU      \(pct(g.utilization))") }
        if let m = s.memory {
            Output.line("Memory   \(Output.memory(m.usedBytes)) / \(Output.memory(m.totalBytes))  pressure \(m.pressure)  swap \(Output.memory(m.swapUsedBytes))")
        }
        if let d = s.disk {
            Output.line("Disk     \(Output.bytes(UInt64(max(d.availableBytes, 0)))) free  read \(Output.bytes(UInt64(d.readBytesPerSecond)))/s  write \(Output.bytes(UInt64(d.writeBytesPerSecond)))/s")
        }
        if let n = s.network { Output.line("Network  ↓ \(Output.bytes(UInt64(n.inBytesPerSecond)))/s  ↑ \(Output.bytes(UInt64(n.outBytesPerSecond)))/s") }
        if let h = s.hottestCelsius { Output.line(String(format: "Temp     hottest %.0f °C (%d sensors)", h, s.temperatures.count)) }
        for f in s.fans { Output.line("Fan \(f.id)    \(Int(f.actualRPM)) rpm (\(Int(f.minRPM))–\(Int(f.maxRPM)), \(f.mode))") }
        if let p = s.power { Output.line("Power    system \(w(p.systemWatts))  GPU \(w(p.gpuWatts))  CPU \(w(p.cpuWatts))") }
        if let b = s.battery { Output.line("Battery  \(pct(b.charge))  \(String(format: "%+.1f W", b.watts))  cycles \(b.cycleCount)") }
    }
}

struct DockerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docker",
        abstract: "Show how much space Docker uses and how much it can reclaim (read-only).",
        discussion: """
        Runs `docker system df`; the engine (Docker Desktop, OrbStack, Colima…) must be running.
        To reclaim space use `machelper optimize --task docker.prune` (or docker.builder.all, docker.images.unused) --yes.
        """
    )

    @OptionGroup var output: OutputOptions

    func run() throws {
        switch DockerUsage.read() {
        case .success(let usage):
            if output.json {
                struct Out: Encodable { let schemaVersion = 1; let usage: DockerUsage; let totalSize, totalReclaimable: UInt64 }
                try Output.json(Out(usage: usage, totalSize: usage.totalSize, totalReclaimable: usage.totalReclaimable))
                return
            }
            Output.line("\(Output.pad("TYPE", 14)) \(Output.lpad("COUNT", 7)) \(Output.lpad("ACTIVE", 7)) \(Output.lpad("SIZE", 10)) \(Output.lpad("RECLAIMABLE", 12))")
            for r in usage.rows {
                Output.line("\(Output.pad(r.type, 14)) \(Output.lpad("\(r.totalCount)", 7)) \(Output.lpad("\(r.active)", 7)) \(Output.lpad(Output.bytes(r.size), 10)) \(Output.lpad(Output.bytes(r.reclaimable), 12))")
            }
            Output.line("\nTotal \(Output.bytes(usage.totalSize)), reclaimable \(Output.bytes(usage.totalReclaimable)) (as reported by Docker).")
        case .failure(let failure):
            let message: String = switch failure {
            case .notInstalled: "Docker CLI not found."
            case .engineNotRunning: "Docker is installed but its engine is not running. Start Docker Desktop, OrbStack or Colima and try again."
            case .unreadable(let text): "Could not read Docker disk usage: \(text)"
            }
            if output.json {
                struct Out: Encodable { let schemaVersion = 1; let error: String }
                try Output.json(Out(error: message))
            } else {
                Output.err(message)
            }
            throw ExitCode(1)
        }
    }
}

struct LoginItemsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login-items",
        abstract: "List login items and background items macOS has registered (read-only).",
        discussion: """
        Reads the Background Task Management database (sfltool dumpbtm): the list behind
        System Settings → General → Login Items, including items apps register themselves.
        Change them in System Settings; `machelper startup` manages LaunchAgent plists.
        macOS asks for an administrator password each time sfltool reads the database; the
        MacHelper app reads it through its Helper instead and never asks.
        """
    )

    @OptionGroup var output: OutputOptions

    @Flag(name: .long, help: "Include disabled items.")
    var all = false

    func run() throws {
        switch BackgroundItems.read() {
        case .failure(.unavailable(let message)):
            Output.err("Could not read background items: \(message)")
            throw ExitCode(1)
        case .success(let items):
            let groups = BackgroundItems.groups(items).filter { all || $0.enabled }
            if output.json {
                struct Group: Encodable { let title: String; let enabled: Bool; let parent: BackgroundItem?; let items: [BackgroundItem] }
                struct Out: Encodable { let schemaVersion = 1; let groups: [Group] }
                try Output.json(Out(groups: groups.map { Group(title: $0.title, enabled: $0.enabled, parent: $0.parent, items: $0.items) }))
                return
            }
            for g in groups {
                let developer = g.parent?.developerName.flatMap { $0 == g.title ? nil : " — \($0)" } ?? ""
                Output.line("\(g.enabled ? "[on] " : "[off]") \(g.title)\(developer)")
                for i in g.items where all || i.isActive {
                    let state = i.enabled ? (i.allowed ? "" : " (not allowed)") : " (disabled)"
                    let scope = i.uid == Int(getuid()) ? "" : " [all users]"
                    let path = i.executablePath ?? i.url ?? i.bundleIdentifier ?? ""
                    Output.line("      \(Output.pad(i.kind.rawValue, 13)) \(i.displayName)\(state)\(scope)  \(Output.shortPath(path))")
                }
            }
            let shown = groups.count
            Output.line("\n\(shown) groups\(all ? "" : " with enabled items; add --all to include disabled ones").")
        }
    }
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "One-off health report from the monitoring history (read-only).",
        discussion: """
        Looks at the stored history (CPU, memory, temperature, busiest processes, free-space trend)
        plus swap and uptime. Works best with background recording turned on.
        Login items are counted only with --background-items, because reading them (sfltool)
        asks for an administrator password; the app's health check counts them through its Helper.
        Exit code 0 also when problems are found; check "overall" in --json output.
        """
    )

    @OptionGroup var output: OutputOptions

    @Flag(name: .long, help: "Also count login and background items (macOS asks for an administrator password).")
    var backgroundItems = false

    @Option(name: .long, help: "Hours of history to look at (1–720).")
    var hours: Double = 24

    func validate() throws {
        guard (1...720).contains(hours) else { throw ValidationError("--hours must be between 1 and 720") }
    }

    func run() throws {
        let history = try MetricsHistory(readOnly: true)
        let report = try HealthCheck.run(history: history, hours: hours, system: .current(includeBackgroundItems: backgroundItems))
        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let overall: HealthReport.Severity; let report: HealthReport }
            try Output.json(Out(overall: report.overall, report: report))
            return
        }
        let pct = { (v: Double?) in v.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "-" }
        Output.line("Last \(Int(hours)) h, \(pct(report.coverage)) of the time recorded")
        Output.line("CPU avg \(pct(report.cpu.average)) max \(pct(report.cpu.maximum))   Memory avg \(pct(report.memory.average)) max \(pct(report.memory.maximum))")
        if let t = report.temperature.maximum { Output.line("Temperature max \(Int(t)) °C" + (report.power.average.map { String(format: "   Power avg %.1f W", $0) } ?? "")) }
        if let free = report.system.diskFreeBytes {
            var line = "Free space \(Output.bytes(UInt64(free)))"
            if let f = report.diskForecast {
                line += String(format: "   trend %@%@/day", f.bytesPerDay < 0 ? "-" : "+", Output.bytes(UInt64(abs(f.bytesPerDay))))
                if let d = f.daysUntilFull { line += String(format: ", full in ~%.0f days", d) }
            } else {
                line += "   (trend needs 12 h of hourly data)"
            }
            Output.line(line)
        }
        if !report.topByCPU.isEmpty {
            Output.line("Busiest (share of one core × time present): " + report.topByCPU.prefix(3).map { "\($0.name) \(pct($0.averageCPU * $0.presence))" }.joined(separator: ", "))
        }
        Output.line()
        if report.findings.isEmpty { Output.line("No problems found.") }
        for f in report.findings {
            Output.line("[\(f.severity.rawValue.uppercased())] \(f.title)")
            Output.line("    \(f.detail)")
        }
    }
}
