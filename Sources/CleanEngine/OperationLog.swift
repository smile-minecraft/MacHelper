import Foundation

/// Append-only JSON Lines log of every real (non-dry-run) removal and maintenance task,
/// at ~/Library/Logs/MacHelper/operations.jsonl. Shared by the app and the CLI.
public struct OperationLog: Sendable {
    public struct Entry: Codable, Sendable {
        public let time: Date
        public let command: String
        public let path: String
        public let source: String
        public let bytes: UInt64
        public let result: String
        public let message: String?

        public init(time: Date, command: String, path: String, source: String, bytes: UInt64, result: String, message: String?) {
            self.time = time
            self.command = command
            self.path = path
            self.source = source
            self.bytes = bytes
            self.result = result
            self.message = message
        }
    }

    public static let shared = OperationLog(url: MacHelperPaths.operationLog)
    public let url: URL

    public init(url: URL) { self.url = url }

    public func append(command: String, outcomes: [ItemOutcome]) {
        let now = Date()
        append(outcomes.map {
            Entry(time: now, command: command, path: $0.path, source: $0.source, bytes: $0.bytes,
                  result: $0.result.rawValue, message: $0.message)
        })
    }

    public func append(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var blob = Data()
        for e in entries {
            guard let line = try? encoder.encode(e) else { continue }
            blob.append(line)
            blob.append(0x0A)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: blob)
        } else {
            try? blob.write(to: url)
        }
    }

    /// Most recent entries first.
    public func read(limit: Int = 200) -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).reversed().prefix(limit).compactMap {
            try? decoder.decode(Entry.self, from: Data($0.utf8))
        }
    }
}
