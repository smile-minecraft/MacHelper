import Foundation
import Testing
@testable import Telemetry

@Suite struct TelemetryClientTests {
    @Test func defaultOffQueuesAndSendsNothing() async {
        let name = makePreferenceSuite()
        defer { removePreferenceSuite(name) }
        let preferences = TelemetryPreferences(suiteName: name, infoDictionary: [:])
        let transport = RecordingTransport()
        let client = TelemetryClient(preferences: preferences, transport: transport)

        #expect((await client.isEnabled) == false)
        await client.recordAppLaunch(coldStartMsBucket: 120)
        await client.recordSectionView("monitor")
        await client.recordAction("refresh", category: "ui")
        await client.recordPerformanceSummary(mainThreadStalls: 2, memoryMBBucket: 320)
        await client.flush()

        #expect(await client.bufferedEventCount == 0)
        #expect(await transport.attemptCount() == 0)
        #expect(UserDefaults(suiteName: name)?.object(forKey: TelemetryPreferences.installIDKey) == nil)
    }

    @Test func turningItOffPurgesTheQueueAndTheAnonymousID() async {
        let name = makePreferenceSuite()
        defer { removePreferenceSuite(name) }
        let preferences = TelemetryPreferences(suiteName: name, infoDictionary: [:])
        let transport = RecordingTransport()
        let client = TelemetryClient(preferences: preferences, transport: transport)

        preferences.setEnabled(true)
        for section in ["overview", "monitor", "health"] {
            await client.recordSectionView(section)
        }
        #expect(await client.bufferedEventCount == 3)
        #expect(preferences.installID != nil)

        await client.setEnabled(false)
        #expect(await client.isEnabled == false)
        #expect(await client.bufferedEventCount == 0)
        #expect(preferences.installID == nil)
        await client.flush()
        #expect(await transport.attemptCount() == 0)
    }

    @Test func boundedBufferDropsTheOldestEvent() async {
        let name = makePreferenceSuite()
        defer { removePreferenceSuite(name) }
        let preferences = TelemetryPreferences(suiteName: name, infoDictionary: [:])
        let transport = RecordingTransport()
        let client = TelemetryClient(preferences: preferences, transport: transport, bufferLimit: 10)

        preferences.setEnabled(true)
        for index in 0..<25 {
            await client.recordSectionView("s\(index)")
        }
        #expect(await client.bufferedEventCount == 10)

        await client.flush()
        let properties = await transport.eventProperties()
        #expect(properties.count == 10)
        #expect(properties.first?["section"] == "s15", "the first 15 events were dropped")
        #expect(properties.last?["section"] == "s24")
        #expect(await client.bufferedEventCount == 0, "a flush empties the buffer")
    }

    @Test func concurrentRecordingStaysWithinTheLimit() async {
        let name = makePreferenceSuite()
        defer { removePreferenceSuite(name) }
        let preferences = TelemetryPreferences(suiteName: name, infoDictionary: [:])
        let transport = RecordingTransport()
        let client = TelemetryClient(preferences: preferences, transport: transport, bufferLimit: 64)
        preferences.setEnabled(true)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<100 {
                        await client.recordAction("refresh", category: "ui")
                    }
                }
            }
        }
        #expect(await client.bufferedEventCount == 64)
    }

    @Test func convenienceEventsArriveSanitizedInOneEnvelope() async throws {
        let name = makePreferenceSuite()
        defer { removePreferenceSuite(name) }
        let preferences = TelemetryPreferences(suiteName: name, infoDictionary: [:])
        let transport = RecordingTransport()
        let client = TelemetryClient(preferences: preferences, transport: transport)
        preferences.setEnabled(true)

        await client.recordAppLaunch(coldStartMsBucket: 450)
        await client.recordSectionView("/Users/alice/private")     // unsafe value is stripped
        await client.recordAction("refresh", category: "ui")
        await client.recordPerformanceSummary(mainThreadStalls: 2, memoryMBBucket: 320)
        await client.flush()

        let envelopes = await transport.envelopes()
        #expect(envelopes.count == 1)
        let envelope = try #require(envelopes.first)
        #expect(envelope.schemaVersion == 1)
        #expect(envelope.installId == preferences.installID)
        #expect(envelope.events.count == 4)
        #expect(envelope.events.map(\.name) == ["app_launch", "section_view", "action", "performance_summary"])
        #expect(envelope.events[0].properties == ["cold_start_ms": "450"])
        #expect(envelope.events[1].properties.isEmpty)
        #expect(envelope.events[2].properties == ["action": "refresh", "category": "ui"])
        #expect(envelope.events[3].properties == ["main_thread_stalls": "2", "memory_mb": "320"])
        #expect(envelope.events.allSatisfy { $0.timestampBucket.range(of: "^[0-9]{4}-", options: .regularExpression) != nil })
    }

    @Test func aFailedBatchIsLoggedAndDroppedWithoutGrowingMemory() async {
        let name = makePreferenceSuite()
        defer { removePreferenceSuite(name) }
        let preferences = TelemetryPreferences(suiteName: name, infoDictionary: [:])
        let transport = RecordingTransport(failuresBeforeSuccess: 1, failure: MockTransportError.rejected)
        let client = TelemetryClient(preferences: preferences, transport: transport)
        preferences.setEnabled(true)

        await client.recordSectionView("monitor")
        await client.flush()
        #expect(await transport.attemptCount() == 1)
        #expect(await client.bufferedEventCount == 0)
    }
}
