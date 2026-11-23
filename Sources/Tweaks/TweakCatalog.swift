import Foundation

/// A setting value as it appears in tweaks.json. Encoded as the bare JSON value so the file stays
/// readable and the CLI can print the same representation it accepts.
public enum TweakValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case stringList([String])

    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var intValue: Int? { if case .int(let v) = self { return v }; return nil }
    public var doubleValue: Double? { if case .double(let v) = self { return v }; return nil }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var stringListValue: [String]? { if case .stringList(let v) = self { return v }; return nil }
}

extension TweakValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { throw DecodingError.typeMismatch(TweakValue.self, .init(codingPath: c.codingPath, debugDescription: "null")) }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode([String].self) { self = .stringList(v); return }
        self = .string(try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .stringList(let v): try c.encode(v)
        }
    }
}

public enum TweakOptionKind: String, Codable, Sendable {
    case bool, int, double, string
    case enumeration = "enum"
    case appList = "app-list"
}

public struct TweakOptionDefinition: Equatable, Sendable {
    public let id: String
    public let kind: TweakOptionKind
    public let defaultValue: TweakValue
    public let minimum: Double?
    public let maximum: Double?
    public let allowedValues: [String]?

    public init(id: String, kind: TweakOptionKind, defaultValue: TweakValue,
                minimum: Double? = nil, maximum: Double? = nil, allowedValues: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
        self.allowedValues = allowedValues
    }

    /// JSON has one number type: a Double that happens to be whole (1.0) is written as `1` and
    /// read back as an int. A whole number is a valid double, so it is converted back here before
    /// validation instead of being dropped.
    public func normalized(_ value: TweakValue) -> TweakValue {
        if kind == .double, case .int(let n) = value { return .double(Double(n)) }
        return value
    }

    /// The single validation rule for both the UI and the CLI. A value of the wrong Swift type or
    /// outside the declared range is rejected instead of silently changing the tweak's behaviour.
    public func isValid(_ value: TweakValue) -> Bool {
        switch kind {
        case .bool: return value.boolValue != nil
        case .int:
            guard let n = value.intValue else { return false }
            return (minimum.map { n >= Int($0.rounded(.up)) } ?? true)
                && (maximum.map { n <= Int($0.rounded(.down)) } ?? true)
        case .double:
            guard let n = value.doubleValue else { return false }
            return (minimum.map { n >= $0 } ?? true) && (maximum.map { n <= $0 } ?? true)
        case .string: return value.stringValue != nil
        case .enumeration:
            guard let s = value.stringValue else { return false }
            return allowedValues?.contains(s) ?? true
        case .appList: return value.stringListValue != nil
        }
    }

    /// Parses the CLI's string argument, then applies the same validation as the UI.
    public func parse(_ text: String) -> TweakValue? {
        let value: TweakValue?
        switch kind {
        case .bool:
            switch text.lowercased() {
            case "true", "yes", "1": value = .bool(true)
            case "false", "no", "0": value = .bool(false)
            default: return nil
            }
        case .int: value = Int(text).map(TweakValue.int)
        case .double: value = Double(text).map(TweakValue.double)
        case .string, .enumeration: value = .string(text)
        case .appList:
            let ids = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            value = .stringList(ids)
        }
        guard let value, isValid(value) else { return nil }
        return value
    }
}

public struct TweakDefinition: Equatable, Sendable, Identifiable {
    public let id: TweakID
    /// English String Catalog keys; the App localizes them, the CLI prints them verbatim.
    public let title: String
    public let detail: String
    public let permissions: [TweakPermission]
    public let options: [TweakOptionDefinition]
    public let implemented: Bool
    /// Why this build cannot offer the tweak, when the answer is not simply "not written yet".
    public let unavailableReason: String?

    public init(id: TweakID, title: String, detail: String, permissions: [TweakPermission] = [],
                options: [TweakOptionDefinition] = [], implemented: Bool = false,
                unavailableReason: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.permissions = permissions
        self.options = options
        self.implemented = implemented
        self.unavailableReason = unavailableReason
    }

    public func option(_ id: String) -> TweakOptionDefinition? { options.first { $0.id == id } }
}

/// The single place that decides which tweaks exist, what their options mean and which ones are
/// available in this build. Later work adds a behaviour class and flips `implemented` here.
public enum TweakCatalog {
    public static let all: [TweakDefinition] = [
        TweakDefinition(id: .finderCutPaste, title: "Cut and paste files in Finder",
                        detail: "Move files with ⌘X / ⌘V instead of copying them.",
                        permissions: [.accessibility],
                        options: [],
                        implemented: true),
        TweakDefinition(id: .finderNewFile, title: "New file in Finder",
                        detail: "Create a file in the folder the Finder window shows and start renaming it.",
                        permissions: [.accessibility, .automationFinder],
                        options: [.init(id: "shortcut", kind: .string, defaultValue: .string("ctrl+option+n")),
                                  .init(id: "template", kind: .enumeration, defaultValue: .string("text"),
                                        allowedValues: FinderFileTemplate.allCases.map(\.rawValue)),
                                  .init(id: "baseName", kind: .string, defaultValue: .string(FinderNewFileRules.defaultBaseName)),
                                  .init(id: "customExtension", kind: .string, defaultValue: .string("txt"))],
                        implemented: true),
        TweakDefinition(id: .finderContextMenu, title: "Finder context menu items",
                        detail: "Add New File, Copy Path, Open in Terminal and Cut to Finder's right-click menu.",
                        permissions: [.finderExtension],
                        options: [.init(id: "terminalBundleID", kind: .string, defaultValue: .string("com.apple.Terminal"))],
                        implemented: true),
        TweakDefinition(id: .finderColumnAutosize, title: "Fit Finder column widths",
                        detail: "Size a column view column to fit its longest name.",
                        permissions: [.finderExtension],
                        options: [],
                        unavailableReason: "Finder does not let Accessibility set column widths."),
        TweakDefinition(id: .dockClickAction, title: "Dock icon click action",
                        detail: "Act on an app already in the foreground when you click its Dock icon.",
                        permissions: [.accessibility],
                        options: [.init(id: "action", kind: .enumeration, defaultValue: .string("hide"), allowedValues: ["hide", "minimize"]),
                                  .init(id: "cycleWindows", kind: .bool, defaultValue: .bool(false))],
                        implemented: true),
        TweakDefinition(id: .musicBlockAutolaunch, title: "Block Music auto-launch",
                        detail: "Close Music as soon as it starts, with an optional replacement app.",
                        options: [.init(id: "replacementBundleID", kind: .string, defaultValue: .string(""))],
                        implemented: true),
        TweakDefinition(id: .windowTrafficLights, title: "Traffic light buttons",
                        detail: "Change what the close, minimize and zoom buttons do.",
                        permissions: [.accessibility],
                        options: [.init(id: "closeAction", kind: .enumeration, defaultValue: .string("close"), allowedValues: ["close", "quit"]),
                                  .init(id: "minimizeAction", kind: .enumeration, defaultValue: .string("minimize"), allowedValues: ["minimize", "hide"]),
                                  .init(id: "zoomAction", kind: .enumeration, defaultValue: .string("fullScreen"), allowedValues: ["fullScreen", "fill", "zoom"]),
                                  .init(id: "excludedApps", kind: .appList, defaultValue: .stringList([]))],
                        implemented: true),
        TweakDefinition(id: .windowCmdTabRestore, title: "Restore minimized windows on ⌘Tab",
                        detail: "Bring back the last minimized window when you switch to an app with no visible ones.",
                        permissions: [.accessibility],
                        options: [],
                        implemented: true),
        TweakDefinition(id: .inputQuitGuard, title: "Quit shortcut guard",
                        detail: "Require a deliberate press before ⌘Q (and optionally ⌘W) can quit an app.",
                        permissions: [.accessibility],
                        options: [.init(id: "mode", kind: .enumeration, defaultValue: .string("hold"), allowedValues: ["hold", "doublePress"]),
                                  .init(id: "holdSeconds", kind: .double, defaultValue: .double(0.6), minimum: 0.2, maximum: 3.0),
                                  .init(id: "guardCloseWindow", kind: .bool, defaultValue: .bool(false)),
                                  .init(id: "excludedApps", kind: .appList, defaultValue: .stringList([]))],
                        implemented: true),
        TweakDefinition(id: .windowSwitcherMenu, title: "Window list in the menu bar",
                        detail: "Switch windows from a menu bar item instead of the app menu.",
                        permissions: [.accessibility],
                        options: [.init(id: "showIcons", kind: .bool, defaultValue: .bool(true)),
                                  .init(id: "hotkey", kind: .string, defaultValue: .string(""))],
                        implemented: true),
        TweakDefinition(id: .missionControlWindowButtons, title: "Window buttons in Mission Control",
                        detail: "Show per-window controls above Mission Control thumbnails.",
                        permissions: [.accessibility],
                        options: [.init(id: "buttons", kind: .appList, defaultValue: .stringList(["close", "minimize"]))],
                        implemented: true),
    ]

    public static func definition(for id: TweakID) -> TweakDefinition {
        all.first { $0.id == id }!
    }

    public static func isAvailable(_ id: TweakID) -> Bool { definition(for: id).implemented }

    /// Definition order, grouped the way the Tweaks page shows it.
    public static func ids(in category: TweakCategory) -> [TweakDefinition] {
        all.filter { $0.id.category == category }
    }
}
