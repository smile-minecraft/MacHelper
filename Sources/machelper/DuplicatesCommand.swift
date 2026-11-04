import ArgumentParser
import CleanEngine
import DiskScan
import Foundation

struct Duplicates: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find files with identical content (read-only).",
        discussion: """
        Compares size, then the first/last 64 KB, then a full SHA-256. Hard links are one file; APFS clones \
        share storage and are marked, since deleting one of them frees almost nothing.
        """
    )

    @OptionGroup var output: OutputOptions

    @Argument(help: "Folder to search (default: your home folder).")
    var path: String = "~"

    @Option(name: .long, help: "Ignore files smaller than this many MB.")
    var minSize: Double = 1

    @Option(name: .long, help: "Groups to show.")
    var top = 30

    func run() throws {
        let minBytes = UInt64(minSize * 1_048_576)
        var options = ScanOptions()
        options.keepFilesLargerThan = max(minBytes, 1)
        let result = try DiskScanner(options: options).scan(URL(fileURLWithPath: expandTilde(path)))
        var files: [String] = []
        result.root.forEach { if !$0.isDirectory && $0.size >= minBytes / 2 { files.append($0.path) } }
        let groups = DuplicateFinder.find(paths: files, minSize: minBytes)
        let total = groups.reduce(0) { $0 + $1.reclaimable }
        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let reclaimable: UInt64; let groups: [DuplicateGroup] }
            return try Output.json(Out(reclaimable: total, groups: Array(groups.prefix(top))))
        }
        Output.line("\(groups.count) groups of duplicates among \(files.count) files ≥ \(minSize) MB; \(Output.bytes(total)) reclaimable.")
        for g in groups.prefix(top) {
            Output.line("\n\(Output.bytes(g.size)) × \(g.files.count)  (frees \(Output.bytes(g.reclaimable)))")
            for f in g.files {
                Output.line("  \(f.sharesStorage ? "[clone] " : "")\(Output.shortPath(f.path))")
            }
        }
    }
}
