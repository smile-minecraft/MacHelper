import Foundation
import Testing
@testable import Diagnostics

@Suite struct SecurityAuditTests {
    @Test func parsesStatusOutputs() {
        #expect(SecurityAudit.gatekeeper("assessments enabled\n").state == .on)
        #expect(SecurityAudit.gatekeeper("assessments disabled\n").state == .off)
        #expect(SecurityAudit.gatekeeper(nil).state == .unknown)
        #expect(SecurityAudit.fileVault("FileVault is On.\n").state == .on)
        #expect(SecurityAudit.fileVault("FileVault is Off.\n").state == .off)
        #expect(SecurityAudit.fileVault("Encryption in progress: Percent completed = 42.0\n").state == .partial)
        #expect(SecurityAudit.firewall("Firewall is disabled. (State = 0)", stealth: nil).state == .off)
        #expect(SecurityAudit.firewall("Firewall is enabled. (State = 1)", stealth: "Firewall stealth mode is on") == .init(id: "firewall", state: .on, detail: "stealth"))
        #expect(SecurityAudit.firewall("Firewall is blocking all non-essential incoming connections. (State = 2)", stealth: nil).state == .on)
        #expect(SecurityAudit.sip("System Integrity Protection status: enabled.").state == .on)
        #expect(SecurityAudit.sip("System Integrity Protection status: enabled (Custom Configuration).").state == .partial)
        #expect(SecurityAudit.sip("System Integrity Protection status: disabled.").state == .off)
    }

    @Test func automaticUpdatesDefaultToOn() {
        #expect(SecurityAudit.automaticUpdates([:]).state == .on, "missing keys mean the default, which is on")
        #expect(SecurityAudit.automaticUpdates(["CriticalUpdateInstall": 0, "ConfigDataInstall": 0]).state == .off)
        #expect(SecurityAudit.automaticUpdates(["CriticalUpdateInstall": true, "ConfigDataInstall": false]) == .init(id: "updates", state: .partial, detail: "config-off"))
        #expect(SecurityAudit.automaticUpdates(nil).state == .unknown)
    }

    @Test func xprotectVersion() {
        #expect(SecurityAudit.xprotect("Version: 5347 Installed: 2026-06-18 01:12:21 +0000\n", bundleVersion: "5287")
                == .init(id: "xprotect", state: .info, detail: "5347 2026-06-18"))
        #expect(SecurityAudit.xprotect(nil, bundleVersion: "5287").detail == "5287")
        #expect(SecurityAudit.xprotect(nil, bundleVersion: nil).state == .unknown)
    }

    @Test func runsOnThisMacInFixedOrder() {
        let checks = SecurityAudit.run()
        #expect(checks.map(\.id) == SecurityAudit.ids)
        // SIP and Gatekeeper are readable by any user on a normal Mac.
        #expect(checks.first { $0.id == "sip" }?.state != .unknown)
    }
}
