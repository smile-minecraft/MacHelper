import Foundation
import Testing

enum FixtureLoader {
    static func array(_ name: String) -> [[String: Any]] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "plist", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else {
            Issue.record("Missing fixture \(name)")
            return []
        }
        return value
    }

    static func dictionary(_ name: String) -> [String: Any] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "plist", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            Issue.record("Missing fixture \(name)")
            return [:]
        }
        return value
    }
}
