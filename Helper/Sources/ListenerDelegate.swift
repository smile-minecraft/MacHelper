import Foundation
import FanControl
import HelperProtocol
import os
import PrivilegedOps
import SMCKit

private let xpcLog = Logger(subsystem: HelperConstants.helperBundleIdentifier, category: "xpc")

enum ClientVerifier {
    /// The app bundle that contains this helper binary (…/MacHelper.app/Contents/MacOS/MacHelperHelper).
    static var enclosingAppURL: URL? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    /// Requirement every connecting client must satisfy. Nil means "refuse everyone".
    static func requirement() -> String? {
        guard let appURL = enclosingAppURL else {
            xpcLog.fault("Helper is not inside an app bundle; refusing all connections")
            return nil
        }
        let appInfo = CodeSigning.info(at: appURL)
        guard appInfo?.identifier == HelperConstants.appBundleIdentifier else {
            xpcLog.fault("Enclosing bundle has unexpected identifier \(appInfo?.identifier ?? "nil", privacy: .public)")
            return nil
        }
        let req = CodeSigning.requirement(identifier: HelperConstants.appBundleIdentifier, expected: appInfo)
        xpcLog.notice("Client requirement: \(req ?? "nil", privacy: .public)")
        return req
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let driver: FanDriver
    private let engine: FanControlEngine

    /// Evaluated per connection: with ad-hoc signing the app's cdhash changes whenever the bundle
    /// is updated, and a long-running helper must pin the bundle as it is now, not as it was at launch.
    private let clientRequirement: @Sendable () -> String?

    /// cdhash of our executable as it was on disk when we launched.
    private let launchedHash: String?
    private let executableURL = Bundle.main.executableURL?.resolvingSymlinksInPath()

    init(driver: FanDriver, engine: FanControlEngine, clientRequirement: @escaping @Sendable () -> String?) {
        self.driver = driver
        self.engine = engine
        self.clientRequirement = clientRequirement
        launchedHash = executableURL.flatMap { CodeSigning.info(at: $0)?.cdhash }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // App update replaced our binary: hand fans back, exit, and let launchd start the new
        // version on the client's retry (MachServices launch on demand).
        if let url = executableURL, let launchedHash,
           let onDisk = CodeSigning.info(at: url)?.cdhash, onDisk != launchedHash {
            xpcLog.notice("Helper binary was updated on disk; exiting so launchd starts the new version")
            driver.restoreAllAutomatic()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
            return false
        }
        guard let clientRequirement = clientRequirement() else { return false }
        // The kernel enforces this on every message, not just at connect time.
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: HelperXPC.self)
        connection.exportedObject = HelperService(driver: driver, engine: engine, clientUID: Int(connection.effectiveUserIdentifier))
        connection.invalidationHandler = { xpcLog.info("Client disconnected") }
        connection.resume()
        xpcLog.notice("Accepted connection from pid \(connection.processIdentifier)")
        return true
    }
}

final class HelperService: NSObject, HelperXPC, @unchecked Sendable {
    private let driver: FanDriver
    private let engine: FanControlEngine
    /// Effective UID of the connected app, from the kernel (not from the app's own claims).
    private let clientUID: Int

    init(driver: FanDriver, engine: FanControlEngine, clientUID: Int) {
        self.driver = driver
        self.engine = engine
        self.clientUID = clientUID
    }

    func handshake(reply: @escaping @Sendable (Int, String) -> Void) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        reply(HelperConstants.protocolVersion, version)
    }

    func readFans(reply: @escaping @Sendable (Data?, String?) -> Void) {
        do {
            reply(try JSONEncoder().encode(driver.readFans()), nil)
        } catch {
            reply(nil, String(describing: error))
        }
    }

    func applyFanPolicy(_ json: Data, reply: @escaping @Sendable (String?) -> Void) {
        do {
            try engine.apply(try JSONDecoder().decode(FanPolicy.self, from: json))
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func fanControlStatus(reply: @escaping @Sendable (Data?, String?) -> Void) {
        do {
            reply(try JSONEncoder().encode(engine.status()), nil)
        } catch {
            reply(nil, String(describing: error))
        }
    }

    func heartbeat(reply: @escaping @Sendable () -> Void) {
        engine.heartbeat()
        reply()
    }

    /// Fixed allowlist: the app can only pick a task id, never supply a command.
    private static let maintenance: [String: [[String]]] = [
        "dns.flush": [["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"]],
        "memory.purge": [["/usr/sbin/purge"]],
        "periodic.run": [["/usr/sbin/periodic", "daily", "weekly", "monthly"]],
    ]

    func systemCleanup(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        let decoded: SystemCleanupRequest
        do { decoded = try JSONDecoder().decode(SystemCleanupRequest.self, from: request) } catch {
            reply(nil, "bad request: \(error)")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                let result = try SystemCleanup.run(decoded)
                if !decoded.dryRun {
                    xpcLog.notice("System cleanup \(decoded.targetIDs.joined(separator: ","), privacy: .public): \(result.count) files, \(result.bytes) bytes")
                }
                reply(try JSONEncoder().encode(result), nil)
            } catch {
                reply(nil, String(describing: error))
            }
        }
    }

    func setSystemDaemonEnabled(_ plistPath: String, enabled: Bool, reply: @escaping @Sendable (String?) -> Void) {
        let label: String
        do { label = try SystemJobControl.validate(plistPath: plistPath, kind: .daemon) } catch {
            reply(String(describing: error))
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let (required, bestEffort) = SystemJobControl.commands(label: label, plistPath: plistPath, domain: "system", enabled: enabled)
            let (status, output) = Self.exec(["/bin/launchctl"] + required)
            guard status == 0 else { reply("launchctl \(required.joined(separator: " ")): \(output) (exit \(status))"); return }
            // Already stopped / already loaded is fine.
            _ = Self.exec(["/bin/launchctl"] + bestEffort)
            xpcLog.notice("\(enabled ? "Enabled" : "Disabled", privacy: .public) system daemon \(label, privacy: .public)")
            reply(nil)
        }
    }

    func dumpBackgroundItems(reply: @escaping @Sendable (String?, String?) -> Void) {
        let uid = clientUID
        DispatchQueue.global(qos: .utility).async {
            guard FileManager.default.isExecutableFile(atPath: BackgroundTaskDump.tool) else {
                reply(nil, "sfltool not available on this macOS")
                return
            }
            let (status, output) = Self.exec([BackgroundTaskDump.tool] + BackgroundTaskDump.arguments, timeout: 30)
            guard status == 0 else { reply(nil, "sfltool dumpbtm: \(output.suffix(300)) (exit \(status))"); return }
            reply(BackgroundTaskDump.filter(output, uid: uid), nil)
        }
    }

    func moveSystemLeftovers(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        let decoded: SystemLeftovers.Request
        do { decoded = try JSONDecoder().decode(SystemLeftovers.Request.self, from: request) } catch {
            reply(nil, "bad request: \(error)")
            return
        }
        guard decoded.paths.count <= SystemLeftovers.maxPaths else { reply(nil, "too many paths"); return }
        let uid = clientUID
        // The caller's own Trash; never root's, never another account's.
        guard uid > 0, let pw = getpwuid(uid_t(uid)), let dir = pw.pointee.pw_dir else {
            reply(nil, "no home folder for uid \(uid)")
            return
        }
        let trash = String(cString: dir) + "/.Trash"
        let owner = SystemLeftovers.Owner(uid: uid_t(uid), gid: pw.pointee.pw_gid)
        DispatchQueue.global(qos: .utility).async {
            let items = decoded.paths.map { path in
                SystemLeftovers.moveToTrash(path, trash: trash, owner: owner) { area in
                    try Self.stopJob(at: path, area: area, uid: uid)
                }
            }
            for item in items where item.error == nil {
                xpcLog.notice("Moved system leftover \(item.path, privacy: .public) to the Trash of uid \(uid)")
            }
            do { reply(try JSONEncoder().encode(SystemLeftovers.Result(items: items)), nil) } catch { reply(nil, "\(error)") }
        }
    }

    /// A launchd plist about to be moved: stop its job first (a loaded job keeps running without
    /// its plist). Apple's and MacHelper's own jobs are refused.
    private static func stopJob(at path: String, area: SystemLeftovers.Area, uid: Int) throws {
        let kind: SystemJobControl.Kind
        switch area.dir {
        case SystemJobControl.Kind.daemon.directory: kind = .daemon
        case SystemJobControl.Kind.agent.directory: kind = .agent
        default: return
        }
        let label: String
        do { label = try SystemJobControl.validate(plistPath: path, kind: kind) } catch let e as SystemJobControl.ValidationError {
            if case .protectedLabel = e { throw e }
            return  // unreadable or odd plist: nothing loaded from it can be stopped by label
        }
        _ = exec(["/bin/launchctl", "bootout", kind == .daemon ? "system/\(label)" : "gui/\(uid)/\(label)"])
    }

    func processCounters(reply: @escaping @Sendable (Data?, String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do { reply(try JSONEncoder().encode(ProcessCounters.readAll()), nil) } catch { reply(nil, "\(error)") }
        }
    }

    private static func exec(_ argv: [String], timeout: TimeInterval = 60) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func runMaintenance(_ taskID: String, reply: @escaping @Sendable (Bool, String) -> Void) {
        guard let commands = Self.maintenance[taskID] else {
            reply(false, "unknown task \(taskID)")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            var output = ""
            for argv in commands {
                guard FileManager.default.isExecutableFile(atPath: argv[0]) else {
                    reply(false, "\(argv[0]) not available on this macOS")
                    return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: argv[0])
                p.arguments = Array(argv.dropFirst())
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { reply(false, "\(error)"); return }
                output += String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { reply(false, output + "(exit \(p.terminationStatus))"); return }
            }
            reply(true, output)
        }
    }
}
