import Darwin
import Foundation

/// Network traffic of one app (all of its processes) or one standalone process.
public struct ProcessNetworkUsage: Sendable, Hashable, Identifiable {
    /// The enclosing app bundle path, or `name.pid` for a process outside any app.
    public let id: String
    public let name: String
    /// Executable path of the busiest process in the group, when readable.
    public let path: String?
    /// The outermost `.app` bundle the processes belong to.
    public let appPath: String?
    public let processCount: Int
    /// nil on the first snapshot: a rate needs two snapshots of the same process.
    public let inBytesPerSecond: Double?
    public let outBytesPerSecond: Double?
    /// Bytes on the flows `nettop` still tracks for these processes (since each process started).
    public let totalInBytes: UInt64
    public let totalOutBytes: UInt64

    public var totalBytesPerSecond: Double? {
        guard let i = inBytesPerSecond, let o = outBytesPerSecond else { return nil }
        return i + o
    }

    public var totalBytes: UInt64 { totalInBytes &+ totalOutBytes }
}

public struct ProcessNetworkSnapshot: Sendable, Hashable {
    public let capturedAt: Date
    /// Every group with traffic, busiest first (by rate when known, otherwise by total bytes).
    public let items: [ProcessNetworkUsage]
    /// false until the sampler has two snapshots to compare.
    public let hasRates: Bool
}

/// One row of `nettop -P -x -J bytes_in,bytes_out` output.
struct NettopRow: Sendable, Hashable {
    var name: String
    var pid: Int32
    var inBytes: UInt64
    var outBytes: UInt64
}

/// Pure parser for `nettop` CSV. Rows look like `Spotify Helper.48160,7231956,557,`; the
/// header row starts with a comma. The pid follows the last dot, since names may contain dots.
enum NettopParser {
    static func parse(_ text: String) -> [NettopRow] {
        var rows: [NettopRow] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let label = fields.first, !label.isEmpty,
                  let dot = label.lastIndex(of: "."),
                  let pid = Int32(label[label.index(after: dot)...]),
                  let inBytes = UInt64(fields[1].trimmingCharacters(in: .whitespaces)),
                  let outBytes = UInt64(fields[2].trimmingCharacters(in: .whitespaces))
            else { continue }
            rows.append(NettopRow(name: String(label[..<dot]), pid: pid, inBytes: inBytes, outBytes: outBytes))
        }
        return rows
    }
}

/// Per-process network traffic without root, read from `nettop`.
///
/// Each `sample()` runs one `nettop -L 1` snapshot (cumulative bytes per process, about 5 s of
/// wall time but well under 0.1 s of CPU) and compares it with the previous snapshot. Streaming
/// `nettop` in delta mode was measured at over 100 % CPU, so it is never used. The call blocks:
/// run it off the main actor, and only while someone is looking at the numbers.
public final class ProcessNetworkSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: (rows: [Int32: NettopRow], time: Date)?
    private let run: @Sendable () -> String?
    private let resolvePath: @Sendable (Int32) -> String?
    private let now: @Sendable () -> Date

    public init() {
        run = Self.runNettop
        resolvePath = { ProcessSampler.path($0) }
        now = { Date() }
    }

    /// Test seam: canned output, path lookup and clock.
    init(run: @escaping @Sendable () -> String?,
         resolvePath: @escaping @Sendable (Int32) -> String?,
         now: @escaping @Sendable () -> Date) {
        self.run = run
        self.resolvePath = resolvePath
        self.now = now
    }

    /// Forgets the previous snapshot, so the next rates are not computed across a long pause.
    public func reset() {
        lock.withLock { previous = nil }
    }

    public func sample() -> ProcessNetworkSnapshot? {
        guard let output = run() else { return nil }
        let rows = NettopParser.parse(output)
        guard !rows.isEmpty else { return nil }
        let time = now()
        let current = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, b in
            NettopRow(name: a.name, pid: a.pid, inBytes: a.inBytes &+ b.inBytes, outBytes: a.outBytes &+ b.outBytes)
        })
        let prev: (rows: [Int32: NettopRow], time: Date)? = lock.withLock {
            defer { previous = (current, time) }
            return previous
        }
        return Self.snapshot(current: current, previous: prev, now: time, resolvePath: resolvePath)
    }

    /// Groups processes by app and computes rates against the previous snapshot. A process that
    /// is new, or whose counters went backwards (closed flows drop out of `nettop`), counts as
    /// zero for this interval instead of a spike.
    static func snapshot(current: [Int32: NettopRow],
                         previous: (rows: [Int32: NettopRow], time: Date)?,
                         now: Date,
                         resolvePath: (Int32) -> String?) -> ProcessNetworkSnapshot {
        let dt = previous.map { now.timeIntervalSince($0.time) } ?? 0
        let hasRates = previous != nil && dt > 0

        struct Group {
            var name: String
            var path: String?
            var appPath: String?
            var count = 0
            var inRate = 0.0, outRate = 0.0
            var totalIn: UInt64 = 0, totalOut: UInt64 = 0
            var busiest = -1.0
        }
        var groups: [String: Group] = [:]
        for row in current.values {
            var inRate = 0.0, outRate = 0.0
            if hasRates, let old = previous?.rows[row.pid], old.name == row.name {
                inRate = row.inBytes >= old.inBytes ? Double(row.inBytes - old.inBytes) / dt : 0
                outRate = row.outBytes >= old.outBytes ? Double(row.outBytes - old.outBytes) / dt : 0
            }
            guard row.inBytes > 0 || row.outBytes > 0 else { continue }
            let path = resolvePath(row.pid)
            let appPath = path.flatMap(ProcessGrouping.outermostApp)
            let key = appPath ?? "\(row.name).\(row.pid)"
            var g = groups[key] ?? Group(name: appPath.map(ProcessGrouping.appName) ?? path.map { ($0 as NSString).lastPathComponent } ?? row.name,
                                         path: path, appPath: appPath)
            g.count += 1
            g.inRate += inRate
            g.outRate += outRate
            g.totalIn &+= row.inBytes
            g.totalOut &+= row.outBytes
            if inRate + outRate > g.busiest { g.busiest = inRate + outRate; g.path = path }
            groups[key] = g
        }
        let items = groups.map { key, g in
            ProcessNetworkUsage(id: key, name: g.name, path: g.path, appPath: g.appPath, processCount: g.count,
                                inBytesPerSecond: hasRates ? g.inRate : nil, outBytesPerSecond: hasRates ? g.outRate : nil,
                                totalInBytes: g.totalIn, totalOutBytes: g.totalOut)
        }
        .sorted { a, b in
            let ra = a.totalBytesPerSecond ?? 0, rb = b.totalBytesPerSecond ?? 0
            if ra != rb { return ra > rb }
            if a.totalBytes != b.totalBytes { return a.totalBytes > b.totalBytes }
            return a.id < b.id
        }
        return ProcessNetworkSnapshot(capturedAt: now, items: items, hasRates: hasRates)
    }

    /// One snapshot. Gives up after 15 s so a stuck `nettop` cannot hold the loop forever.
    private static func runNettop() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
