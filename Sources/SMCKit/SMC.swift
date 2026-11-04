import CSystemBridge
import Foundation
import IOKit

public enum SMCError: Error, Sendable, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case smcResult(key: FourCC, code: UInt8)
    case keyNotFound(FourCC)
    case sizeMismatch(key: FourCC, expected: Int, got: Int)
    case unsupportedType(key: FourCC, type: FourCC)
    case notPrivileged

    public var description: String {
        switch self {
        case .serviceNotFound: "AppleSMC service not found"
        case .openFailed(let kr): "IOServiceOpen failed (0x\(String(kr, radix: 16)))"
        case .callFailed(let kr): "SMC call failed (0x\(String(UInt32(bitPattern: kr), radix: 16)))"
        case .smcResult(let key, let code): "SMC returned 0x\(String(code, radix: 16)) for \(key)"
        case .keyNotFound(let key): "SMC key \(key) does not exist"
        case .sizeMismatch(let key, let e, let g): "SMC key \(key) expects \(e) bytes, got \(g)"
        case .unsupportedType(let key, let type): "Cannot encode type \(type) for \(key)"
        case .notPrivileged: "Writing SMC keys requires root"
        }
    }
}

/// Connection to the AppleSMC kernel user client.
///
/// Reads work as any user. Writes require root (they are performed by the Helper daemon).
/// Calls are serialised with a lock, so one instance can be shared across tasks.
public final class SMC: @unchecked Sendable {
    private static let resultKeyNotFound: UInt8 = 0x84

    private let connection: io_connect_t
    private let lock = NSLock()
    private var keyInfoCache: [FourCC: MHSMCKeyInfo] = [:]

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mh_task_self(), 0, &conn)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr) }
        connection = conn
    }

    deinit { IOServiceClose(connection) }

    // MARK: Public API

    public func keyExists(_ key: FourCC) -> Bool {
        (try? keyInfo(key)) != nil
    }

    public func read(_ key: FourCC) throws -> SMCValue {
        try lock.withLock {
            let info = try unlockedKeyInfo(key)
            var input = MHSMCKeyData()
            input.key = key.rawValue
            input.keyInfo.dataSize = info.dataSize
            input.data8 = UInt8(MH_SMC_CMD_READ_BYTES)
            var output = try call(&input, key: key)
            let size = Int(min(info.dataSize, 32))
            let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(size)) }
            return SMCValue(key: key, type: FourCC(rawValue: info.dataType), bytes: bytes)
        }
    }

    public func readDouble(_ key: FourCC) throws -> Double {
        let value = try read(key)
        guard let d = value.doubleValue else { throw SMCError.unsupportedType(key: key, type: value.type) }
        return d
    }

    public func write(_ key: FourCC, bytes: [UInt8]) throws {
        try lock.withLock {
            let info = try unlockedKeyInfo(key)
            guard bytes.count == Int(info.dataSize) else {
                throw SMCError.sizeMismatch(key: key, expected: Int(info.dataSize), got: bytes.count)
            }
            var input = MHSMCKeyData()
            input.key = key.rawValue
            input.keyInfo.dataSize = info.dataSize
            input.data8 = UInt8(MH_SMC_CMD_WRITE_BYTES)
            withUnsafeMutableBytes(of: &input.bytes) { buf in
                for (i, b) in bytes.enumerated() { buf[i] = b }
            }
            _ = try call(&input, key: key)
        }
    }

    /// Writes a numeric value, encoding it with the key's declared type.
    public func write(_ key: FourCC, value: Double) throws {
        let (type, size) = try keyInfo(key)
        guard let bytes = SMCCodec.encode(value, type: type, size: size) else {
            throw SMCError.unsupportedType(key: key, type: type)
        }
        try write(key, bytes: bytes)
    }

    public func keyInfo(_ key: FourCC) throws -> (type: FourCC, size: Int) {
        let info = try lock.withLock { try unlockedKeyInfo(key) }
        return (FourCC(rawValue: info.dataType), Int(info.dataSize))
    }

    /// Number of keys exposed by the SMC (`#KEY`).
    public func keyCount() throws -> Int {
        Int(try readDouble("#KEY"))
    }

    public func key(at index: Int) throws -> FourCC {
        try lock.withLock {
            var input = MHSMCKeyData()
            input.data8 = UInt8(MH_SMC_CMD_READ_INDEX)
            input.data32 = UInt32(index)
            let output = try call(&input, key: "#idx")
            return FourCC(rawValue: output.key)
        }
    }

    public func allKeys() throws -> [FourCC] {
        try (0..<keyCount()).map { try key(at: $0) }
    }

    // MARK: Private

    private func unlockedKeyInfo(_ key: FourCC) throws -> MHSMCKeyInfo {
        if let cached = keyInfoCache[key] { return cached }
        var input = MHSMCKeyData()
        input.key = key.rawValue
        input.data8 = UInt8(MH_SMC_CMD_READ_KEYINFO)
        let output = try call(&input, key: key)
        keyInfoCache[key] = output.keyInfo
        return output.keyInfo
    }

    private func call(_ input: inout MHSMCKeyData, key: FourCC) throws -> MHSMCKeyData {
        var output = MHSMCKeyData()
        var outputSize = MemoryLayout<MHSMCKeyData>.stride
        let kr = IOConnectCallStructMethod(
            connection, UInt32(MH_SMC_KERNEL_INDEX),
            &input, MemoryLayout<MHSMCKeyData>.stride,
            &output, &outputSize
        )
        if kr == kIOReturnNotPrivileged { throw SMCError.notPrivileged }
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kr) }
        if output.result == Self.resultKeyNotFound { throw SMCError.keyNotFound(key) }
        guard output.result == 0 else { throw SMCError.smcResult(key: key, code: output.result) }
        return output
    }
}
