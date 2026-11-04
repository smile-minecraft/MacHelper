import FanControl
import Foundation
import HelperProtocol

/// `MacHelper.app/Contents/MacOS/MacHelper --selftest [--register | --refresh | --reinstall | --unregister]`
///
/// - `--register`   first-time registration
/// - `--refresh`    in-place `register()` when the embedded helper changed (what the app does at launch)
/// - `--reinstall`  unregister + register (fallback if --refresh does not update launchd's constraint)
/// - `--unregister` remove the helper
enum SelfTest {
    static func runAndExit() -> Never {
        let args = CommandLine.arguments
        let client = HelperClient.shared
        func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

        out("bundle:      \(Bundle.main.bundleURL.path)")
        if let info = CodeSigning.currentProcess() {
            out("signature:   id=\(info.identifier ?? "nil") team=\(info.teamID ?? "none (ad-hoc)") cdhash=\(info.cdhash ?? "nil")")
        }
        out("helper hash: embedded=\(client.embeddedHelperHash ?? "nil") registered=\(client.registeredHelperHash ?? "unknown")")
        out("status:      \(client.status.label)\(client.needsReregistration ? "  (needs re-registration)" : "")")

        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            func step(_ name: String, _ body: () async throws -> Void) async {
                do {
                    try await body()
                    out("\(name): ok → \(client.status.label)")
                } catch {
                    let ns = error as NSError
                    out("\(name): FAILED \(error) (\(ns.domain) \(ns.code)) → \(client.status.label)")
                }
            }
            if args.contains("--unregister") { await step("unregister") { try await client.unregister() } }
            if args.contains("--register") { await step("register") { try client.register() } }
            if args.contains("--refresh") {
                await step("refresh") {
                    let did = try client.refreshRegistrationIfNeeded()
                    out("refresh:     \(did ? "re-registered in place" : "not needed")")
                }
            }
            if args.contains("--reinstall") { await step("reinstall") { try await client.reinstall() } }

            // Fan policy from the command line:
            //   --fan auto | --fan fixed:0.4 | --fan curve:quiet|balanced|performance
            //   --watch N   print fan status once per second for N seconds
            if let i = args.firstIndex(of: "--fan"), i + 1 < args.count {
                let spec = args[i + 1]
                var policy: FanPolicy?
                if spec == "auto" {
                    policy = .automatic
                } else if spec.hasPrefix("fixed:"), let f = Double(spec.dropFirst(6)) {
                    policy = FanPolicy(mode: .fixed(fraction: f))
                } else if spec.hasPrefix("curve:"), let p = FanProfile(rawValue: String(spec.dropFirst(6))), let c = p.presetCurve {
                    policy = FanPolicy(mode: .curve(CurveSettings(curve: c)))
                }
                if let policy {
                    do {
                        try await client.applyFanPolicy(policy)
                        out("apply:       \(spec) ok")
                    } catch {
                        out("apply:       \(spec) FAILED \(error)")
                    }
                } else {
                    out("apply:       unknown spec \(spec)")
                }
            }
            if let i = args.firstIndex(of: "--watch"), i + 1 < args.count, let n = Int(args[i + 1]) {
                for t in 0..<n {
                    if let s = try? await client.fanControlStatus(), let f = s.fans.first {
                        out(String(format: "t=%2ds  actual %4.0f  target %4.0f  commanded %@  mode %@  temp %@  hottest %@%@",
                                   t, f.reading.actualRPM, f.reading.targetRPM,
                                   f.commandedRPM.map { String(format: "%4.0f", $0) } ?? "  fw",
                                   "\(f.reading.mode)",
                                   s.controlCelsius.map { String(format: "%.0f°", $0) } ?? "-",
                                   s.hottestCelsius.map { String(format: "%.0f°", $0) } ?? "-",
                                   s.lastError.map { "  ERR \($0)" } ?? ""))
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                sem.signal()
                return
            }

            if client.status == .enabled {
                do {
                    let hs = try await client.handshake()
                    out("handshake:   protocol v\(hs.protocolVersion), helper \(hs.helperVersion)")
                    for f in try await client.readFans() {
                        out("fan \(f.id):       \(Int(f.actualRPM)) rpm, range \(Int(f.minRPM))–\(Int(f.maxRPM)), \(f.mode)")
                    }
                    let s = try await client.fanControlStatus()
                    out("policy:      \(s.policy.mode)")
                    out("control:     source=\(s.controlCelsius.map { "\(Int($0))°C" } ?? "-") hottest=\(s.hottestCelsius.map { "\(Int($0))°C" } ?? "-") sensors=\(s.sensorSource) safety=\(s.safetyTripped) canControl=\(s.canControl)")
                    for f in s.fans {
                        out("  fan \(f.id):    actual \(Int(f.reading.actualRPM)) target \(Int(f.reading.targetRPM)) commanded \(f.commandedRPM.map { "\(Int($0))" } ?? "firmware") mode \(f.reading.mode)")
                    }
                    if let e = s.lastError { out("lastError:   \(e)") }
                } catch {
                    out("error:       \(error)")
                }
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 120) == .timedOut { out("error:       self-test timed out") }
        exit(0)
    }
}
