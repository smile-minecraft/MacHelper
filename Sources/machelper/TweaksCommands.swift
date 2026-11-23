import ArgumentParser
import Foundation
import Tweaks

struct Tweaks: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tweaks",
        abstract: "List, inspect and change MacHelper tweaks shared with the app.",
        discussion: """
        Settings live in ~/Library/Application Support/MacHelper/tweaks.json and are applied by the
        running MacHelper app. Without the app open, changes are saved but take effect on launch.
        """,
        subcommands: [List.self, Status.self, Enable.self, Disable.self, Set.self, Reset.self],
        defaultSubcommand: Status.self)

    // MARK: - Shared helpers

    private struct OptionJSON: Encodable {
        let id: String
        let kind: TweakOptionKind
        let defaultValue: TweakValue
        let minimum: Double?
        let maximum: Double?
        let allowedValues: [String]?
    }

    private struct DefinitionJSON: Encodable {
        let id: TweakID
        let title: String
        let detail: String
        let category: TweakCategory
        let permissions: [TweakPermission]
        let options: [OptionJSON]
        let implemented: Bool

        init(_ definition: TweakDefinition) {
            id = definition.id
            title = definition.title
            detail = definition.detail
            category = definition.id.category
            permissions = definition.permissions
            options = definition.options.map {
                OptionJSON(id: $0.id, kind: $0.kind, defaultValue: $0.defaultValue,
                           minimum: $0.minimum, maximum: $0.maximum, allowedValues: $0.allowedValues)
            }
            implemented = definition.implemented
        }
    }

    private struct StateJSON: Encodable {
        let id: TweakID
        let title: String
        let enabled: Bool
        let implemented: Bool
        let state: String
        let reason: String?
        let permissions: [TweakPermission]
    }

    private struct StatusJSON: Encodable {
        let schemaVersion = 1
        let appRunning: Bool
        let accessibilityGranted: Bool?
        let eventTapInstalled: Bool
        let message: String?
        let tweaks: [StateJSON]
    }

    private static func resolve(_ raw: String) throws -> TweakID {
        guard let id = TweakID(rawValue: raw) else {
            throw ValidationError("Unknown tweak: \(raw). Run `machelper tweaks list` for the ids.")
        }
        return id
    }

    private static func appIsRunning(_ store: TweakStore) -> Bool {
        TweakRuntimeStatus.load(from: store.statusURL)?.isAppRunning ?? false
    }

    private static func appliedMessage(_ store: TweakStore, _ what: String) -> String? {
        appIsRunning(store) ? nil : "Saved. Open MacHelper to apply \(what); changes are not active yet."
    }

    private static func effectiveValues(_ settings: TweakSettings) -> [String: [String: TweakValue]] {
        var result: [String: [String: TweakValue]] = [:]
        for definition in TweakCatalog.all {
            var values: [String: TweakValue] = ["enabled": .bool(settings.isEnabled(definition.id))]
            for option in definition.options {
                values[option.id] = settings.value(option.id, for: definition.id)
            }
            result[definition.id.rawValue] = values
        }
        return result
    }

    // MARK: - Commands

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List every tweak, its options and whether it is available.")
        @OptionGroup var output: OutputOptions

        func run() throws {
            if output.json {
                struct Out: Encodable {
                    let schemaVersion = 1
                    let tweaks: [DefinitionJSON]
                }
                try Output.json(Out(tweaks: TweakCatalog.all.map(DefinitionJSON.init)))
                return
            }
            for category in TweakCategory.allCases {
                let group = TweakCatalog.ids(in: category)
                Output.line("\(category.title):")
                for definition in group {
                    let flag = definition.implemented ? Output.pad("on", 3) : Output.pad("soon", 3)
                    let permissions = definition.permissions.isEmpty ? "" : "  [\(definition.permissions.map(\.rawValue).joined(separator: ", "))]"
                    Output.line("  \(flag) \(Output.pad(definition.id.rawValue, 34)) \(definition.title)\(permissions)")
                }
                Output.line()
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether the app is running and each tweak's current state.")
        @OptionGroup var output: OutputOptions

        func run() throws {
            let store = TweakStore()
            let settings = store.load()
            let runtime = TweakRuntimeStatus.load(from: store.statusURL)
            let running = runtime?.isAppRunning ?? false
            let granted = runtime?.accessibilityGranted
            let rows = TweakCatalog.all.map { definition -> StateJSON in
                let enabled = settings.isEnabled(definition.id)
                let reported = running ? runtime?.tweaks[definition.id.rawValue] : nil
                let state: String
                if !definition.implemented { state = "coming-soon" }
                else if !enabled { state = "off" }
                else if let reported {
                    state = reported.kind.rawValue
                } else {
                    state = running ? "pending" : "pending"
                }
                return StateJSON(id: definition.id, title: definition.title, enabled: enabled,
                                 implemented: definition.implemented, state: state,
                                 reason: reported?.reason, permissions: definition.permissions)
            }
            if output.json {
                try Output.json(StatusJSON(
                    appRunning: running,
                    accessibilityGranted: running ? granted : nil,
                    eventTapInstalled: running && (runtime?.eventTapInstalled ?? false),
                    message: running ? nil : "MacHelper is not running; saved changes take effect when you open it.",
                    tweaks: rows))
                return
            }
            if running {
                Output.line("MacHelper is running (PID \(runtime?.appPID ?? 0)). Accessibility: \(granted == true ? "granted" : "not granted").")
            } else {
                Output.line("MacHelper is not running; saved changes take effect when you open it.")
            }
            for row in rows where row.enabled || row.state == "needsPermission" {
                let reason = row.reason.map { " (\($0))" } ?? ""
                Output.line("  \(Output.pad(row.id.rawValue, 34)) \(row.state)\(reason)")
            }
            if !rows.contains(where: { $0.enabled }) { Output.line("  No tweaks are enabled.") }
        }
    }

    struct Enable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Enable an implemented tweak.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Tweak id, for example input.quit-guard.") var id: String

        func run() throws {
            let tweak = try resolve(id)
            guard TweakCatalog.isAvailable(tweak) else {
                throw ValidationError("\(tweak.rawValue) is not available in this build (coming soon).")
            }
            let store = TweakStore()
            var settings = store.load()
            let wrote = settings.setEnabled(tweak, true)
            guard wrote else { throw ValidationError("Could not enable \(tweak.rawValue).") }
            try store.save(settings)
            let message = Tweaks.appliedMessage(store, tweak.rawValue)
            if output.json {
                struct Out: Encodable { let schemaVersion = 1; let id: TweakID; let enabled = true; let appRunning: Bool; let message: String? }
                try Output.json(Out(id: tweak, appRunning: Tweaks.appIsRunning(store), message: message))
            } else {
                Output.line("Enabled \(tweak.rawValue).")
                if let message { Output.line(message) }
            }
        }
    }

    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Disable a tweak.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Tweak id.") var id: String

        func run() throws {
            let tweak = try resolve(id)
            let store = TweakStore()
            var settings = store.load()
            settings.setEnabled(tweak, false)
            try store.save(settings)
            let message = Tweaks.appliedMessage(store, tweak.rawValue)
            if output.json {
                struct Out: Encodable { let schemaVersion = 1; let id: TweakID; let enabled = false; let appRunning: Bool; let message: String? }
                try Output.json(Out(id: tweak, appRunning: Tweaks.appIsRunning(store), message: message))
            } else {
                Output.line("Disabled \(tweak.rawValue).")
                if let message { Output.line(message) }
            }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set one option of a tweak (booleans: true/false, lists: comma separated).")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Tweak id.") var id: String
        @Argument(help: "Option id from `machelper tweaks list`.") var option: String
        @Argument(help: "New value.") var value: String

        func run() throws {
            let tweak = try resolve(id)
            guard let definition = TweakCatalog.definition(for: tweak).option(option) else {
                throw ValidationError("Unknown option \(option) for \(tweak.rawValue). Options: \(TweakCatalog.definition(for: tweak).options.map(\.id).joined(separator: ", ")).")
            }
            guard let parsed = definition.parse(value) else {
                throw ValidationError("Invalid value \(value) for \(tweak.rawValue).\(option). Expected \(definition.kind.rawValue)"
                    + (definition.minimum.map { " between \(Int($0)) and \(Int(definition.maximum ?? $0))" } ?? "")
                    + ".")
            }
            let store = TweakStore()
            var settings = store.load()
            settings.setValue(option, for: tweak, to: parsed)
            try store.save(settings)
            let message = Tweaks.appliedMessage(store, "\(tweak.rawValue).\(option)")
            if output.json {
                struct Out: Encodable {
                    let schemaVersion = 1
                    let id: TweakID
                    let option: String
                    let value: TweakValue
                    let appRunning: Bool
                    let message: String?
                }
                try Output.json(Out(id: tweak, option: option, value: parsed,
                                    appRunning: Tweaks.appIsRunning(store), message: message))
            } else {
                Output.line("Set \(tweak.rawValue).\(option) = \(value).")
                if let message { Output.line(message) }
            }
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Clear all tweaks, or only one tweak's settings.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Optional tweak id; omit to clear everything.") var id: String?

        func run() throws {
            let tweak = try id.map(resolve)
            let store = TweakStore()
            var settings = store.load()
            settings.reset(tweak)
            try store.save(settings)
            let message = Tweaks.appliedMessage(store, tweak?.rawValue ?? "all tweaks")
            if output.json {
                struct Out: Encodable {
                    let schemaVersion = 1
                    let reset: String?
                    let appRunning: Bool
                    let settings: [String: [String: TweakValue]]
                    let message: String?
                }
                try Output.json(Out(reset: tweak?.rawValue, appRunning: Tweaks.appIsRunning(store),
                                    settings: effectiveValues(settings), message: message))
            } else {
                Output.line(tweak.map { "Reset \($0.rawValue)." } ?? "Reset all tweaks.")
                if let message { Output.line(message) }
            }
        }
    }
}
