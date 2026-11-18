import Foundation
import Testing
@testable import DiskScan

@Suite struct LocalSnapshotsTests {
    static let utc = TimeZone(secondsFromGMT: 0)!

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = Self.utc
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        return components.date!
    }

    @Test func successfulQueriesWithNoSnapshotsAreNone() {
        let result = LocalSnapshots.parse("Snapshots for disk /:\n", exitCode: 0, timeZone: Self.utc)
        #expect(result == .none)
        #expect(result.total == 0)
        #expect(result.dates.isEmpty)
    }

    @Test func snapshotsAreListedNewestFirst() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-11-15-101500.local
        com.apple.TimeMachine.2026-11-17-090000.local
        com.apple.TimeMachine.2026-11-16-000000.local
        """
        let result = LocalSnapshots.parse(output, exitCode: 0, timeZone: Self.utc)
        #expect(result.total == 3)
        #expect(result.dates == [date(2026, 11, 17, 9, 0, 0), date(2026, 11, 16, 0, 0, 0), date(2026, 11, 15, 10, 15, 0)])
    }

    @Test func emptySuccessMessageCountsAsNone() {
        let output = "Snapshots for disk /:\nNo snapshots for disk /\n"
        let result = LocalSnapshots.parse(output, exitCode: 0, timeZone: Self.utc)
        #expect(result == .none)
    }

    @Test func failureIsUnavailableNotNone() {
        let result = LocalSnapshots.parse("", exitCode: 1, error: "tmutil: Operation not permitted", timeZone: Self.utc)
        guard case .unavailable(let reason) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(reason.contains("tmutil"))
        #expect(result.total == 0)
    }

    @Test func failureWithEmptyStderrStillReportsExitCode() {
        let result = LocalSnapshots.parse("", exitCode: 134, timeZone: Self.utc)
        guard case .unavailable(let reason) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(reason.contains("134"))
    }

    @Test func snapshotsWithoutParsableDatesStillCount() {
        let output = "Snapshots for disk /:\ncom.apple.TimeMachine.manual.snapshot\n"
        let result = LocalSnapshots.parse(output, exitCode: 0, timeZone: Self.utc)
        #expect(result.total == 1)
        #expect(result.dates.isEmpty)
    }

    @Test func unrelatedOutputIsIgnored() {
        let output = "Snapshots for disk /:\ncom.apple.TimeMachine.2026-11-17-090000.local\nError measuring total system usage: something\n"
        let result = LocalSnapshots.parse(output, exitCode: 0, timeZone: Self.utc)
        #expect(result.total == 1)
    }

    @Test func duplicateDatesAreKeptInTotalButListedOnce() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-11-17-090000.local
        com.apple.TimeMachine.2026-11-17-090000.local
        """
        let result = LocalSnapshots.parse(output, exitCode: 0, timeZone: Self.utc)
        #expect(result.total == 2)
        #expect(result.dates == [date(2026, 11, 17, 9, 0, 0)])
    }
}
