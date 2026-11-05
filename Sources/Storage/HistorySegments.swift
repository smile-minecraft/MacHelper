import Foundation

/// Splits chronologically ordered points into runs separated by gaps, so charts never
/// draw a line across an interval in which nothing was sampled (sleep, shutdown, or the
/// recorder being off). A gap strictly larger than `maxGap` starts a new segment; points
/// exactly `maxGap` apart stay in the same segment.
public enum HistorySegments {
    public static func split<T>(_ points: [T], time: (T) -> Date, maxGap: TimeInterval) -> [[T]] {
        var segments: [[T]] = []
        var current: [T] = []
        var previous: Date?
        for point in points {
            let t = time(point)
            if let previous, t.timeIntervalSince(previous) > maxGap, !current.isEmpty {
                segments.append(current)
                current = []
            }
            current.append(point)
            previous = t
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }
}
