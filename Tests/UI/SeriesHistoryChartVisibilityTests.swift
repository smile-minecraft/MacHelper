import AppKit
import Charts
import SwiftUI

// The real chart content reads these app presentation constants. The test supplies only
// these constants; the marks, segmentation and axis code are compiled from the production
// App/Monitor/SeriesHistoryView.swift with -D MACHELPER_CHART_TEST.
enum Palette {
    static let text = Color.black
}

enum Theme {
    static let smallNumeral = Font.system(size: 10, design: .monospaced)
}

extension Font {
    static func mh(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Renders the production chart view with SwiftUI's ImageRenderer and counts the actual
/// colored pixels. This catches the case where a single averaged bucket reaches the chart
/// as one LineMark/AreaMark and Swift Charts draws nothing at all.
@main
struct SeriesHistoryChartVisibilityTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    static func main() {
        let red = Color(red: 0.9, green: 0.1, blue: 0.1)
        let blue = Color(red: 0.1, green: 0.2, blue: 0.9)

        func bucket(_ minute: Int, minutes: Int = 1, _ value: Double) -> SeriesBucket {
            SeriesBucket(
                time: base.addingTimeInterval(TimeInterval(minute * 60)),
                value: value,
                lastSampleTime: base.addingTimeInterval(TimeInterval((minute + minutes - 1) * 60)),
                storedMinuteCount: minutes)
        }
        func plot(_ id: String, _ name: String, _ color: Color, _ points: [SeriesBucket]) -> SeriesHistoryChart.Plot {
            SeriesHistoryChart.Plot(id: id, name: name, color: color, points: points)
        }
        func chart(_ plots: [SeriesHistoryChart.Plot], axis: SeriesHistoryChart.Axis = .history) -> SeriesHistoryChart {
            SeriesHistoryChart(title: "Sensor", plots: plots, format: .percent, axis: axis,
                               valueLabel: { String(format: "%.0f%%", $0 * 100) })
        }

        let oneThirtyMinute = chart([plot("cpu", "CPU", red, [bucket(0, minutes: 30, 0.5)])])
        let thirtyPixels = plotRedPixels(render(oneThirtyMinute))
        check(thirtyPixels > 0, "one 30-minute bucket is visible (\(thirtyPixels) red pixels in the plot)")

        let oneTwoMinute = chart([plot("cpu", "CPU", red, [bucket(0, minutes: 2, 0.5)])])
        let twoPixels = plotRedPixels(render(oneTwoMinute))
        check(twoPixels > 0, "one 2-minute bucket is visible (\(twoPixels) red pixels in the plot)")

        let twoPoints = chart([plot("cpu", "CPU", red, [bucket(0, 0.4), bucket(1, 0.6)])])
        let linePixels = plotRedPixels(render(twoPoints))
        check(linePixels > 0, "two contiguous buckets draw a line (\(linePixels) red pixels in the plot)")

        let gapped = chart([plot("cpu", "CPU", red, [bucket(0, 0.5), bucket(30, 0.5)])])
        let gapImage = render(gapped)
        let gapPixels = plotRedPixels(gapImage)
        check(gapPixels > 0, "two single-bucket runs are visible (\(gapPixels) red pixels in the plot)")
        let columns = redColumns(gapImage)
        if let minX = columns.min(), let maxX = columns.max(), maxX > minX {
            let middle = (minX + maxX) / 2
            let window = max(1, (maxX - minX) / 10)
            let inGap = columns.filter { abs($0 - middle) <= window }.count
            check(inGap == 0, "the gap between two single-bucket runs is not connected (\(inGap) red pixels in the middle)")
        } else {
            check(false, "the two single-bucket runs did not produce separate columns")
        }

        let twoSeries = chart([
            plot("red", "Red", red, [bucket(0, 0.3)]),
            plot("blue", "Blue", blue, [bucket(0, 0.7)]),
        ])
        let twoSeriesImage = render(twoSeries)
        let redPixels = plotRedPixels(twoSeriesImage)
        let bluePixels = plotBluePixels(twoSeriesImage)
        check(redPixels > 0, "the first series keeps its color (\(redPixels) red pixels in the plot)")
        check(bluePixels > 0, "the second series keeps its color (\(bluePixels) blue pixels in the plot)")

        print("Series history chart visibility tests passed.")
    }

    // MARK: Rendering and pixels

    @MainActor
    private static func render(_ chart: SeriesHistoryChart) -> NSBitmapImageRep {
        let content = ZStack {
            Color.white
            chart
        }
        .frame(width: 360, height: 200)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              rep.bitmapData != nil else {
            fail("ImageRenderer produced no bitmap")
        }
        return rep
    }

    private static func plotRedPixels(_ rep: NSBitmapImageRep) -> Int {
        plotPixelCount(rep) { color in
            color.alphaComponent > 0.5
                && color.redComponent > 0.55
                && color.greenComponent < 0.45
                && color.blueComponent < 0.45
        }
    }

    private static func plotBluePixels(_ rep: NSBitmapImageRep) -> Int {
        plotPixelCount(rep) { color in
            color.alphaComponent > 0.5
                && color.blueComponent > 0.55
                && color.redComponent < 0.45
                && color.greenComponent < 0.45
        }
    }

    private static func redColumns(_ rep: NSBitmapImageRep) -> [Int] {
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

    /// The header value is drawn in the series color, so counting the whole image would
    /// report a mark even when the chart body is empty. The plot region starts below the
    /// header and above the x-axis labels.
    private static func plotRange(_ rep: NSBitmapImageRep) -> Range<Int> {
        let top = min(90, rep.pixelsHigh)
        let bottom = max(top, rep.pixelsHigh - 30)
        return top..<bottom
    }

    private static func plotPixelCount(_ rep: NSBitmapImageRep,
                                       where matches: (NSColor) -> Bool) -> Int {
        var count = 0
        for y in plotRange(rep) {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if matches(color) { count += 1 }
            }
        }
        return count
    }

    private static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("PASS: \(message)")
        } else {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
