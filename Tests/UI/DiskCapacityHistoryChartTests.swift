import AppKit
import Foundation
import Storage
import SwiftUI
import Testing
@testable import DiskCapacityHistoryFeature

/// The chart is tested from synthetic points only. Nothing here reads the disk, opens the
/// history database, starts the app or the helper, or touches user preferences. The rendering
/// checks compile the production `DiskCapacityHistoryChart` and count its actual pixels; the
/// test does not copy the chart's filtering, segmentation or drawing code.
@Suite(.serialized) struct DiskCapacityHistoryChartTests {
    private let hour: TimeInterval = 3_600
    private let gigabyte: Double = 1_000_000_000
    /// 1_800_000_000 is a whole hour, so `now` itself is an hourly boundary.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(_ volume: String = "disk-a",
                       hoursAgo: Double,
                       free: Double,
                       total: Double = 1_000_000_000_000) -> VolumeCapacityPoint {
        VolumeCapacityPoint(volume: volume,
                            time: now.addingTimeInterval(-hoursAgo * hour),
                            free: free,
                            total: total)
    }

    // MARK: - Window and volume

    @Test func keepsOnlyTheSelectedVolumeInsideTheSevenDayWindow() {
        let points = [
            point(hoursAgo: 24 * 8, free: 100),          // older than seven days
            point("disk-b", hoursAgo: 12, free: 200),    // another volume
            point(hoursAgo: 12, free: 300),
            point(hoursAgo: -1, free: 400),              // clock skew into the future
            point(hoursAgo: 0, free: 500),
        ]
        let series = DiskCapacityHistorySeries(points: points, volumeID: "disk-a", now: now)

        #expect(series.points.map(\.volume) == ["disk-a", "disk-a"])
        #expect(series.points.map(\.free) == [300, 500])
        #expect(series.latest?.free == 500)
        #expect(series.windowStart == now.addingTimeInterval(-7 * 86_400))
        #expect(series.windowEnd == now)
    }

    @Test func includesAReadingExactlySevenDaysOldAndExcludesOneSecondOlder() {
        let boundary = point(hoursAgo: 24 * 7, free: 100)
        let older = point(hoursAgo: 24 * 7 + 1.0 / 3600.0, free: 50)
        let series = DiskCapacityHistorySeries(points: [older, boundary], volumeID: "disk-a", now: now)
        #expect(series.points.map(\.free) == [100])
    }

    @Test func noPointsForAnotherVolumeShowsTheEmptyState() {
        let series = DiskCapacityHistorySeries(points: [point("disk-b", hoursAgo: 2, free: 100)],
                                               volumeID: "disk-a", now: now)
        #expect(series.state == .empty)
        #expect(series.points.isEmpty)
        #expect(series.latest == nil)
        #expect(series.freeDomain == nil)
    }

    // MARK: - Gaps and single readings

    @Test func hourlyCadenceStaysConnectedAndLongerGapsSplit() {
        let series = DiskCapacityHistorySeries(points: [
            point(hoursAgo: 5, free: 1),
            point(hoursAgo: 4, free: 2),   // exactly one hour later
            point(hoursAgo: 2, free: 3),   // two hours later
            point(hoursAgo: 1, free: 4),   // exactly one hour later
        ], volumeID: "disk-a", now: now)

        #expect(series.segments.map { $0.points.map(\.free) } == [[1, 2], [3, 4]])
        // The missing hour is absent, not filled with a zero.
        #expect(series.points.map(\.free) == [1, 2, 3, 4])
    }

    @Test func oneSecondOverTheHourlyIntervalStartsANewSegment() {
        let first = VolumeCapacityPoint(volume: "disk-a",
                                        time: now.addingTimeInterval(-2 * hour),
                                        free: 1,
                                        total: 1_000)
        let second = VolumeCapacityPoint(volume: "disk-a",
                                         time: first.time.addingTimeInterval(hour + 1),
                                         free: 2,
                                         total: 1_000)
        let series = DiskCapacityHistorySeries(points: [first, second], volumeID: "disk-a", now: now)
        #expect(series.segments.count == 2)
    }

    @Test func singleReadingIsKeptAsASingleVisibleSegment() {
        let series = DiskCapacityHistorySeries(points: [point(hoursAgo: 12, free: 500 * gigabyte)],
                                               volumeID: "disk-a", now: now)
        #expect(series.state == .single(series.points[0]))
        #expect(series.segments.count == 1)
        #expect(series.segments[0].points.count == 1)
        let domain = series.freeDomain
        #expect(domain != nil)
        #expect(domain?.contains(500 * gigabyte) == true)
    }

    @Test func flatSeriesStillGetsAVisibleYDomain() {
        let series = DiskCapacityHistorySeries(points: [
            point(hoursAgo: 2, free: 400 * gigabyte),
            point(hoursAgo: 1, free: 400 * gigabyte),
        ], volumeID: "disk-a", now: now)
        let domain = series.freeDomain
        #expect(domain != nil)
        #expect((domain?.upperBound ?? 0) > (domain?.lowerBound ?? 0))
        #expect(domain?.contains(400 * gigabyte) == true)
    }

    // MARK: - Values and summary

    @Test func summaryUsesTheFilteredValues() {
        let series = DiskCapacityHistorySeries(points: [
            point(hoursAgo: 3, free: 100 * gigabyte),
            point(hoursAgo: 2, free: 150 * gigabyte),
            point(hoursAgo: 1, free: 120 * gigabyte),
        ], volumeID: "disk-a", now: now)
        let english = Locale(identifier: "en_US_POSIX")
        #expect(series.accessibilityValue(locale: english)
                == "Latest 120 GB, lowest 100 GB, highest 150 GB")
    }

    @Test func singleAndEmptySummariesAreClear() {
        let english = Locale(identifier: "en_US_POSIX")
        let single = DiskCapacityHistorySeries(points: [point(hoursAgo: 1, free: 120 * gigabyte)],
                                               volumeID: "disk-a", now: now)
        #expect(single.accessibilityValue(locale: english) == "One reading: 120 GB")
        let empty = DiskCapacityHistorySeries(points: [], volumeID: "disk-a", now: now)
        #expect(empty.accessibilityValue(locale: english) == "No capacity readings in the last seven days")
    }

    @Test func formatsBytesWithDecimalUnitsAndTheCallersLocale() {
        let english = Locale(identifier: "en_US_POSIX")
        #expect(DiskCapacityHistoryFormat.bytes(0, locale: english) == "0 B")
        #expect(DiskCapacityHistoryFormat.bytes(1_500, locale: english) == "1.5 KB")
        #expect(DiskCapacityHistoryFormat.bytes(1_000_000_000, locale: english) == "1 GB")
        #expect(DiskCapacityHistoryFormat.bytes(931_200_000_000, locale: english) == "931.2 GB")
        #expect(DiskCapacityHistoryFormat.bytes(1_234_567_890, locale: english) == "1.23 GB")
        #expect(DiskCapacityHistoryFormat.bytes(-5, locale: english) == "0 B")
        let spanish = Locale(identifier: "es_ES")
        #expect(DiskCapacityHistoryFormat.bytes(931_200_000_000, locale: spanish) == "931,2 GB")
    }

    // MARK: - Dedicated catalog

    @Test func catalogCoversEveryTextInEveryLanguage() throws {
        let resources = try resourcesURL()
        let data = try Data(contentsOf: resources.appendingPathComponent("DiskCapacityHistory.xcstrings"))
        let object = try JSONSerialization.jsonObject(with: data)
        let document = try #require(object as? [String: Any])
        #expect(document["sourceLanguage"] as? String == "en")
        let strings = try #require(document["strings"] as? [String: Any])

        let expectedKeys = Set(DiskCapacityHistoryText.allCases.map(\.rawValue))
        #expect(Set(strings.keys) == expectedKeys)
        let languages = ["es", "ja", "ko", "zh-Hans", "zh-Hant"]
        for key in expectedKeys {
            let entry = try #require(strings[key] as? [String: Any], "\(key) is missing")
            let localizations = try #require(entry["localizations"] as? [String: Any], "\(key) has no localizations")
            #expect(Set(localizations.keys) == Set(languages), "\(key) has \(localizations.keys.sorted())")
            for language in languages {
                let unit = try #require((localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any],
                                        "\(key) [\(language)] has no string unit")
                #expect(unit["state"] as? String == "translated")
                let value = try #require(unit["value"] as? String)
                #expect(!value.isEmpty)
            }
        }
    }

    @Test func formatTranslationsKeepTheirPlaceholders() throws {
        let resources = try resourcesURL()
        let data = try Data(contentsOf: resources.appendingPathComponent("DiskCapacityHistory.xcstrings"))
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(document["strings"] as? [String: Any])
        for key in ["One reading: %@", "Latest %@, lowest %@, highest %@"] {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let sourceCount = key.components(separatedBy: "%@").count - 1
            for (language, value) in localizations {
                let unit = try #require((value as? [String: Any])?["stringUnit"] as? [String: Any])
                let translated = try #require(unit["value"] as? String)
                #expect(translated.components(separatedBy: "%@").count - 1 == sourceCount,
                        "\(language) changed the placeholders in \(key)")
            }
        }
    }

    @Test func catalogSpotChecksUseTheRightLanguage() throws {
        let resources = try resourcesURL()
        func localized(_ text: DiskCapacityHistoryText, _ language: String) throws -> String {
            let bundle = try #require(Bundle(url: resources.appendingPathComponent("Localizations/\(language).lproj")))
            return text.localized(in: bundle)
        }
        #expect(try localized(.title, "ja") == "空き容量（過去7日間）")
        #expect(try localized(.title, "zh-Hant") == "可用空間，最近 7 天")
        #expect(try localized(.noHistory, "zh-Hans") == "还没有容量记录")
        #expect(try localized(.oneReading, "es") == "Una lectura hasta ahora")
        #expect(try localized(.latest, "ko") == "최신")
    }

    @Test func compiledTablesResolveEveryTextForEveryLanguage() throws {
        let resources = try resourcesURL()
        let languages = ["es", "ja", "ko", "zh-Hans", "zh-Hant"]
        let keys = Set(DiskCapacityHistoryText.allCases.map(\.rawValue))
        for language in languages {
            let lproj = resources.appendingPathComponent("Localizations/\(language).lproj")
            let bundle = try #require(Bundle(url: lproj), "\(language) bundle is missing")
            let table = try #require(NSDictionary(contentsOf: lproj.appendingPathComponent("DiskCapacityHistory.strings")) as? [String: String],
                                     "\(language) table is missing")
            #expect(Set(table.keys) == keys, "\(language) table keys differ")
            for text in DiskCapacityHistoryText.allCases {
                #expect(table[text.rawValue] != nil, "\(language) is missing \(text.rawValue)")
                #expect(text.localized(in: bundle) == table[text.rawValue],
                        "\(language) lookup differs for \(text.rawValue)")
            }
        }
    }

    // MARK: - Rendered at the menu width

    @Test @MainActor func singleReadingDrawsAVisiblePoint() throws {
        let chart = DiskCapacityHistoryChart(points: [point(hoursAgo: 36, free: 500 * gigabyte)],
                                             volumeID: "disk-a", now: now)
        let image = try render(chart)
        let pixels = redPixelCount(image, rows: plotRows(image))
        #expect(pixels > 0, "a single hourly reading must draw a visible point")
    }

    @Test @MainActor func singleReadingAtTheWindowEdgesStaysVisible() throws {
        for hoursAgo in [0.0, 168.0] {
            let chart = DiskCapacityHistoryChart(points: [point(hoursAgo: hoursAgo, free: 500 * gigabyte)],
                                                 volumeID: "disk-a", now: now)
            let image = try render(chart)
            let pixels = redPixelCount(image, rows: plotRows(image))
            #expect(pixels > 0, "a single reading at \(hoursAgo) hours ago must be visible")
        }
    }

    @Test @MainActor func aLongGapIsNotConnected() throws {
        let points = [
            point(hoursAgo: 144, free: 500 * gigabyte),
            point(hoursAgo: 143, free: 500 * gigabyte),
            point(hoursAgo: 48, free: 500 * gigabyte),
            point(hoursAgo: 47, free: 500 * gigabyte),
        ]
        let chart = DiskCapacityHistoryChart(points: points, volumeID: "disk-a", now: now)
        let image = try render(chart)
        let rows = plotRows(image)
        let columns = redColumns(image, rows: rows)
        let minX = try #require(columns.min())
        let maxX = try #require(columns.max())
        #expect(maxX > minX)

        let middle = (minX + maxX) / 2
        let window = max(2, (maxX - minX) / 10)
        let inGap = columns.filter { abs($0 - middle) <= window }.count
        #expect(inGap == 0, "the chart connected across a gap: \(inGap) colored columns in the middle")
    }

    @Test @MainActor func emptyAndSingleStatesRenderAtTheMenuWidth() throws {
        let empty = try render(DiskCapacityHistoryChart(points: [], volumeID: "disk-a", now: now))
        #expect(empty.size.width == 460)
        #expect(empty.size.height > 0)
        #expect(redPixelCount(empty, rows: plotRows(empty)) == 0)

        let single = try render(DiskCapacityHistoryChart(points: [point(hoursAgo: 12, free: 500 * gigabyte)],
                                                        volumeID: "disk-a", now: now))
        #expect(single.size.width == 460)
        // The single-reading note sits below the plot, so this state is taller than the
        // empty state's fixed-height explanation.
        #expect(single.size.height > empty.size.height)
    }

    @Test @MainActor func rendersAtALargerTextSize() throws {
        // The app's text-size setting can grow the labels; the chart must still render at the
        // menu width. The stub scales the font without reading ThemeStore.
        DiskCapacityHistoryTestFontScale.value = 1.6
        defer { DiskCapacityHistoryTestFontScale.value = 1 }

        let full = DiskCapacityHistoryChart(points: [
            point(hoursAgo: 3, free: 400 * gigabyte),
            point(hoursAgo: 2, free: 500 * gigabyte),
        ], volumeID: "disk-a", now: now)
        let empty = DiskCapacityHistoryChart(points: [], volumeID: "disk-a", now: now)
        for image in [try render(full), try render(empty)] {
            #expect(image.size.width == 460)
            #expect(image.size.height > 0)
        }
    }

    @Test @MainActor func rendersAtThePanelsContentWidth() throws {
        let chart = DiskCapacityHistoryChart(points: [
            point(hoursAgo: 3, free: 400 * gigabyte),
            point(hoursAgo: 2, free: 500 * gigabyte),
        ], volumeID: "disk-a", now: now)
        let image = try render(chart, width: 420)
        #expect(image.size.width == 420)
        #expect(redPixelCount(image, rows: plotRows(image)) > 0)
    }

    // MARK: - Rendering helpers

    @MainActor
    private func render(_ view: some View, width: CGFloat = 460) throws -> NSBitmapImageRep {
        let content = ZStack {
            Color.white
            view
        }
        .frame(width: width)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.nsImage, "ImageRenderer produced no image")
        let tiff = try #require(image.tiffRepresentation, "ImageRenderer produced no TIFF data")
        return try #require(NSBitmapImageRep(data: tiff), "ImageRenderer produced no bitmap")
    }

    /// The header is above the 140 pt plot; the x-axis labels sit at the bottom. Counting only
    /// the plot body keeps the colored latest value in the header from counting as a mark.
    private func plotRows(_ rep: NSBitmapImageRep) -> Range<Int> {
        let top = min(24, rep.pixelsHigh)
        let bottom = max(top, rep.pixelsHigh - 20)
        return top..<bottom
    }

    private func redPixelCount(_ rep: NSBitmapImageRep, rows: Range<Int>) -> Int {
        var count = 0
        for y in rows {
            for x in 0..<rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y), isStrongRed(color) { count += 1 }
            }
        }
        return count
    }

    private func redColumns(_ rep: NSBitmapImageRep, rows: Range<Int>) -> [Int] {
        var columns: [Int] = []
        for x in 0..<rep.pixelsWide {
            for y in rows {
                if let color = rep.colorAt(x: x, y: y), isStrongRed(color) {
                    columns.append(x)
                    break
                }
            }
        }
        return columns
    }

    private func isStrongRed(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.deviceRGB) else { return false }
        return c.alphaComponent > 0.5
            && c.redComponent > 0.6
            && c.greenComponent < 0.35
            && c.blueComponent < 0.35
    }

    // MARK: - Resources

    private func resourcesURL() throws -> URL {
        let bundle = Bundle.module
        let url = try #require(bundle.resourceURL?.appendingPathComponent("Resources"),
                               "test resources are missing")
        return url
    }
}
