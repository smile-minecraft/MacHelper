import Foundation
import Testing
@testable import Storage

/// The privileged Helper is registered with launchd/BTM and spoken to over XPC. Both
/// can drift independently across an app update. These tests pin the decisions that
/// keep a Helper which used to work from silently disappearing after an update, and
/// keep a Helper that never worked from raising a false alarm.
@Suite struct HelperUpdateHandoffTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func handoff(wasEnabled: Bool = true,
                         wasHealthy: Bool = true,
                         appVersion: String = "0.4.0",
                         hash: String? = "oldhash",
                         at date: Date? = nil) -> HelperUpdateHandoff {
        HelperUpdateHandoff(wasEnabled: wasEnabled,
                            wasHealthy: wasHealthy,
                            previousAppVersion: appVersion,
                            previousHelperHash: hash,
                            timestamp: date ?? now)
    }

    // MARK: Snapshot and storage

    @Test("Snapshot records everything needed to judge the other side of an update.")
    func snapshotCapturesPreUpdateState() {
        let h = handoff(wasEnabled: true, wasHealthy: true, appVersion: "0.4.0", hash: "abc123")
        #expect(h.wasEnabled)
        #expect(h.wasHealthy)
        #expect(h.previousAppVersion == "0.4.0")
        #expect(h.previousHelperHash == "abc123")
        #expect(h.timestamp == now)
    }

    @Test("Snapshot of a Helper that was off does not claim it worked.")
    func snapshotOfDisabledHelper() {
        let h = handoff(wasEnabled: false, wasHealthy: false, hash: nil)
        #expect(!h.wasEnabled)
        #expect(!h.wasHealthy)
    }

    @Test("Handoff round-trips through the store and can be cleared.")
    func handoffStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "helper-handoff-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: HelperUpdateHandoffStore.fileName)
        #expect(HelperUpdateHandoffStore.load(from: url, now: now) == nil)

        let saved = handoff()
        try HelperUpdateHandoffStore.save(saved, to: url)
        #expect(HelperUpdateHandoffStore.load(from: url, now: now) == saved)

        HelperUpdateHandoffStore.clear(from: url)
        #expect(HelperUpdateHandoffStore.load(from: url, now: now) == nil)
    }

    @Test("An expired handoff is consumed, never replayed.")
    func expiredHandoffIsDiscarded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "helper-handoff-expiry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: HelperUpdateHandoffStore.fileName)
        try HelperUpdateHandoffStore.save(handoff(), to: url)

        let later = now.addingTimeInterval(HelperUpdateHandoff.timeToLive + 1)
        #expect(HelperUpdateHandoffStore.load(from: url, now: later) == nil)
        #expect(HelperUpdateHandoffStore.load(from: url, now: now) == nil,
                "expiry must remove the file so a later read cannot revive it")
    }

    @Test("A handoff from the future is treated as corrupt.")
    func futureHandoffIsDiscarded() {
        #expect(handoff().isExpired(now: now.addingTimeInterval(-120)))
        #expect(!handoff().isExpired(now: now.addingTimeInterval(60)))
    }

    @Test("Cancelling an update clears the pending handoff.")
    func cancellationClearsHandoff() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "helper-handoff-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: HelperUpdateHandoffStore.fileName)
        try HelperUpdateHandoffStore.save(handoff(), to: url)
        HelperUpdateHandoffStore.clear(from: url)
        #expect(HelperUpdateHandoffStore.load(from: url, now: now) == nil)
        #expect(HelperRecoveryPlanner.nextAction(status: .enabled,
                                                  handshakeResult: nil,
                                                  handoff: HelperUpdateHandoffStore.load(from: url, now: now),
                                                  hadPreviouslyWorked: false,
                                                  attemptCount: 0) == .none)
    }

    // MARK: State derivation

    @Test("First launch with no registration is not configured, not a failure.")
    func firstLaunchIsNotConfigured() {
        let state = HelperRecoveryPlanner.evaluateState(
            status: .notRegistered, handshakeResult: nil, handoff: nil, hadPreviouslyWorked: false)
        #expect(state == .notConfigured)
        #expect(!state.needsAttention)
        #expect(HelperRecoveryPlanner.nextAction(status: .notRegistered,
                                                  handshakeResult: nil, handoff: nil,
                                                  hadPreviouslyWorked: false, attemptCount: 0) == .none)
    }

    @Test("A working Helper whose registration vanished after an update is a permission loss.")
    func permissionLostAfterUpdate() {
        let h = handoff()
        let state = HelperRecoveryPlanner.evaluateState(
            status: .notRegistered, handshakeResult: nil, handoff: h, hadPreviouslyWorked: true)
        #expect(state == .permissionLostAfterUpdate)
        #expect(state.needsAttention)
        #expect(HelperRecoveryPlanner.nextAction(status: .notRegistered,
                                                  handshakeResult: nil, handoff: h,
                                                  hadPreviouslyWorked: true, attemptCount: 0) == .reinstall)
        #expect(HelperRecoveryPlanner.nextAction(status: .notRegistered,
                                                  handshakeResult: nil, handoff: h,
                                                  hadPreviouslyWorked: true, attemptCount: 3)
                == .promptUser(.permissionLostAfterUpdate))
    }

    @Test("A missing helper executable after an update is the same permission loss.")
    func notFoundAfterUpdate() {
        let state = HelperRecoveryPlanner.evaluateState(
            status: .notFound, handshakeResult: nil, handoff: handoff(), hadPreviouslyWorked: true)
        #expect(state == .permissionLostAfterUpdate)
    }

    @Test("Post-update approval waits for the user instead of re-registering.")
    func requiresApprovalAfterUpdate() {
        let h = handoff()
        let state = HelperRecoveryPlanner.evaluateState(
            status: .requiresApproval, handshakeResult: nil, handoff: h, hadPreviouslyWorked: true)
        #expect(state == .requiresApproval(afterUpdate: true))
        #expect(HelperRecoveryPlanner.nextAction(status: .requiresApproval,
                                                  handshakeResult: nil, handoff: h,
                                                  hadPreviouslyWorked: true, attemptCount: 0)
                == .promptUser(.requiresApproval(afterUpdate: true)))
    }

    @Test("Approval on first setup stays quiet until the user acts.")
    func firstLaunchApprovalDoesNotAlarm() {
        let state = HelperRecoveryPlanner.evaluateState(
            status: .requiresApproval, handshakeResult: nil, handoff: nil, hadPreviouslyWorked: false)
        #expect(state == .notConfigured)
        #expect(HelperRecoveryPlanner.nextAction(status: .requiresApproval,
                                                  handshakeResult: nil, handoff: nil,
                                                  hadPreviouslyWorked: false, attemptCount: 0) == .none)
    }

    @Test("An enabled Helper with a successful handshake is healthy.")
    func healthyHandshake() {
        let outcome = HelperHandshakeOutcome.success(protocolVersion: 6, helperVersion: "0.4.0")
        let state = HelperRecoveryPlanner.evaluateState(
            status: .enabled, handshakeResult: outcome, handoff: handoff(), hadPreviouslyWorked: true)
        #expect(state == .healthy(helperVersion: "0.4.0"))
        #expect(!state.needsAttention)
        #expect(HelperRecoveryPlanner.nextAction(status: .enabled,
                                                  handshakeResult: outcome, handoff: handoff(),
                                                  hadPreviouslyWorked: true, attemptCount: 0) == .none)
    }

    @Test("An enabled Helper that times out is retried, then softly repaired, then surfaced.")
    func timeoutEscalatesFromRetryToPrompt() {
        let h = handoff()
        let timedOut = HelperHandshakeOutcome.timedOut
        let action = { count in
            HelperRecoveryPlanner.nextAction(status: .enabled,
                                              handshakeResult: timedOut, handoff: h,
                                              hadPreviouslyWorked: true, attemptCount: count)
        }
        #expect(action(0) == .retryHandshake)
        #expect(action(1) == .softReregister)
        #expect(action(2) == .softReregister)
        #expect(action(3) == .promptUser(.unresponsive(
            detail: "The Helper did not answer in time.", afterUpdate: true)))

        let state = HelperRecoveryPlanner.evaluateState(
            status: .enabled, handshakeResult: timedOut, handoff: h, hadPreviouslyWorked: true)
        #expect(state == .unresponsive(detail: "The Helper did not answer in time.", afterUpdate: true))
    }

    @Test("A broken XPC connection follows the same recovery ladder as a timeout.")
    func connectionFailureEscalates() {
        let outcome = HelperHandshakeOutcome.connectionFailed("connection invalidated")
        #expect(HelperRecoveryPlanner.nextAction(status: .enabled,
                                                  handshakeResult: outcome, handoff: handoff(),
                                                  hadPreviouslyWorked: true, attemptCount: 0)
                == .retryHandshake)
        #expect(HelperRecoveryPlanner.nextAction(status: .enabled,
                                                  handshakeResult: outcome, handoff: handoff(),
                                                  hadPreviouslyWorked: true, attemptCount: 2)
                == .softReregister)
    }

    @Test("A protocol mismatch is softly repaired, then reinstalled, then surfaced.")
    func versionMismatchEscalates() {
        let outcome = HelperHandshakeOutcome.versionMismatch(helper: 5, app: 6)
        let state = HelperRecoveryPlanner.evaluateState(
            status: .enabled, handshakeResult: outcome, handoff: handoff(), hadPreviouslyWorked: true)
        #expect(state == .versionMismatch(helper: 5, app: 6))
        #expect(state.isRepairable)
        #expect(HelperRecoveryPlanner.nextAction(status: .enabled,
                                                  handshakeResult: outcome, handoff: handoff(),
                                                  hadPreviouslyWorked: true, attemptCount: 0) == .softReregister)
        #expect(HelperRecoveryPlanner.nextAction(status: .enabled,
                                                  handshakeResult: outcome, handoff: handoff(),
                                                  hadPreviouslyWorked: true, attemptCount: 1) == .reinstall)
        #expect(HelperRecoveryPlanner.nextAction(status: .enabled,
                                                  handshakeResult: outcome, handoff: handoff(),
                                                  hadPreviouslyWorked: true, attemptCount: 2)
                == .promptUser(.versionMismatch(helper: 5, app: 6)))
    }

    @Test("An untrusted signature goes straight to a prompt; reinstall cannot fix it.")
    func untrustedSignaturePrompts() {
        let outcome = HelperHandshakeOutcome.untrustedSignature("no cdhash")
        let state = HelperRecoveryPlanner.evaluateState(
            status: .enabled, handshakeResult: outcome, handoff: handoff(), hadPreviouslyWorked: true)
        #expect(state == .untrustedSignature(detail: "no cdhash"))
        #expect(!state.isRepairable)
        #expect(HelperRecoveryPlanner.nextAction(status: .enabled,
                                                  handshakeResult: outcome, handoff: handoff(),
                                                  hadPreviouslyWorked: true, attemptCount: 0)
                == .promptUser(.untrustedSignature(detail: "no cdhash")))
    }

    @Test("A successful repair clears the alert.")
    func repairClearsAlert() {
        let broken = HelperRecoveryPlanner.evaluateState(
            status: .enabled,
            handshakeResult: .timedOut,
            handoff: handoff(),
            hadPreviouslyWorked: true)
        #expect(broken.needsAttention)

        let repaired = HelperRecoveryPlanner.evaluateState(
            status: .enabled,
            handshakeResult: .success(protocolVersion: 6, helperVersion: "0.5.0"),
            handoff: handoff(),
            hadPreviouslyWorked: true)
        #expect(repaired == .healthy(helperVersion: "0.5.0"))
        #expect(!repaired.needsAttention)
        #expect(HelperRecoveryPlanner.nextAction(status: .enabled,
                                                  handshakeResult: .success(protocolVersion: 6, helperVersion: "0.5.0"),
                                                  handoff: handoff(),
                                                  hadPreviouslyWorked: true, attemptCount: 3) == .none)
    }

    // MARK: Manual DMG updates (no Sparkle handoff)

    @Test("A version change with a previously working Helper is detected as an update.")
    func manualUpdateByVersion() {
        let last = HelperInstallFingerprint(appVersion: "0.4.0", helperHash: "samehash", recordedAt: now)
        let h = HelperRecoveryPlanner.detectUpdate(lastKnownWorking: last,
                                                   currentAppVersion: "0.5.0",
                                                   currentHelperHash: "samehash",
                                                   wasEnabled: true,
                                                   now: now)
        #expect(h != nil)
        #expect(h?.previousAppVersion == "0.4.0")
        #expect(h?.wasHealthy == true)
        #expect(HelperRecoveryPlanner.evaluateState(status: .notRegistered,
                                                    handshakeResult: nil, handoff: h,
                                                    hadPreviouslyWorked: true)
                == .permissionLostAfterUpdate)
    }

    @Test("A helper cdhash change is detected even when the app version is unchanged.")
    func manualUpdateByHelperHash() {
        let last = HelperInstallFingerprint(appVersion: "0.4.0", helperHash: "oldhash", recordedAt: now)
        let h = HelperRecoveryPlanner.detectUpdate(lastKnownWorking: last,
                                                   currentAppVersion: "0.4.0",
                                                   currentHelperHash: "newhash",
                                                   wasEnabled: true,
                                                   now: now)
        #expect(h?.previousHelperHash == "oldhash")
    }

    @Test("An unchanged install, or a Helper that was never on, produces no synthetic handoff.")
    func noFalseManualUpdate() {
        let last = HelperInstallFingerprint(appVersion: "0.4.0", helperHash: "samehash", recordedAt: now)
        #expect(HelperRecoveryPlanner.detectUpdate(lastKnownWorking: last,
                                                   currentAppVersion: "0.4.0",
                                                   currentHelperHash: "samehash",
                                                   wasEnabled: true, now: now) == nil)
        #expect(HelperRecoveryPlanner.detectUpdate(lastKnownWorking: last,
                                                   currentAppVersion: "0.5.0",
                                                   currentHelperHash: "newhash",
                                                   wasEnabled: false, now: now) == nil)
        #expect(HelperRecoveryPlanner.detectUpdate(lastKnownWorking: nil,
                                                   currentAppVersion: "0.5.0",
                                                   currentHelperHash: "newhash",
                                                   wasEnabled: true, now: now) == nil)
    }

    @Test("A recovered Helper can be fingerprinted and stops looking like an update.")
    func recoveredFingerprintStopsDetection() {
        let recovered = HelperInstallFingerprint(appVersion: "0.5.0", helperHash: "newhash", recordedAt: now)
        #expect(HelperRecoveryPlanner.detectUpdate(lastKnownWorking: recovered,
                                                   currentAppVersion: "0.5.0",
                                                   currentHelperHash: "newhash",
                                                   wasEnabled: true, now: now) == nil)
    }
}
