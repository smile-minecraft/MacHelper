import ArgumentParser
import Foundation
import Storage

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show recorded metric history (per-minute averages; 7-day default retention, configurable in the app).",
        discussion: "--range accepts 1h, 24h, 7d (or any number with m/h/d). Read-only. Change the retention in Settings → General → Data management."
    )

    @OptionGroup var output: OutputOptions

    @Option(name: .long, help: "How far back: 1h, 24h, 7d …")
    var range = "24h"

    @Option(name: .long, help: "Bucket size in minutes (default: picked from the range).")
    var bucket: Int?

    func run() throws {
        guard let seconds = Self.parse(range) else { throw ValidationError("Invalid --range \(range)") }
        let bucketSeconds = TimeInterval((bucket ?? (seconds <= 3600 ? 1 : seconds <= 86_400 ? 5 : 30)) * 60)
        guard FileManager.default.fileExists(atPath: MetricsHistory.defaultURL.path) else {
            throw ValidationError("No history yet: MacHelper hasn’t recorded any samples.")
        }
        let history = try MetricsHistory(readOnly: true)
        let samples = try history.samples(since: Date().addingTimeInterval(-seconds), bucket: bucketSeconds)
        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let rangeSeconds: Int; let bucketSeconds: Int; let samples: [MetricSample] }
            return try Output.json(Out(rangeSeconds: Int(seconds), bucketSeconds: Int(bucketSeconds), samples: samples))
        }
        Output.line("\(samples.count) samples over the last \(range) (\(Int(bucketSeconds / 60)) min buckets)")
        let rows: [(String, KeyPath<MetricSample, Double?>, (Double) -> String)] = [
            ("CPU", \.cpu, { String(format: "%.0f%%", $0 * 100) }), ("GPU", \.gpu, { String(format: "%.0f%%", $0 * 100) }),
            ("Memory", \.memory, { String(format: "%.0f%%", $0 * 100) }), ("Temperature", \.temperature, { String(format: "%.0f°C", $0) }),
            ("Fan", \.fan, { String(format: "%.0f rpm", $0) }), ("Power", \.power, { String(format: "%.1f W", $0) }),
            ("Net in", \.networkIn, { Output.bytes(UInt64($0)) + "/s" }), ("Net out", \.networkOut, { Output.bytes(UInt64($0)) + "/s" }),
            ("Disk read", \.diskRead, { Output.bytes(UInt64($0)) + "/s" }), ("Disk write", \.diskWrite, { Output.bytes(UInt64($0)) + "/s" }),
            ("Battery", \.battery, { String(format: "%.0f%%", $0 * 100) }),
        ]
        Output.line("\(Output.pad("", 12)) \(Output.lpad("min", 12)) \(Output.lpad("avg", 12)) \(Output.lpad("max", 12))")
        for (name, key, fmt) in rows {
            let v = samples.compactMap { $0[keyPath: key] }
            guard !v.isEmpty else { continue }
            let avg = v.reduce(0, +) / Double(v.count)
            Output.line("\(Output.pad(name, 12)) \(Output.lpad(fmt(v.min()!), 12)) \(Output.lpad(fmt(avg), 12)) \(Output.lpad(fmt(v.max()!), 12))")
        }
    }

    static func parse(_ s: String) -> TimeInterval? {
        guard let unit = s.last, let n = Double(s.dropLast()), n > 0 else { return nil }
        switch unit { case "m": return n * 60; case "h": return n * 3600; case "d": return n * 86_400; default: return nil }
    }
}
