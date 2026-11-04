import Foundation
import Metrics
import SMCKit

// Read-only hardware probe. Validates the SMC / IOHID / IOReport stack on the current machine.
// Usage: mhprobe            summary
//        mhprobe keys [P]   dump all SMC keys (optionally only those starting with P)

let args = CommandLine.arguments.dropFirst()

func pct(_ v: Double?) -> String { v.map { String(format: "%5.1f%%", $0 * 100) } ?? "  n/a" }
func gb(_ b: UInt64) -> String { String(format: "%.2f GB", Double(b) / 1_073_741_824) }

let smc: SMC
do { smc = try SMC() } catch {
    print("SMC open failed: \(error)")
    exit(1)
}

if args.first == "keys" {
    let prefix = args.dropFirst().first ?? ""
    let keys = (try? smc.allKeys()) ?? []
    print("\(keys.count) keys")
    for key in keys where key.description.hasPrefix(prefix) {
        if let v = try? smc.read(key) { print(v) } else { print("\(key) <unreadable>") }
    }
    exit(0)
}

if args.first == "procs" {
    let sampler = ProcessSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1)
    let s = sampler.sample(top: 6)
    print("hidden (need root): \(s.hiddenCount)")
    for p in s.byCPU { print(String(format: "  cpu %6.1f%%  %@ (%d)", p.cpu * 100, p.name, p.pid)) }
    for p in s.byMemory { print(String(format: "  mem %@  %@", gb(p.memoryBytes), p.name)) }
    exit(0)
}

print("Chip:      \(ChipFamily.current)  model=\(sysctlString("hw.model") ?? "?")")
print("SMC keys:  \((try? smc.keyCount()) ?? -1)")

let driver = FanDriver(smc: smc)
print("Fan strategy: \(driver.strategy)  Ftst=\((try? smc.readDouble("Ftst")).map { "\($0)" } ?? "absent")")
for f in driver.readFans() {
    print(String(format: "  Fan %d: actual %.0f rpm, target %.0f, range %.0f–%.0f, mode %@",
                 f.id, f.actualRPM, f.targetRPM, f.minRPM, f.maxRPM, "\(f.mode)"))
}

let cpu = CPUSampler()
let power = PowerSampler(smc: smc)
_ = cpu.sample()
_ = power?.sample()
Thread.sleep(forTimeInterval: 1)

if let c = cpu.sample() {
    let p = cpu.coreKinds.filter { $0 == .performance }.count
    let e = cpu.coreKinds.filter { $0 == .efficiency }.count
    print("CPU:       total \(pct(c.total))  P(\(p)) \(pct(c.performance))  E(\(e)) \(pct(c.efficiency))")
}
for g in GPUSampler.sample() { print("GPU:       \(g.name) \(pct(g.utilization))") }
if let m = MemorySampler.sample() {
    print("Memory:    used \(gb(m.usedBytes)) / \(gb(m.totalBytes))  swap \(gb(m.swapUsedBytes))  pressure \(m.pressure)")
}
if let p = power?.sample() {
    func w(_ v: Double?) -> String { v.map { String(format: "%.2f W", $0) } ?? "n/a" }
    print("Power:     CPU \(w(p.cpuWatts))  GPU \(w(p.gpuWatts))  ANE \(w(p.aneWatts))  DRAM \(w(p.dramWatts))  system \(w(p.systemWatts))")
} else {
    print("Power:     IOReport unavailable")
}

if let hid = HIDTemperatureSensors() {
    let temps = hid.read()
    print("HID temperatures (\(temps.count)):")
    for t in temps { print(String(format: "  %-28@ %6.1f °C  [%@]", t.name, t.celsius, t.category.rawValue)) }
}
let smcTempKeys = SMCTemperatures.discoverKeys(smc)
let smcTemps = SMCTemperatures.read(smc, keys: smcTempKeys)
print("SMC temperature keys (\(smcTemps.count)): " + smcTemps.prefix(40).map { String(format: "%@=%.0f", $0.name, $0.celsius) }.joined(separator: " "))

let net = NetworkSampler(), disk = DiskSampler()
_ = net.sample(); _ = disk.sample()
Thread.sleep(forTimeInterval: 1)
if let n = net.sample() { print(String(format: "Network:   in %.1f KB/s  out %.1f KB/s", n.inBytesPerSecond / 1024, n.outBytesPerSecond / 1024)) }
if let d = disk.sample() {
    print(String(format: "Disk:      read %.1f KB/s  write %.1f KB/s  free %@ / %@", d.readBytesPerSecond / 1024, d.writeBytesPerSecond / 1024,
                 gb(UInt64(d.availableBytes)), gb(UInt64(d.totalBytes))))
}
print("Battery:   \(BatterySampler.sample().map { "\($0)" } ?? "none")")
