import Foundation

/// Read-only view of `docker system df`: how much space images, containers, volumes and build cache use,
/// and how much Docker itself reports as reclaimable. Never removes anything.
public struct DockerUsage: Codable, Sendable, Equatable {
    public struct Row: Codable, Sendable, Equatable, Identifiable {
        public enum Kind: String, Codable, Sendable { case images, containers, volumes, buildCache, other }
        public let kind: Kind
        /// Docker's own label ("Images", "Build Cache", …).
        public let type: String
        public let totalCount: Int
        public let active: Int
        public let size: UInt64
        public let reclaimable: UInt64
        public var id: String { type }
    }

    public let rows: [Row]
    public var totalSize: UInt64 { rows.reduce(0) { $0 + $1.size } }
    public var totalReclaimable: UInt64 { rows.reduce(0) { $0 + $1.reclaimable } }

    public init(rows: [Row]) { self.rows = rows }

    public enum Failure: Error, Equatable, Sendable {
        case notInstalled
        /// The CLI exists but the engine (Docker Desktop, OrbStack, Colima…) is not running.
        case engineNotRunning(String)
        case unreadable(String)
    }

    /// Runs `docker system df --format json` (one JSON object per line). Takes a few seconds; call off the main thread.
    public static func read(docker: String? = MaintenanceCatalog.docker, timeout: TimeInterval = 20) -> Result<DockerUsage, Failure> {
        guard let docker else { return .failure(.notInstalled) }
        let (status, text) = MaintenanceRunner.exec([docker, "system", "df", "--format", "{{json .}}"], timeout: timeout)
        guard status == 0 else {
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.localizedCaseInsensitiveContains("cannot connect") || message.localizedCaseInsensitiveContains("is the docker daemon running") {
                return .failure(.engineNotRunning(message))
            }
            return .failure(.unreadable(message.isEmpty ? "exit \(status)" : String(message.suffix(300))))
        }
        guard let usage = parse(text) else { return .failure(.unreadable(String(text.prefix(300)))) }
        return .success(usage)
    }

    /// Parses the line-delimited JSON. Returns nil when no line is usable.
    public static func parse(_ text: String) -> DockerUsage? {
        struct Line: Decodable {
            let `Type`: String
            let TotalCount: String?
            let Active: String?
            let Size: String?
            let Reclaimable: String?
        }
        let rows: [Row] = text.split(whereSeparator: \.isNewline).compactMap { raw in
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)) else { return nil }
            let kind: Row.Kind = switch line.Type.lowercased() {
            case "images": .images
            case "containers": .containers
            case "local volumes", "volumes": .volumes
            case "build cache": .buildCache
            default: .other
            }
            return Row(kind: kind, type: line.Type,
                       totalCount: Int(line.TotalCount ?? "") ?? 0, active: Int(line.Active ?? "") ?? 0,
                       size: bytes(line.Size ?? "") ?? 0, reclaimable: bytes(line.Reclaimable ?? "") ?? 0)
        }
        return rows.isEmpty ? nil : DockerUsage(rows: rows)
    }

    /// Docker prints sizes with go-units `HumanSize`: decimal units, e.g. "11.75GB", "521.7kB (0%)", "0B".
    static func bytes(_ text: String) -> UInt64? {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        guard let split = token.firstIndex(where: { $0.isLetter }) else { return nil }
        guard let value = Double(token[..<split]), value >= 0 else { return nil }
        let unit = token[split...].uppercased()
        let scale: Double = switch unit {
        case "B": 1
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        case "PB": 1e15
        default: -1
        }
        guard scale > 0 else { return nil }
        return UInt64((value * scale).rounded())
    }
}
