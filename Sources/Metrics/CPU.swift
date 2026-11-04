import CSystemBridge
import Darwin
import Foundation
import IOKit
import SMCKit

public struct CPUReading: Sendable, Hashable, Codable {
    /// 0...1 averaged over all cores.
    public var total: Double
    public var performance: Double?
    public var efficiency: Double?
    public var perCore: [Double]
    /// Kind of each entry in `perCore` (performance / efficiency), same order.
    public var coreKinds: [CoreKind] = []
    /// Shares of all CPU time in this interval (0...1).
    public var system: Double = 0
    public var user: Double = 0
}

public enum CoreKind: String, Sendable, Codable { case performance, efficiency, unknown }

/// CPU utilisation from `host_processor_info` deltas, split by cluster on Apple Silicon.
public final class CPUSampler: @unchecked Sendable {
    public let coreKinds: [CoreKind]
    private var previousTicks: [[UInt32]]?
    private let lock = NSLock()

    public init() {
        coreKinds = Self.detectCoreKinds()
    }

    public func sample() -> CPUReading? {
        lock.withLock {
            guard let ticks = Self.readTicks() else { return nil }
            defer { previousTicks = ticks }
            guard let prev = previousTicks, prev.count == ticks.count else { return nil }

            var perCore: [Double] = []
            var sumUser = 0.0, sumSys = 0.0, sumAll = 0.0
            for (now, before) in zip(ticks, prev) {
                let d = zip(now, before).map { Double($0 &- $1) }
                let user = d[Int(CPU_STATE_USER)], sys = d[Int(CPU_STATE_SYSTEM)]
                let nice = d[Int(CPU_STATE_NICE)], idle = d[Int(CPU_STATE_IDLE)]
                let busy = user + sys + nice
                let all = busy + idle
                perCore.append(all > 0 ? busy / all : 0)
                sumUser += user + nice; sumSys += sys; sumAll += all
            }
            func avg(_ kind: CoreKind) -> Double? {
                let vals = perCore.indices.filter { $0 < coreKinds.count && coreKinds[$0] == kind }.map { perCore[$0] }
                return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
            }
            return CPUReading(
                total: perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count),
                performance: avg(.performance),
                efficiency: avg(.efficiency),
                perCore: perCore,
                coreKinds: Array(coreKinds.prefix(perCore.count)),
                system: sumAll > 0 ? sumSys / sumAll : 0,
                user: sumAll > 0 ? sumUser / sumAll : 0
            )
        }
    }

    private static func readTicks() -> [[UInt32]]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return nil }
        defer {
            vm_deallocate(mh_task_self(), vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { cpu in
            (0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) }
        }
    }

    /// Maps logical CPU index → cluster kind using the device tree `cluster-type` property.
    static func detectCoreKinds() -> [CoreKind] {
        let total = sysctlInt("hw.logicalcpu") ?? 0
        guard ChipFamily.current.isAppleSilicon else { return Array(repeating: .unknown, count: total) }

        var kinds: [Int: CoreKind] = [:]
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != 0 {
            defer { IOObjectRelease(cpus) }
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                var ordinal = 0
                while case let entry = IOIteratorNext(iterator), entry != 0 {
                    defer { IOObjectRelease(entry); ordinal += 1 }
                    let id = registryData(entry, "logical-cpu-id").map { Int(littleEndianUInt32($0)) } ?? ordinal
                    let type = registryData(entry, "cluster-type").flatMap { String(bytes: $0.prefix { $0 != 0 }, encoding: .ascii) }
                    kinds[id] = switch type {
                    case "P": .performance
                    case "E": .efficiency
                    default: .unknown
                    }
                }
            }
        }
        if kinds.isEmpty {
            // Fallback: perflevel1 (efficiency) cores enumerate first on Apple Silicon.
            let e = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
            return (0..<total).map { $0 < e ? .efficiency : .performance }
        }
        return (0..<total).map { kinds[$0] ?? .unknown }
    }
}

func registryData(_ entry: io_registry_entry_t, _ key: String) -> [UInt8]? {
    guard let prop = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
          let data = prop as? Data
    else { return nil }
    return Array(data)
}

func littleEndianUInt32(_ b: [UInt8]) -> UInt32 {
    b.prefix(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
}
