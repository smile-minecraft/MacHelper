import ArgumentParser
import CleanEngine
import Foundation

@main
struct MacHelperCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machelper",
        abstract: "MacHelper command-line tool: clean, purge build artifacts, optimize, analyze disk, show status.",
        discussion: """
        Commands that remove things only preview by default. Add --yes to actually do it.
        Every command accepts --json for machine-readable output (stable "schemaVersion" field).
        Exit codes: 0 success, 1 failure, 2 partial failure (some items could not be processed).
        Cleaning rules: low-risk items are deleted directly, medium and high risk go to the Trash
        (`clean --trash` sends everything to the Trash). Other removals go to the Trash unless --permanent.
        All real operations are logged to ~/Library/Logs/MacHelper/operations.jsonl (see `machelper history`).
        """,
        // From the Info.plist section the app build embeds in the binary; a plain `swift build` has none.
        version: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map {
            "\($0) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))"
        } ?? "dev",
        subcommands: [Clean.self, Purge.self, Optimize.self, Uninstall.self, AutoCleanCommand.self, Startup.self, Analyze.self, Insights.self, Duplicates.self, Guide.self, SkillCommand.self, Status.self, DockerCommand.self, LoginItemsCommand.self, DoctorCommand.self, Stats.self, Rules.self, Ignore.self, Updates.self, Security.self, History.self, MonitorCommand.self]
    )

    static func main() {
        reexecFromRealPathIfLinked()
        do {
            var command = try parseAsRoot()
            try command.run()
        } catch {
            // Agents read stdout as JSON: with --json, a failure is a JSON document too.
            if CommandLine.arguments.contains("--json"), !(error is ExitCode), !(error is CleanExit) {
                struct Failure: Encodable { let message: String; let exitCode: Int32 }
                struct Out: Encodable { let schemaVersion = 1; let error: Failure }
                let code = exitCode(for: error).rawValue
                try? Output.json(Out(error: Failure(message: fullMessage(for: error).trimmingCharacters(in: .whitespacesAndNewlines), exitCode: code)))
                Foundation.exit(code)
            }
            exit(withError: error)
        }
    }

    /// Run through a symlink (~/.local/bin/machelper), the process wouldn't see the app it lives in:
    /// re-exec from the real path so resources and the app's language are found the same way.
    private static func reexecFromRealPathIfLinked() {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0, let real = realpath(buf, nil) else { return }
        defer { free(real) }
        let exe = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let realPath = String(cString: real)
        guard realPath != exe, realPath.contains(".app/Contents/MacOS/") else { return }
        var args = CommandLine.arguments
        args[0] = realPath
        var cargs = args.map { strdup($0) } + [nil]
        execv(realPath, &cargs)
    }
}

// MARK: - Shared options and output

struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Machine-readable JSON on stdout.")
    var json = false
}

struct ApplyOptions: ParsableArguments {
    @Flag(name: .long, help: "Actually perform the operation. Without it, only a preview is shown.")
    var yes = false

    @Flag(name: .long, help: "Preview only (the default; kept for explicitness in scripts).")
    var dryRun = false

    var shouldApply: Bool { yes && !dryRun }
}

enum Output {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func json<T: Encodable>(_ value: T) throws {
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func line(_ s: String = "") { print(s) }

    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// "500MB", "2 GB", "1.5g", "123" (bytes); decimal units like Finder. Nil when it doesn't parse.
    static func parseBytes(_ s: String) -> UInt64? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
        let units: [(String, Double)] = [("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("t", 1e12), ("g", 1e9), ("m", 1e6), ("k", 1e3), ("b", 1)]
        for (u, m) in units where t.hasSuffix(u) {
            guard let v = Double(t.dropLast(u.count)), v >= 0 else { return nil }
            return UInt64(v * m)
        }
        return Double(t).flatMap { $0 >= 0 ? UInt64($0) : nil }
    }

    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file)
    }

    /// RAM uses binary units (32 GB, like Activity Monitor).
    static func memory(_ b: UInt64) -> String {
        b == 0 ? "0" : ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .memory)
    }

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    static func lpad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }

    static func shortPath(_ p: String) -> String {
        let home = MacHelperPaths.home.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

/// Exit with 2 when some items failed.
func reportExit(_ report: CleanReport) -> ExitCode {
    report.failures.isEmpty ? .success : ExitCode(2)
}

/// CLI-side risk argument. A separate type (instead of extending RiskLevel) avoids a retroactive
/// conformance that SwiftPM and Xcode builds disagree about.
enum RiskArgument: String, ExpressibleByArgument, CaseIterable {
    case low, medium, high
    var level: RiskLevel { RiskLevel(rawValue: rawValue)! }
}
