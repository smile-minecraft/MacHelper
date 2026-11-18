import Foundation

/// Names and grouping shared by the per-process samplers.
enum ProcessGrouping {
    /// The outermost `.app` bundle containing an executable path, or nil for a bare executable.
    static func outermostApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func appName(_ appPath: String) -> String {
        let name = FileManager.default.displayName(atPath: appPath)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
