import AppKit
import Diagnostics
import DiskScan
import Foundation
import Metrics
import SMCKit
import Storage

/// Made-up readings for previewing pages this Mac has no hardware for, e.g. the battery page on a
/// Mac mini: `make run ARGS=--demo-battery`. Debug builds only; a release build ignores the flag.
///
/// The demo battery discharges for seven minutes and charges for three, over and over, so the
/// drawn battery, the status and the charge history all move. Its values never reach the
/// history database: the minute rows keep only real measurements.
///
/// `--snapshot-demo DIR` (see `DemoSnapshotRenderer`) goes further: every page reads the
/// synthetic Mac below instead of this one, so the README screenshots never show a real
/// user name, folder, app list or reading.
enum DemoData {
    #if DEBUG
    static let battery = CommandLine.arguments.contains("--demo-battery")
    /// The whole app runs on synthetic data: no sampler, Helper, history database, saved scan or
    /// update check is touched. Set only by `--snapshot-demo`.
    static let snapshot = CommandLine.arguments.contains("--snapshot-demo")
    #else
    static let battery = false
    static let snapshot = false
    #endif

    /// What the synthetic Mac reports about itself (overview machine line and uptime). Kept
    /// outside `#if DEBUG` because `Host` reads them behind `snapshot`, which is always false
    /// in a release build.
    static let demoModelName = "Apple M4 Pro (Mac mini)"
    static let demoOSVersion = "macOS 26.1"
    static let demoUptime: TimeInterval = 15 * 86_400 + 6 * 3_600 + 12 * 60

    static func batteryReading(at date: Date = Date()) -> BatteryReading {
        let period = 600.0, discharge = 420.0
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        let charging = t >= discharge
        let charge = charging
            ? 0.62 + 0.24 * (t - discharge) / (period - discharge)
            : 0.86 - 0.24 * t / discharge
        let wobble = sin(date.timeIntervalSinceReferenceDate / 7)
        return BatteryReading(charge: charge, isCharging: charging, externalPower: charging,
                              watts: charging ? 18.5 + wobble : -(9.4 + 1.2 * wobble),
                              cycleCount: 214, health: 0.912, celsius: 30.8 + 1.5 * wobble)
    }

    /// Accessories added next to the real ones, so the accessory rows show every kind of detail
    /// (earbuds with a case, a charging device).
    static var accessories: [AccessoryBatteryReading] {
        guard battery else { return [] }
        return [
            AccessoryBatteryReading(id: "demo.airpods", name: "AirPods Pro", kind: .headphones, charge: 0.46,
                                    components: [.init(id: .left, charge: 0.78), .init(id: .right, charge: 0.81),
                                                 .init(id: .chargingCase, charge: 0.46)]),
            AccessoryBatteryReading(id: "demo.trackpad", name: "Magic Trackpad", kind: .trackpad, charge: 0.34,
                                    isCharging: true),
        ]
    }
}

#if DEBUG
// MARK: - Synthetic Mac for `--snapshot-demo`

/// A healthy, made-up Mac mini: every value below is invented, and nothing here reads the
/// machine it runs on. Readings are smooth waves that land exactly on the headline values "now",
/// so the README numbers stay the same on every run.
extension DemoData {
    static let gigabyte = 1_000_000_000.0
    static let memoryTotal: UInt64 = 32 * 1_073_741_824
    static let diskTotal = 494.38 * gigabyte
    static let diskFree = 248.6 * gigabyte
    static let homePath = "/Users/alex"
    /// Modules the synthetic Mac has: a desktop with fans, so no battery.
    static let modules: Set<MonitorModule> = [.cpu, .gpu, .memory, .disk, .network, .temperature, .fan, .power]
    /// Seconds of live history drawn before "now" (the store keeps 330 s).
    static let liveSpan = 330

    /// A smooth wave that is exactly `value` at offset 0 and drifts around it before.
    private static func wave(_ s: Double, _ value: Double, _ parts: [(amp: Double, period: Double, phase: Double)]) -> Double {
        value + parts.reduce(0) { $0 + $1.amp * (sin(s / $1.period + $1.phase) - sin($1.phase)) }
    }

    // MARK: Readings

    /// Every module's reading `offset` seconds before now (offset ≤ 0).
    static func samples(offset s: Double) -> [ModuleSample] {
        let cpuTotal = max(0.04, wave(s, 0.18, [(0.07, 41, 0.6), (0.035, 13, 1.9), (0.015, 5.3, 0.2)]))
        let gpu = max(0.01, wave(s, 0.12, [(0.06, 29, 2.4), (0.03, 9, 0.7)]))
        let memory = wave(s, 0.54, [(0.012, 97, 1.1), (0.004, 23, 0.3)])
        let celsius = wave(s, 46, [(2.4, 53, 0.9), (0.8, 17, 2.2)])
        let rpm = wave(s, 1_850, [(110, 61, 1.4), (35, 19, 0.5)])
        let watts = max(4, wave(s, 11.2, [(3.4, 37, 0.4), (1.2, 11, 2.8)]))
        let download = max(40_000, wave(s, 2_400_000, [(1_300_000, 23, 1.7), (500_000, 7, 0.4)]))
        let upload = max(8_000, wave(s, 180_000, [(90_000, 31, 0.2), (40_000, 9, 1.3)]))
        let read = max(50_000, wave(s, 3_200_000, [(1_900_000, 27, 2.1), (600_000, 8, 0.9)]))
        let write = max(20_000, wave(s, 1_100_000, [(700_000, 33, 0.8), (250_000, 11, 2.6)]))
        let perf = min(1, cpuTotal * 1.35), eff = cpuTotal * 0.55
        let used = UInt64(Double(memoryTotal) * memory)
        return [
            .cpu(make(["total": cpuTotal, "performance": perf, "efficiency": eff,
                       "perCore": Array(repeating: cpuTotal, count: 14),
                       "coreKinds": Array(repeating: "performance", count: 10) + Array(repeating: "efficiency", count: 4),
                       "system": cpuTotal * 0.35, "user": cpuTotal * 0.65])),
            .gpu(make(["name": "Apple M4 Pro", "utilization": gpu])),
            .memory(make(["totalBytes": memoryTotal, "usedBytes": used, "appBytes": UInt64(Double(used) * 0.62),
                          "wiredBytes": UInt64(Double(used) * 0.24), "compressedBytes": UInt64(Double(used) * 0.14),
                          "swapUsedBytes": UInt64(1.3 * gigabyte), "pressure": MemoryReading.Pressure.normal.rawValue])),
            .disk(make(["readBytesPerSecond": read, "writeBytesPerSecond": write,
                        "availableBytes": Int64(diskFree), "totalBytes": Int64(diskTotal)])),
            .network(make(["inBytesPerSecond": download, "outBytesPerSecond": upload])),
            .temperature([
                temperature("CPU Performance Cores", celsius, "cpu"),
                temperature("CPU Efficiency Cores", celsius - 5.5, "cpu"),
                temperature("GPU", celsius - 3.1, "gpu"),
                temperature("Memory", celsius - 7.4, "memory"),
                temperature("SSD", 36.5, "storage"),
            ]),
            .fan([FanReading(id: 0, actualRPM: rpm, targetRPM: 1_850, minRPM: 1_000, maxRPM: 4_900, mode: .automatic)]),
            .power(make(["cpuWatts": watts * 0.46, "gpuWatts": watts * 0.18, "aneWatts": 0.0, "dramWatts": watts * 0.08,
                         "systemWatts": watts, "hasSystemRail": true, "channels": [String: Double]()])),
        ]
    }

    private static func temperature(_ name: String, _ celsius: Double, _ category: String) -> TemperatureReading {
        make(["name": name, "celsius": celsius, "category": category])
    }

    /// The Metrics readings only expose memberwise initializers inside their module; they are
    /// Codable, so the demo builds them from their coded form.
    private static func make<T: Decodable>(_ fields: [String: Any]) -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: fields)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            fatalError("Demo data for \(T.self) is out of date: \(error)")
        }
    }

    // MARK: Apps

    private struct DemoApp {
        let name: String
        let bundleID: String
        let fallback: String
        let cpu: Double
        let memoryGB: Double
    }

    private static let apps: [DemoApp] = [
        DemoApp(name: "Xcode", bundleID: "com.apple.dt.Xcode", fallback: "/Applications/Xcode.app", cpu: 0.24, memoryGB: 3.42),
        DemoApp(name: "Safari", bundleID: "com.apple.Safari", fallback: "/Applications/Safari.app", cpu: 0.09, memoryGB: 1.86),
        DemoApp(name: "Figma", bundleID: "com.figma.Desktop", fallback: "/Applications/Figma.app", cpu: 0.07, memoryGB: 1.24),
        DemoApp(name: "Terminal", bundleID: "com.apple.Terminal", fallback: "/System/Applications/Utilities/Terminal.app", cpu: 0.03, memoryGB: 0.18),
        DemoApp(name: "Music", bundleID: "com.apple.Music", fallback: "/System/Applications/Music.app", cpu: 0.02, memoryGB: 0.32),
        DemoApp(name: "Finder", bundleID: "com.apple.finder", fallback: "/System/Library/CoreServices/Finder.app", cpu: 0.01, memoryGB: 0.14),
    ]

    /// The busiest apps. Paths point at wherever the system finds each app, only so the list
    /// can show the app's icon; no process is read.
    static var processes: ProcessSnapshot {
        let usage: [ProcessUsage] = apps.enumerated().map { i, app in
            let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)?.path ?? app.fallback
            return make(["pid": 4_100 + i * 37, "name": app.name, "path": "\(bundle)/Contents/MacOS/\(app.name)",
                         "cpu": app.cpu, "memoryBytes": UInt64(app.memoryGB * gigabyte)])
        }
        return ProcessSnapshot(byCPU: usage, byMemory: usage.sorted { $0.memoryBytes > $1.memoryBytes }, hiddenCount: 0)
    }

    // MARK: Health

    static var system: SystemSnapshot {
        SystemSnapshot(swapUsedBytes: 1.3 * gigabyte, uptimeSeconds: demoUptime, diskFreeBytes: diskFree,
                       diskTotalBytes: diskTotal, activeBackgroundItems: 14)
    }

    /// A fully recorded day: one sample a minute, so the report covers 100 % of it.
    static func healthReport(now: Date = Date()) -> HealthReport {
        let minutes = 24 * 60
        let samples: [MetricSample] = (0..<minutes).map { i in
            let m = Double(i)
            // Busier during the working hours of the day, quiet overnight.
            let day = max(0, sin((m - 420) / 1440 * 2 * .pi))
            return MetricSample(time: now.addingTimeInterval(-Double(minutes - i) * 60),
                                cpu: 0.08 + 0.16 * day + 0.03 * sin(m / 17),
                                gpu: 0.05 + 0.1 * day,
                                memory: 0.47 + 0.09 * day + 0.01 * sin(m / 41),
                                temperature: 41 + 9 * day + 1.5 * sin(m / 23),
                                fan: 1_500 + 450 * day,
                                power: 7 + 8 * day + sin(m / 13))
        }
        let ranks: [(String, Double, Double, Int)] = [
            ("Xcode", 0.21, 3.1, 1_020), ("Safari", 0.08, 1.7, 1_300), ("Figma", 0.06, 1.2, 610),
            ("WindowServer", 0.05, 0.6, 1_440), ("Music", 0.02, 0.3, 900), ("Terminal", 0.02, 0.2, 1_100),
        ]
        let history = ProcessUsageHistory(
            byCPU: ranks.map { ProcessUsageRank(name: $0.0, averageCPU: $0.1, averageMemoryBytes: $0.2 * gigabyte, minuteCount: $0.3) },
            byMemory: ranks.map { ProcessUsageRank(name: $0.0, averageCPU: $0.1, averageMemoryBytes: $0.2 * gigabyte, minuteCount: $0.3) },
            totalMinuteCount: minutes, hiddenCount: 0)
        return HealthCheck.evaluate(samples: samples, processes: history, diskPoints: diskPoints(now: now),
                                    hours: 24, system: system, now: now)
    }

    /// Hourly free space for 30 days: a slow fill, one cleanup, then a steady line to today.
    static func diskPoints(now: Date = Date()) -> [DiskSpacePoint] {
        let hours = 30 * 24
        return (0...hours).map { i in
            let h = Double(i)
            let free: Double = if h < 470 {
                236 - 13 * h / 470 + 0.6 * sin(h / 9)
            } else {
                // Optimize freed about 26 GB, then the disk fills slowly again.
                250.4 - 1.8 * (h - 470) / Double(hours - 470) + 0.4 * sin(h / 11) - 0.4 * sin(Double(hours) / 11)
            }
            return DiskSpacePoint(time: now.addingTimeInterval(-Double(hours - i) * 3_600), free: free * gigabyte, total: diskTotal)
        }
    }

    static let security: [SecurityCheck] = [
        SecurityCheck(id: "gatekeeper", state: .on),
        SecurityCheck(id: "filevault", state: .on),
        SecurityCheck(id: "firewall", state: .on, detail: "stealth"),
        SecurityCheck(id: "sip", state: .on),
        SecurityCheck(id: "updates", state: .on),
        SecurityCheck(id: "xprotect", state: .info, detail: "5329 2026-11-18"),
    ]

    // MARK: Disk

    /// Scan figures for the demo home folder.
    static let scanFiles = 684_213
    static let scanElapsed: TimeInterval = 6.4

    static var volume: VolumeSummary {
        VolumeSummary(total: Int64(diskTotal), available: Int64(diskFree - 5.3 * gigabyte),
                      availableForImportant: Int64(diskFree), identifier: "6A1F3C2E-7B4D-4E8A-9C51-2D7E0F4B8A63",
                      mountPath: "/System/Volumes/Data", snapshots: .none)
    }

    /// About 142 GB of ordinary folders under `/Users/alex`.
    static func homeTree() -> CachedNode {
        let recent = Date().addingTimeInterval(-3 * 86_400)
        let old = Date().addingTimeInterval(-420 * 86_400)
        func file(_ name: String, _ gb: Double, modified: Date? = nil) -> CachedNode {
            CachedNode(name: name, isDirectory: false, modified: modified ?? recent, size: UInt64(gb * gigabyte),
                       fileCount: 1, smallFilesSize: 0, smallFilesCount: 0, readError: 0, skippedCloudOnly: false, children: [])
        }
        /// A folder of `gb` small files plus `children`.
        func dir(_ name: String, _ gb: Double = 0, _ children: [CachedNode] = [], modified: Date? = nil) -> CachedNode {
            let small = UInt64(gb * gigabyte)
            let size = small + children.reduce(0) { $0 + $1.size }
            let smallCount = Int(gb * 4_200)
            return CachedNode(name: name, isDirectory: true, modified: modified ?? recent, size: size,
                              fileCount: smallCount + children.reduce(0) { $0 + $1.fileCount },
                              smallFilesSize: small, smallFilesCount: smallCount, readError: 0,
                              skippedCloudOnly: false, children: children)
        }
        func project(_ name: String, modules: Double, build: Double, source: Double, assets: Double) -> CachedNode {
            dir(name, 0.04, [
                dir("node_modules", modules * 0.2, [dir("@babel", modules * 0.18), dir("typescript", modules * 0.14),
                                                     dir("esbuild", modules * 0.12), dir("react-dom", modules * 0.08),
                                                     dir("@swc", modules * 0.1), dir("eslint", modules * 0.06),
                                                     dir("lodash", modules * 0.04), dir("vite", modules * 0.08)]),
                dir("build", build * 0.3, [dir("Release", build * 0.45), dir("Debug", build * 0.25)]),
                dir("Sources", source * 0.4, [dir("App", source * 0.35), dir("Core", source * 0.25)]),
                dir("Assets", assets * 0.3, [dir("Images", assets * 0.45), dir("Fonts", assets * 0.25)]),
            ])
        }

        return dir("alex", 0.6, [
            dir("Library", 0.8, [
                dir("Application Support", 1.4, [
                    dir("Xcode", 0.2, [dir("Snapshots", 1.9), dir("Previews", 1.1)]),
                    dir("Figma", 0.3, [dir("DesktopProfile", 1.6), dir("FontCache", 0.5)]),
                    dir("Music", 0.2, [dir("Library.musicdb", 1.1)]),
                    dir("CloudDocs", 1.5),
                    dir("Safari", 0.9),
                    dir("Notes", 0.7),
                    dir("Photos", 0.6),
                    dir("Slack", 0.8),
                ]),
                dir("Developer", 0.3, [
                    dir("Xcode", 0.4, [dir("DerivedData", 1.2, [dir("Atlas-abcd", 1.9), dir("Lumen-efgh", 2.6), dir("Harbor-ijkl", 1.4)]),
                                       dir("iOS DeviceSupport", 2.9), dir("Archives", 0.8)]),
                    dir("CoreSimulator", 0.3, [dir("Devices", 2.6), dir("Caches", 1.1)]),
                ]),
                dir("Caches", 1.6, [
                    dir("Homebrew", 2.4), dir("com.apple.dt.Xcode", 1.9), dir("com.apple.Safari", 1.2),
                    dir("com.figma.Desktop", 0.9), dir("pip", 0.6), dir("Yarn", 1.1),
                ]),
                dir("Containers", 0.6, [dir("com.apple.mail", 2.1), dir("com.apple.Notes", 0.8), dir("com.apple.Photos", 0.7)]),
                dir("Mail", 1.6),
                dir("Group Containers", 1.9),
                dir("Logs", 0.4),
                dir("Fonts", 0.3),
            ]),
            dir("Projects", 0.3, [
                project("Atlas", modules: 2.4, build: 1.8, source: 0.9, assets: 1.1),
                project("Lumen", modules: 1.9, build: 1.3, source: 0.7, assets: 0.9),
                project("Harbor", modules: 1.5, build: 1.1, source: 0.6, assets: 0.7),
                project("Notebook", modules: 1.0, build: 0.6, source: 0.5, assets: 0.5),
                project("design-system", modules: 0.8, build: 0.4, source: 0.3, assets: 0.6),
                project("website", modules: 0.7, build: 0.4, source: 0.2, assets: 0.5),
            ]),
            dir("Movies", 0.2, [
                dir("Travel 2025", 0.3, [file("Iceland.mov", 4.2), file("Kyoto.mov", 3.1), file("Lisbon.mov", 1.8)]),
                dir("Final Cut Projects", 0.4, [dir("Product Launch.fcpbundle", 3.4), dir("Tutorial Series.fcpbundle", 2.3)]),
                dir("Screen Recordings", 0.6, [file("Demo walkthrough.mov", 1.5), file("Bug report.mov", 1.1)]),
            ]),
            dir("Pictures", 0.2, [
                dir("Photos Library.photoslibrary", 0.4, [dir("originals", 11.6), dir("resources", 2.8)]),
                dir("Screenshots", 1.3),
            ]),
            dir("Developer", 0.2, [
                dir("SDKs", 0.3, [dir("android-sdk", 3.1), dir("flutter", 1.7)]),
                dir("Toolchains", 3.4),
                dir("Swift Packages", 2.2),
                dir("Archives", 1.7),
            ]),
            dir("Downloads", 0.6, [
                file("Xcode_26.1.xip", 3.1, modified: old), file("macOS Installer.dmg", 1.9, modified: old),
                file("Figma-Installer.dmg", 0.6), file("dataset-2026.zip", 1.2), dir("Archive", 0.5),
            ]),
            dir("Applications", 0.1, [dir("Figma.app", 0.5), dir("Blender.app", 2.4), dir("DaVinci Resolve.app", 3.3)]),
            dir("Documents", 0.4, [
                dir("Reports", 1.6), dir("Presentations", 2.1), dir("Invoices", 0.4), dir("Notes", 0.3), dir("Scans", 1.3),
            ]),
            dir("Music", 0.1, [dir("Music", 0.2, [dir("Media", 3.3)])]),
            dir("Desktop", 1.1),
        ])
    }
}
#endif
