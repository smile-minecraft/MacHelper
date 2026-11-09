import Foundation
import Testing
@testable import Storage

/// The background recording agent is unregistered while Sparkle replaces the app
/// bundle, then restored afterwards. These tests pin the stop/restore decisions:
/// restore only what was actually running, and never re-enable a service the user
/// revoked or had turned off.
@Suite struct UpdateAgentHandoffTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func heartbeat(age: TimeInterval, sampleAge: TimeInterval?) -> MonitorAgentHeartbeat {
        MonitorAgentHeartbeat(pid: 4242,
                              lastHeartbeatAt: now.addingTimeInterval(-age),
                              lastSampleAt: sampleAge.map { now.addingTimeInterval(-$0) })
    }

    @Test("Snapshot captures a recorder that is enabled and reporting.")
    func snapshotRunningRecorder() {
        let handoff = UpdateAgentRestorePlanner.snapshot(
            enabledIntent: true, serviceStatus: .enabled,
            heartbeat: heartbeat(age: 10, sampleAge: 20), now: now)
        #expect(handoff.wasEnabled)
        #expect(handoff.wasRunning)
        #expect(handoff.recordedAt == now)
    }

    @Test("Snapshot marks wasEnabled even when the heartbeat went stale.")
    func snapshotStaleHeartbeat() {
        let handoff = UpdateAgentRestorePlanner.snapshot(
            enabledIntent: true, serviceStatus: .enabled,
            heartbeat: heartbeat(age: 600, sampleAge: 600), now: now)
        #expect(handoff.wasEnabled)
        #expect(!handoff.wasRunning)
    }

    @Test("Snapshot without an intent never restores, even with a leftover registration.")
    func snapshotOffIntentStaysOff() {
        let handoff = UpdateAgentRestorePlanner.snapshot(
            enabledIntent: false, serviceStatus: .enabled,
            heartbeat: heartbeat(age: 10, sampleAge: 20), now: now)
        #expect(!handoff.wasEnabled)
        #expect(!handoff.wasRunning)
    }

    @Test("Snapshot when the service was revoked before the update stays off.")
    func snapshotRevokedBeforeUpdate() {
        // The profile still says on, but Login Items no longer has the service; the
        // update must not re-enable it afterwards.
        let handoff = UpdateAgentRestorePlanner.snapshot(
            enabledIntent: true, serviceStatus: .notRegistered,
            heartbeat: heartbeat(age: 10, sampleAge: 20), now: now)
        #expect(!handoff.wasEnabled)
        let restore = UpdateAgentRestorePlanner.restore(handoff: handoff, serviceStatus: .notRegistered)
        #expect(restore == .stayOff)
    }

    @Test("Restore re-registers the agent that was unregistered for the install.")
    func restoreReregisters() {
        let handoff = UpdateAgentHandoff(wasEnabled: true, wasRunning: true, recordedAt: now)
        let restore = UpdateAgentRestorePlanner.restore(handoff: handoff, serviceStatus: .notRegistered)
        #expect(restore == .reregister)
    }

    @Test("Restore republishes when the service survived the update enabled.")
    func restoreRepublishes() {
        let handoff = UpdateAgentHandoff(wasEnabled: true, wasRunning: true, recordedAt: now)
        let restore = UpdateAgentRestorePlanner.restore(handoff: handoff, serviceStatus: .enabled)
        #expect(restore == .republish)
    }

    @Test("Restore stays off while approval is pending.")
    func restorePendingApproval() {
        // The user must approve again in Login Items; the update must not force it.
        let handoff = UpdateAgentHandoff(wasEnabled: true, wasRunning: true, recordedAt: now)
        let restore = UpdateAgentRestorePlanner.restore(handoff: handoff, serviceStatus: .requiresApproval)
        #expect(restore == .stayOff)
    }

    @Test("Restore stays off when there is no handoff.")
    func restoreWithoutHandoff() {
        let restore = UpdateAgentRestorePlanner.restore(handoff: nil, serviceStatus: .notRegistered)
        #expect(restore == .stayOff)
    }

    @Test("A canceled update restores exactly like a completed one.")
    func cancelRestoresLikeCompletion() {
        let handoff = UpdateAgentHandoff(wasEnabled: true, wasRunning: true, recordedAt: now)
        #expect(UpdateAgentRestorePlanner.restore(handoff: handoff, serviceStatus: .notRegistered) == .reregister)
        #expect(UpdateAgentRestorePlanner.restore(handoff: UpdateAgentHandoff(wasEnabled: false, wasRunning: false, recordedAt: now), serviceStatus: .notRegistered) == .stayOff)
    }

    @Test("Handoff round-trips through the store and clears.")
    func handoffStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "update-handoff-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: UpdateAgentHandoffStore.fileName)
        #expect(UpdateAgentHandoffStore.load(from: url) == nil)
        let saved = UpdateAgentHandoff(wasEnabled: true, wasRunning: false, recordedAt: now)
        try UpdateAgentHandoffStore.save(saved, to: url)
        #expect(UpdateAgentHandoffStore.load(from: url) == saved)
        UpdateAgentHandoffStore.clear(from: url)
        #expect(UpdateAgentHandoffStore.load(from: url) == nil)
    }
}
