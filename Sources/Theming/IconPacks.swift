import Foundation

/// Every icon the interface shows, by id. The built-in pixel art lives in the asset catalog as
/// `px.<id>`; an icon pack replaces any of them with `<id>.<ext>` files.
public enum IconCatalog {
    public struct Entry: Sendable, Hashable, Identifiable {
        public let id: String
        /// English name (the app localizes it).
        public let title: String
        /// SF Symbol used by the "system symbols" set.
        public let symbol: String
        /// Theme color the symbol is tinted with.
        public let tint: ThemeColors.Role
    }

    public static let entries: [Entry] = [
        Entry(id: "app", title: "App icon (Dock)", symbol: "fan", tint: .accent),
        Entry(id: "mascot", title: "Mascot", symbol: "face.smiling", tint: .accent),
        Entry(id: "overview", title: "Overview", symbol: "square.grid.2x2", tint: .blue),
        Entry(id: "monitor", title: "Monitor", symbol: "waveform.path.ecg", tint: .cyan),
        Entry(id: "health", title: "Health Check", symbol: "heart.text.square", tint: .rose),
        Entry(id: "fans", title: "Fans", symbol: "fan", tint: .mint),
        Entry(id: "optimize", title: "Optimize", symbol: "sparkles", tint: .amber),
        Entry(id: "disk", title: "Disk Analysis", symbol: "chart.pie", tint: .violet),
        Entry(id: "uninstall", title: "Uninstall", symbol: "trash", tint: .rose),
        Entry(id: "startup", title: "Startup Items", symbol: "power", tint: .orange),
        Entry(id: "settings", title: "Settings", symbol: "gearshape", tint: .slate),
        Entry(id: "cpu", title: "CPU", symbol: "cpu", tint: .blue),
        Entry(id: "gpu", title: "GPU", symbol: "square.stack.3d.up", tint: .violet),
        Entry(id: "memory", title: "Memory", symbol: "memorychip", tint: .cyan),
        Entry(id: "ssd", title: "Disk", symbol: "internaldrive", tint: .violet),
        Entry(id: "network", title: "Network", symbol: "network", tint: .blue),
        Entry(id: "battery", title: "Battery", symbol: "battery.75percent", tint: .mint),
        Entry(id: "temperature", title: "Temperature", symbol: "thermometer.medium", tint: .orange),
        Entry(id: "power", title: "Power", symbol: "bolt", tint: .amber),
        Entry(id: "empty.box", title: "Empty list", symbol: "shippingbox", tint: .slate),
        Entry(id: "empty.clean", title: "Nothing to clean", symbol: "sparkles", tint: .mint),
        Entry(id: "empty.scan", title: "Scan prompt", symbol: "magnifyingglass", tint: .blue),
    ]

    public static let ids: Set<String> = Set(entries.map(\.id))

    public static func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    /// "px.cpu" → "cpu"; plain ids pass through.
    public static func id(forAssetName name: String) -> String {
        name.hasPrefix("px.") ? String(name.dropFirst(3)) : name
    }

    /// The asset catalog name of the built-in pixel icon (nil for "app", which is the app icon).
    public static func assetName(_ id: String) -> String? { id == "app" ? nil : "px." + id }
}

/// `pack.json` inside an icon pack folder. Everything is optional.
public struct IconPackManifest: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var name: String?
    public var author: String?
    /// Draw without smoothing (pixel art). Nil = decide per image by size (≤ 64 px is pixel art).
    public var pixelated: Bool?

    public init(name: String? = nil, author: String? = nil, pixelated: Bool? = nil) {
        self.name = name
        self.author = author
        self.pixelated = pixelated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        name = try? c.decode(String.self, forKey: .name)
        author = try? c.decode(String.self, forKey: .author)
        pixelated = try? c.decode(Bool.self, forKey: .pixelated)
    }
}

public struct IconPack: Sendable, Hashable, Identifiable {
    /// The folder name.
    public let id: String
    public let name: String
    public let author: String?
    public let directory: URL
    public let pixelated: Bool?
    /// Icon id → image file.
    public let files: [String: URL]
}

/// Icon packs as folders under one root, plus a special `_overrides` folder for single icons the
/// user replaced by hand. Only image files named after known icon ids are ever read or copied.
public struct IconPackLibrary: Sendable {
    public enum PackError: Error, CustomStringConvertible, Equatable {
        case notAFolder(String)
        case noIcons(String)
        case unsupportedFile(String)
        case unknownIcon(String)
        case tooLarge(String)

        public var description: String {
            switch self {
            case .notAFolder(let p): "\(p) is not a folder"
            case .noIcons(let p): "\(p) has no images named after MacHelper icons (for example cpu.png)"
            case .unsupportedFile(let p): "\(p) is not a supported image (PNG, PDF, SVG, JPEG, TIFF, HEIC, ICNS)"
            case .unknownIcon(let id): "\(id) is not a MacHelper icon"
            case .tooLarge(let p): "\(p) is larger than 5 MB"
            }
        }
    }

    public static let overridesFolder = "_overrides"
    public static let allowedExtensions: Set<String> = ["png", "pdf", "svg", "jpg", "jpeg", "tiff", "tif", "heic", "icns"]
    public static let maxFileSize = 5_000_000

    public let root: URL

    public init(root: URL) { self.root = root }

    public var overridesDirectory: URL { root.appending(path: Self.overridesFolder) }

    /// Installed packs (not the overrides folder), sorted by name.
    public func packs() -> [IconPack] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.filter { $0.lastPathComponent != Self.overridesFolder && !$0.lastPathComponent.hasPrefix(".") && Self.isDirectory($0) }
            .compactMap { load($0) }
            .filter { !$0.files.isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func pack(id: String) -> IconPack? { packs().first { $0.id == id } }

    public func overrides() -> IconPack? { load(overridesDirectory) }

    public func load(_ dir: URL) -> IconPack? {
        guard Self.isDirectory(dir) else { return nil }
        let manifest = (try? Data(contentsOf: dir.appending(path: "pack.json")))
            .flatMap { try? JSONDecoder().decode(IconPackManifest.self, from: $0) }
        return IconPack(id: dir.lastPathComponent, name: manifest?.name ?? dir.lastPathComponent, author: manifest?.author,
                        directory: dir, pixelated: manifest?.pixelated, files: Self.iconFiles(in: dir))
    }

    /// `<id>.<ext>` files for known ids; when several formats exist, the first in a fixed order wins.
    static func iconFiles(in dir: URL) -> [String: URL] {
        let order = ["svg", "pdf", "png", "heic", "tiff", "tif", "jpg", "jpeg", "icns"]
        var found: [String: URL] = [:]
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        for url in entries.sorted(by: { (order.firstIndex(of: $0.pathExtension.lowercased()) ?? 99) < (order.firstIndex(of: $1.pathExtension.lowercased()) ?? 99) }) {
            let ext = url.pathExtension.lowercased()
            let id = url.deletingPathExtension().lastPathComponent
            guard allowedExtensions.contains(ext), IconCatalog.ids.contains(id), found[id] == nil,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max) <= maxFileSize else { continue }
            found[id] = url
        }
        return found
    }

    /// Copies the usable files of a pack folder into the library (never the folder as a whole).
    @discardableResult
    public func importPack(from source: URL) throws -> IconPack {
        guard Self.isDirectory(source) else { throw PackError.notAFolder(source.lastPathComponent) }
        let files = Self.iconFiles(in: source)
        guard !files.isEmpty else { throw PackError.noIcons(source.lastPathComponent) }
        let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []))
        let base = Self.safeFolderName(source.lastPathComponent)
        var name = base
        var i = 2
        while existing.contains(name) { name = "\(base)-\(i)"; i += 1 }
        let dest = root.appending(path: name)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for (id, file) in files {
            try FileManager.default.copyItem(at: file, to: dest.appending(path: "\(id).\(file.pathExtension.lowercased())"))
        }
        if let manifest = try? Data(contentsOf: source.appending(path: "pack.json")), manifest.count < 100_000 {
            try manifest.write(to: dest.appending(path: "pack.json"))
        }
        guard let pack = load(dest) else { throw PackError.noIcons(name) }
        return pack
    }

    public func deletePack(id: String) throws {
        let dir = root.appending(path: Self.safeFolderName(id))
        guard id != Self.overridesFolder, Self.isDirectory(dir) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    /// Replaces one icon with an image file (kept in `_overrides`, across all sets).
    public func setOverride(_ id: String, from file: URL) throws {
        guard IconCatalog.ids.contains(id) else { throw PackError.unknownIcon(id) }
        let ext = file.pathExtension.lowercased()
        guard Self.allowedExtensions.contains(ext) else { throw PackError.unsupportedFile(file.lastPathComponent) }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        guard size <= Self.maxFileSize else { throw PackError.tooLarge(file.lastPathComponent) }
        try FileManager.default.createDirectory(at: overridesDirectory, withIntermediateDirectories: true)
        try removeOverride(id)
        try FileManager.default.copyItem(at: file, to: overridesDirectory.appending(path: "\(id).\(ext)"))
    }

    public func removeOverride(_ id: String) throws {
        for f in (try? FileManager.default.contentsOfDirectory(at: overridesDirectory, includingPropertiesForKeys: nil)) ?? []
        where f.deletingPathExtension().lastPathComponent == id {
            try FileManager.default.removeItem(at: f)
        }
    }

    /// Letters, digits, spaces, dots, dashes and underscores; never empty, never hidden, never the overrides folder.
    public static func safeFolderName(_ s: String) -> String {
        var n = String(s.map { $0.isLetter || $0.isNumber || " ._-".contains($0) ? $0 : "-" }.prefix(80))
            .trimmingCharacters(in: .whitespaces)
        while n.hasPrefix(".") || n.hasPrefix("_") { n.removeFirst() }
        return n.isEmpty ? "Icons" : n
    }

    static func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }
}
