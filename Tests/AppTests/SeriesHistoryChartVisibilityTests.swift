import AppKit
import Charts
import Foundation
import Storage
import SwiftUI
import Testing
@testable import MacHelper

/// Renders the production sensor-history chart with SwiftUI's `ImageRenderer` and counts the
/// actual colored pixels. This catches the case where a single averaged bucket reaches the chart
/// as one LineMark/AreaMark and Swift Charts draws nothing at all. The chart, its segmentation
/// and its axis code are the production code; only synthetic points and colors come from here.
@Suite(.serialized)
@MainActor
struct SeriesHistoryChartVisibilityTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let red = Color(red: 0.9, green: 0.1, blue: 0.1)
    private let blue = Color(red: 0.1, green: 0.2, blue: 0.9)

    // MARK: - Chart fixtures

    private func bucket(_ minute: Int, minutes: Int = 1, _ value: Double) -> SeriesBucket {
        SeriesBucket(
            time: base.addingTimeInterval(TimeInterval(minute * 60)),
            value: value,
            lastSampleTime: base.addingTimeInterval(TimeInterval((minute + minutes - 1) * 60)),
            storedMinuteCount: minutes)
    }

    private func plot(_ id: String, _ name: String, _ color: Color, _ points: [SeriesBucket]) -> SeriesHistoryChart.Plot {
        SeriesHistoryChart.Plot(id: id, name: name, color: color, points: points)
    }

    private func chart(_ plots: [SeriesHistoryChart.Plot], axis: SeriesHistoryChart.Axis = .history) -> SeriesHistoryChart {
        SeriesHistoryChart(title: "Sensor", plots: plots, format: .percent, axis: axis,
                           valueLabel: { String(format: "%.0f%%", $0 * 100) })
    }

    // MARK: - Bucket visibility

    @Test func oneThirtyMinuteBucketIsVisible() throws {
        let chart = chart([plot("cpu", "CPU", red, [bucket(0, minutes: 30, 0.5)])])
        let pixels = try plotRedPixels(render(chart))
        #expect(pixels > 0, "one 30-minute bucket is visible (\(pixels) red pixels in the plot)")
    }

    @Test func oneTwoMinuteBucketIsVisible() throws {
        let chart = chart([plot("cpu", "CPU", red, [bucket(0, minutes: 2, 0.5)])])
        let pixels = try plotRedPixels(render(chart))
        #expect(pixels > 0, "one 2-minute bucket is visible (\(pixels) red pixels in the plot)")
    }

    @Test func twoContiguousBucketsDrawALine() throws {
        let chart = chart([plot("cpu", "CPU", red, [bucket(0, 0.4), bucket(1, 0.6)])])
        let pixels = try plotRedPixels(render(chart))
        #expect(pixels > 0, "two contiguous buckets draw a line (\(pixels) red pixels in the plot)")
    }

    @Test func twoSingleBucketRunsAreVisible() throws {
        let chart = chart([plot("cpu", "CPU", red, [bucket(0, 0.5), bucket(30, 0.5)])])
        let pixels = try plotRedPixels(render(chart))
        #expect(pixels > 0, "two single-bucket runs are visible (\(pixels) red pixels in the plot)")
    }

    @Test func theGapBetweenTwoRunsIsNotConnected() throws {
        let chart = chart([plot("cpu", "CPU", red, [bucket(0, 0.5), bucket(30, 0.5)])])
        let image = try render(chart)
        let columns = redColumns(image)
        let minX = try #require(columns.min(), "the two single-bucket runs produced no red columns")
        let maxX = try #require(columns.max(), "the two single-bucket runs produced no red columns")
        try #require(maxX > minX, "the two single-bucket runs did not produce separate columns")
        let middle = (minX + maxX) / 2
        let window = max(1, (maxX - minX) / 10)
        let inGap = columns.filter { abs($0 - middle) <= window }.count
        #expect(inGap == 0, "the gap between two single-bucket runs is not connected (\(inGap) red pixels in the middle)")
    }

    // MARK: - One color per series

    @Test func theFirstSeriesKeepsItsColor() throws {
        let chart = chart([
            plot("red", "Red", red, [bucket(0, 0.3)]),
            plot("blue", "Blue", blue, [bucket(0, 0.7)]),
        ])
        let pixels = try plotRedPixels(render(chart))
        #expect(pixels > 0, "the first series keeps its color (\(pixels) red pixels in the plot)")
    }

    @Test func theSecondSeriesKeepsItsColor() throws {
        let chart = chart([
            plot("red", "Red", red, [bucket(0, 0.3)]),
            plot("blue", "Blue", blue, [bucket(0, 0.7)]),
        ])
        let pixels = try plotBluePixels(render(chart))
        #expect(pixels > 0, "the second series keeps its color (\(pixels) blue pixels in the plot)")
    }

    // MARK: - Rendering and pixels

    private func render(_ chart: SeriesHistoryChart) throws -> NSBitmapImageRep {
        let content = ZStack {
            Color.white
            chart
        }
        .frame(width: 360, height: 200)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "ImageRenderer produced no image")
        let tiff = try #require(image.tiffRepresentation, "ImageRenderer produced no TIFF data")
        return try #require(NSBitmapImageRep(data: tiff), "ImageRenderer produced no bitmap")
    }

    private func plotRedPixels(_ rep: NSBitmapImageRep) -> Int {
        plotPixelCount(rep) { color in
            color.alphaComponent > 0.5
                && color.redComponent > 0.55
                && color.greenComponent < 0.45
                && color.blueComponent < 0.45
        }
    }

    private func plotBluePixels(_ rep: NSBitmapImageRep) -> Int {
        plotPixelCount(rep) { color in
            color.alphaComponent > 0.5
                && color.blueComponent > 0.55
                && color.redComponent < 0.45
                && color.greenComponent < 0.45
        }
    }

    private func redColumns(_ rep: NSBitmapImageRep) -> [Int] {
        var columns: [Int] = []
        for x in 0..<rep.pixelsWide {
            for y in plotRange(rep) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.5, color.redComponent > 0.55,
                   color.greenComponent < 0.45, color.blueComponent < 0.45 {
                    columns.append(x)
                    break
                }
            }
        }
        return columns
    }

    /// The header value is drawn in the series color, so counting the whole image would report a
    /// mark even when the chart body is empty. The plot region starts below the header and above
    /// the x-axis labels.
    private func plotRange(_ rep: NSBitmapImageRep) -> Range<Int> {
        let top = min(90, rep.pixelsHigh)
        let bottom = max(top, rep.pixelsHigh - 30)
        return top..<bottom
    }

    private func plotPixelCount(_ rep: NSBitmapImageRep, where matches: (NSColor) -> Bool) -> Int {
        var count = 0
        for y in plotRange(rep) {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if matches(color) { count += 1 }
            }
        }
        return count
    }
}
