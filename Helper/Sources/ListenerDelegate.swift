import Foundation
import FanControl
import HelperProtocol
import os
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
        connection.exportedObject = HelperService(driver: driver, engine: engine)
        connection.invalidationHandler = { xpcLog.info("Client disconnected") }
        connection.resume()
        xpcLog.notice("Accepted connection from pid \(connection.processIdentifier)")
        return true
    }
}

final class HelperService: NSObject, HelperXPC, @unchecked Sendable {
    private let driver: FanDriver
    private let engine: FanControlEngine

    init(driver: FanDriver, engine: FanControlEngine) {
        self.driver = driver
        self.engine = engine
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
