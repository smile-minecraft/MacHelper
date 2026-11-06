import Foundation

/// A maintenance action. Defined in code, never in rule files: rules can name paths, not commands.
public struct MaintenanceTask: Sendable, Identifiable {
    public enum Runner: Sendable {
        /// Runs as the user.
        case user([[String]])
        /// Needs root; only the Helper (through the app) can run it.
        case helper
    }

    public let id: String
    public let title: String
    public let description: String
    public let risk: RiskLevel
    public let selectedByDefault: Bool
    public let runner: Runner
    /// Executables that must exist for the task to apply.
    public let requires: [String]
    /// Optional command that must succeed for the task to apply (e.g. Xcode installed anywhere).
    public var probe: [String]? = nil

    public var requiresRoot: Bool {
        if case .helper = runner { return true }
        return false
    }

    public var isAvailable: Bool {
        guard requires.allSatisfy({ FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        if let probe { return MaintenanceRunner.exec(probe, timeout: 10).0 == 0 }
        return true
    }
}

public enum MaintenanceCatalog {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    /// The Docker CLI, whichever engine provides it (Docker Desktop, OrbStack, Colima via Homebrew).
    public static let docker: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "\(home)/.orbstack/bin/docker", "\(home)/.docker/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker", "/Applications/OrbStack.app/Contents/MacOS/xbin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    public static let all: [MaintenanceTask] = {
        var tasks: [MaintenanceTask] = [
            MaintenanceTask(id: "quicklook.reset", title: String(localized: "Reset QuickLook thumbnail cache", bundle: .module),
                            description: String(localized: "Clears the preview thumbnail cache and reloads QuickLook plug-ins, fixing wrong or stale thumbnails.", bundle: .module),
                            risk: .low, selectedByDefault: true,
                            runner: .user([["/usr/bin/qlmanage", "-r", "cache"], ["/usr/bin/qlmanage", "-r"]]),
                            requires: ["/usr/bin/qlmanage"]),
            MaintenanceTask(id: "simulators.unavailable", title: String(localized: "Delete unavailable simulators", bundle: .module),
                            description: String(localized: "Removes iOS simulators whose runtime no longer exists (xcrun simctl delete unavailable).", bundle: .module),
                            risk: .low, selectedByDefault: true,
                            runner: .user([["/usr/bin/xcrun", "simctl", "delete", "unavailable"]]),
                            requires: ["/usr/bin/xcrun"], probe: ["/usr/bin/xcrun", "--find", "simctl"]),
            MaintenanceTask(id: "dock.refresh", title: String(localized: "Restart the Dock", bundle: .module),
                            description: String(localized: "Useful when Dock or Launchpad icons misbehave. The Dock flickers briefly, then comes back.", bundle: .module),
                            risk: .low, selectedByDefault: false,
                            runner: .user([["/usr/bin/killall", "Dock"]]), requires: ["/usr/bin/killall"]),
            MaintenanceTask(id: "finder.refresh", title: String(localized: "Restart Finder", bundle: .module),
                            description: String(localized: "Useful when Finder hangs or shows wrong icons. Copies in progress are interrupted.", bundle: .module),
                            risk: .medium, selectedByDefault: false,
                            runner: .user([["/usr/bin/killall", "Finder"]]), requires: ["/usr/bin/killall"]),
            MaintenanceTask(id: "launchservices.rebuild", title: String(localized: "Rebuild the LaunchServices database", bundle: .module),
                            description: String(localized: "Fixes duplicate or wrong entries in the Open With menu. Resets default apps for file types and takes a few minutes.", bundle: .module),
                            risk: .high, selectedByDefault: false,
                            runner: .user([[lsregister, "-r", "-domain", "local", "-domain", "system", "-domain", "user"]]),
                            requires: [lsregister]),
            MaintenanceTask(id: "dns.flush", title: String(localized: "Flush the DNS cache", bundle: .module),
                            description: String(localized: "Useful when name resolution goes wrong or right after changing DNS settings.", bundle: .module),
                            risk: .low, selectedByDefault: true, runner: .helper, requires: ["/usr/bin/dscacheutil", "/usr/bin/killall"]),
            MaintenanceTask(id: "memory.purge", title: String(localized: "Free inactive memory", bundle: .module),
                            description: String(localized: "Purges the disk cache (purge). macOS manages this itself, so it’s rarely needed; file reads are slower for a while afterwards.", bundle: .module),
                            risk: .medium, selectedByDefault: false, runner: .helper, requires: ["/usr/sbin/purge"]),
            MaintenanceTask(id: "periodic.run", title: String(localized: "Run periodic maintenance scripts", bundle: .module),
                            description: String(localized: "Runs the daily / weekly / monthly scripts (rotates and compresses system logs, cleans temporary files).", bundle: .module),
                            // Removed from macOS 27; kept so older systems still get it.
                            risk: .low, selectedByDefault: false, runner: .helper, requires: ["/usr/sbin/periodic"]),
        ]
        if let brew {
            tasks.append(MaintenanceTask(id: "brew.cleanup", title: String(localized: "Homebrew: remove old versions", bundle: .module),
                                         description: String(localized: "Removes old versions of installed packages and stale downloads (brew cleanup).", bundle: .module),
                                         risk: .low, selectedByDefault: true,
                                         runner: .user([[brew, "cleanup"]]), requires: [brew]))
        }
        if let docker {
            tasks.append(MaintenanceTask(id: "docker.prune", title: String(localized: "Docker cleanup", bundle: .module),
                                         description: String(localized: "Removes stopped containers, unused networks, dangling images and build cache (docker system prune -f). Docker must be running.", bundle: .module),
                                         risk: .medium, selectedByDefault: false,
                                         runner: .user([[docker, "system", "prune", "-f"]]), requires: [docker]))
            tasks.append(MaintenanceTask(id: "docker.builder.all", title: String(localized: "Docker: clear all build cache", bundle: .module),
                                         description: String(localized: "Removes all unused build cache, not only dangling layers (docker builder prune -a -f). The next image builds are slower. Docker must be running.", bundle: .module),
                                         risk: .medium, selectedByDefault: false,
                                         runner: .user([[docker, "builder", "prune", "-a", "-f"]]), requires: [docker]))
            tasks.append(MaintenanceTask(id: "docker.images.unused", title: String(localized: "Docker: remove unused images", bundle: .module),
                                         description: String(localized: "Removes every image no container uses, including tagged images you pulled or built (docker image prune -a -f). They have to be downloaded or rebuilt the next time you need them. Docker must be running.", bundle: .module),
                                         risk: .high, selectedByDefault: false,
                                         runner: .user([[docker, "image", "prune", "-a", "-f"]]), requires: [docker]))
        }
        return tasks
    }()
}

public struct TaskOutcome: Codable, Sendable {
    public let id: String
    public let ok: Bool
    public let dryRun: Bool
    public let output: String
}

public struct MaintenanceRunner: Sendable {
    public let log: OperationLog
    public init(log: OperationLog = .shared) { self.log = log }

    /// Runs user-level tasks. Helper tasks return an outcome explaining they need the app.
    public func run(_ task: MaintenanceTask, dryRun: Bool, timeout: TimeInterval = 300) -> TaskOutcome {
        guard task.isAvailable else { return TaskOutcome(id: task.id, ok: false, dryRun: dryRun, output: "not available on this Mac") }
        guard case .user(let commands) = task.runner else {
            return TaskOutcome(id: task.id, ok: false, dryRun: dryRun, output: "requires root: run it from the MacHelper app (Helper)")
        }
        if dryRun {
            return TaskOutcome(id: task.id, ok: true, dryRun: true, output: commands.map { $0.joined(separator: " ") }.joined(separator: "; "))
        }
        var output = ""
        var ok = true
        for argv in commands {
            let (status, text) = Self.exec(argv, timeout: timeout)
            output += text
            if status != 0 { ok = false; output += "\n(exit \(status))"; break }
        }
        log.append([OperationLog.Entry(time: Date(), command: "optimize", path: "", source: task.id, bytes: 0,
                                       result: ok ? "ok" : "failed", message: ok ? nil : String(output.suffix(300)))])
        return TaskOutcome(id: task.id, ok: ok, dryRun: false, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func exec(_ argv: [String], timeout: TimeInterval) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
