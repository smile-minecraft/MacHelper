import Foundation
import Testing
@testable import Telemetry

@Suite struct TelemetrySanitizerTests {
    @Test func allowsOnlyKnownNames() {
        #expect(TelemetrySanitizer.sanitize(name: "section_view") == "section_view")
        for bad in ["", "SECTION_VIEW", "/Users/alice/secret", "tap alice@example.com", "clean.anything"] {
            #expect(TelemetrySanitizer.sanitize(name: bad) == nil, "\(bad)")
        }
    }

    @Test func stripsPathsEmailsAddressesAndOversizedValues() {
        let sanitized = TelemetrySanitizer.sanitize(properties: [
            "section": "/Users/alice/Documents/secret.txt",
            "category": "alice@example.com",
            "action": "192.168.1.20",
            "memory_mb": "00:1A:2B:3C:4D:5E",
            "cold_start_ms": String(repeating: "1", count: 200),
            "secret": "looks-harmless",
            "main_thread_stalls": "3",
        ])
        #expect(sanitized == ["main_thread_stalls": "3"])
    }

    @Test func rejectsAddressLookalikesWithoutRejectingCoarseBuckets() {
        #expect(!TelemetrySanitizer.isSafeValue("8.8.8.8"))
        #expect(!TelemetrySanitizer.isSafeValue("aa-bb-cc-dd-ee-ff"))
        #expect(!TelemetrySanitizer.isSafeValue("HTTP://example.com/path"))
        #expect(!TelemetrySanitizer.isSafeValue("Alice"))
        for safe in ["monitor", "cold_start_ms", "450", "apple-silicon", "a.b_c-1"] {
            #expect(TelemetrySanitizer.isSafeValue(safe), "\(safe)")
        }
    }

    @Test func sanitizingAnEventKeepsItsTimestampButDropsUnsafeProperties() throws {
        let event = TelemetryEvent(name: "app_launch", timestampBucket: "2026-11-22T14:00:00Z",
                                   properties: ["section": "/Volumes/Backup/report", "cold_start_ms": "450"])
        let clean = try #require(TelemetrySanitizer.sanitize(event: event))
        #expect(clean.name == "app_launch")
        #expect(clean.timestampBucket == "2026-11-22T14:00:00Z")
        #expect(clean.properties == ["cold_start_ms": "450"])
        #expect(TelemetrySanitizer.sanitize(event: TelemetryEvent(name: "unknown", timestampBucket: "x", properties: [:])) == nil)
    }

    @Test func bucketsAreCoarseAndUTC() {
        let date = Date(timeIntervalSince1970: 1_762_000_000)
        let hour = TelemetrySanitizer.bucket(date, granularity: .hour)
        let day = TelemetrySanitizer.bucket(date, granularity: .day)
        #expect(hour.hasPrefix(day))
        #expect(hour.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:00:00Z$", options: .regularExpression) != nil)
        #expect(day.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil)
        #expect(TelemetrySanitizer.bucket(date.addingTimeInterval(60), granularity: .hour) == hour)
        #expect(TelemetrySanitizer.bucket(date.addingTimeInterval(3600), granularity: .hour) != hour)
        #expect(TelemetrySanitizer.bucket(date.addingTimeInterval(3600), granularity: .day) == day)
    }
}

@Suite struct TelemetrySampleTests {
    @Test func samplePayloadIsValidJSONWithSchemaVersionOne() throws {
        let json = TelemetryClient<RecordingTransport>.samplePayloadJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["installId"] as? String == "00000000-0000-0000-0000-000000000000")
        let events = try #require(object["events"] as? [[String: Any]])
        #expect(events.count == 3)
        #expect(events.allSatisfy { ($0["timestampBucket"] as? String)?.isEmpty == false })
    }
}
