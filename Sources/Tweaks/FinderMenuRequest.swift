import Foundation

/// What the Finder extension can ask the app to do. The extension never touches the disk or the
/// clipboard itself: it sends a request and the app decides whether to act on it.
public enum FinderMenuAction: String, CaseIterable, Codable, Sendable {
    case newFile = "new-file"
    case copyPath = "copy-path"
    case openTerminal = "open-terminal"
    case cut
}

/// One request from the extension, carrying the paths Finder reported.
public struct FinderMenuRequest: Equatable, Sendable {
    public let action: FinderMenuAction
    /// Absolute paths, exactly as Finder reported them. Validation happens in the app.
    public let paths: [String]
    /// Only for `newFile`; nil keeps whatever the tweak's settings say.
    public let template: FinderFileTemplate?
    /// Identifies the request so the two delivery paths (URL scheme, distributed notification)
    /// cannot run the same click twice.
    public let id: String

    public init(action: FinderMenuAction, paths: [String], template: FinderFileTemplate? = nil,
                id: String = UUID().uuidString) {
        self.action = action
        self.paths = paths
        self.template = template
        self.id = id
    }
}

/// The URL scheme the extension uses. `machelper://finder/copy-path?path=/Users/me/a.txt&id=…`
public enum FinderMenuURL {
    public static let scheme = "machelper"
    public static let host = "finder"

    public static func make(_ request: FinderMenuRequest) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + request.action.rawValue
        var items = request.paths.map { URLQueryItem(name: "path", value: $0) }
        if let template = request.template { items.append(URLQueryItem(name: "template", value: template.rawValue)) }
        items.append(URLQueryItem(name: "id", value: request.id))
        components.queryItems = items
        return components.url
    }

    public static func parse(_ url: URL) -> FinderMenuRequest? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host else { return nil }
        let actionName = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        guard let action = FinderMenuAction(rawValue: actionName) else { return nil }
        let items = components.queryItems ?? []
        let paths = items.filter { $0.name == "path" }.compactMap(\.value)
        let template = items.first { $0.name == "template" }?.value.flatMap(FinderFileTemplate.init(rawValue:))
        let id = items.first { $0.name == "id" }?.value.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        return FinderMenuRequest(action: action, paths: paths, template: template, id: id)
    }
}

/// Validation of what arrives from the extension. The extension is a separate, sandboxed process and
/// its URL can be opened by anything on the Mac, so every path is checked again here before the app
/// writes a file, opens a terminal or changes the clipboard.
public enum FinderMenuRequestRules {
    public static let maxPaths = 64
    public static let maxPathLength = 4_096

    /// Locations a person's file actions may touch. Everything else is a system location where a
    /// request from a menu item has no business writing.
    static let protectedPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/dev", "/etc", "/cores", "/Library/Apple",
        "/private/etc", "/private/var/db", "/net", "/home",
    ]

    /// The disk checks, injected so the rules can be tested without a file system.
    public struct Environment: Sendable {
        public var exists: @Sendable (String) -> Bool
        public var isDirectory: @Sendable (String) -> Bool
        public var isWritableDirectory: @Sendable (String) -> Bool

        public init(exists: @escaping @Sendable (String) -> Bool,
                    isDirectory: @escaping @Sendable (String) -> Bool,
                    isWritableDirectory: @escaping @Sendable (String) -> Bool) {
            self.exists = exists
            self.isDirectory = isDirectory
            self.isWritableDirectory = isWritableDirectory
        }
    }

    /// An absolute, already-normalized path without traversal or control characters.
    public static func isSafePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count <= maxPathLength,
              !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else { return false }
        return !path.contains("~")
    }

    /// A location a person can own: not a system folder, and not the volume root.
    public static func isUserLocation(_ path: String) -> Bool {
        guard path != "/" else { return false }
        return !protectedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Returns the request with its paths standardized, or nil when any part of it fails a check.
    public static func validate(_ request: FinderMenuRequest, _ environment: Environment) -> FinderMenuRequest? {
        guard !request.paths.isEmpty, request.paths.count <= maxPaths else { return nil }
        var paths: [String] = []
        for raw in request.paths {
            let path = (raw as NSString).standardizingPath
            guard isSafePath(path), isUserLocation(path), environment.exists(path) else { return nil }
            paths.append(path)
        }
        switch request.action {
        case .newFile:
            // One folder to create the file in. A right-click on files names the files, and the
            // new file belongs next to them, in the folder the window shows.
            let folder = newFileFolder(for: paths, isDirectory: environment.isDirectory)
            guard isUserLocation(folder), environment.isWritableDirectory(folder) else { return nil }
            paths = [folder]
        case .copyPath, .cut, .openTerminal:
            break
        }
        return FinderMenuRequest(action: request.action, paths: paths,
                                 template: request.template, id: request.id)
    }

    /// Where New File creates its file: the folder itself when one folder was sent (a right-click on
    /// a folder's background or on one folder), otherwise the folder holding the first item.
    public static func newFileFolder(for paths: [String], isDirectory: (String) -> Bool) -> String {
        guard let first = paths.first else { return "/" }
        if paths.count == 1, isDirectory(first) { return first }
        return (first as NSString).deletingLastPathComponent
    }

    /// The folder `open-terminal` should show: the folder itself, or the one holding the file.
    public static func terminalDirectory(for path: String, isDirectory: Bool) -> String {
        isDirectory ? path : (path as NSString).deletingLastPathComponent
    }
}
