import ArgumentParser
import CleanEngine
import Foundation

struct Startup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "startup",
        abstract: "List launch agents and daemons that start on their own; disable, enable or remove your own.",
        discussion: """
        Lists ~/Library/LaunchAgents, /Library/LaunchAgents and /Library/LaunchDaemons (Apple's jobs are hidden).
        --disable / --enable work like the switch in System Settings → Login Items and survive restarts.
        --remove stops the job and moves its plist to the Trash (needs --yes). Items for all users and system
        daemons need an administrator and are listed only.
        """
    )

    @OptionGroup var output: OutputOptions

    @Option(name: .long, help: "Label (or plist path) to disable.")
    var disable: String?

    @Option(name: .long, help: "Label (or plist path) to enable.")
    var enable: String?

    @Option(name: .long, help: "Label (or plist path) to remove (with --yes).")
    var remove: String?

    @Flag(name: .long, help: "Confirm --remove.")
    var yes = false

    @Flag(name: .long, help: "Only items whose program no longer exists.")
    var broken = false

    func run() throws {
        let items = StartupItems.list()
        if let label = disable {
            try StartupItems.setEnabled(try StartupItems.find(label, in: items), false)
            return Output.line("Disabled \(label).")
        }
        if let label = enable {
            try StartupItems.setEnabled(try StartupItems.find(label, in: items), true)
            return Output.line("Enabled \(label).")
        }
        if let label = remove {
            let item = try StartupItems.find(label, in: items)
            guard yes else { return Output.line("Would stop \(item.label) and move \(Output.shortPath(item.plistPath)) to the Trash. Add --yes.") }
            let report = try StartupItems.remove(item)
            for f in report.failures { Output.err("failed: \(f.message ?? "")") }
            if report.failures.isEmpty { Output.line("Removed \(item.label).") }
            throw reportExit(report)
        }
        let shown = broken ? items.filter(\.programMissing) : items
        if output.json {
            struct Out: Encodable { let schemaVersion = 1; let items: [StartupItem] }
            return try Output.json(Out(items: shown))
        }
        for scope in StartupItem.Scope.allCases {
            let group = shown.filter { $0.scope == scope }
            guard !group.isEmpty else { continue }
            Output.line("\(scope.rawValue) (\(group.count))\(scope.needsAdmin ? "  [needs admin to change]" : "")")
            for i in group {
                let state = i.isDisabled ? "disabled" : (i.pid != nil ? "running" : (i.isLoaded ? "loaded" : "off"))
                let flags = [i.programMissing ? "PROGRAM MISSING" : nil, i.ownerName].compactMap { $0 }.joined(separator: ", ")
                Output.line("  \(Output.pad(state, 9)) \(Output.pad(i.label, 50)) \(flags)")
            }
        }
    }
}
