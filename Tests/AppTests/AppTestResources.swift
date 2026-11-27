import Foundation
import Testing

/// Where the tests read the app's string catalogs.
///
/// The catalogs ship inside MacHelper.app, the bundle the tests are hosted in: Xcode compiles
/// every `.xcstrings` into `<language>.lproj/<Table>.strings` there, and the app is what actually
/// resolves those strings at runtime. The source document is read from the checkout instead, so
/// the completeness checks compare the source with what ships.
enum AppTestResources {
    /// The compiled resources of MacHelper.app.
    static var resources: URL {
        get throws {
            try #require(Bundle.main.resourceURL, "the app bundle has no resources")
        }
    }

    /// A `<language>.lproj` bundle of the app.
    static func localization(_ language: String) throws -> Bundle {
        try #require(Bundle(url: try resources.appendingPathComponent("\(language).lproj")),
                     "\(language).lproj is missing from the app")
    }

    /// The `.xcstrings` source document in the checkout (`App/Resources`).
    static func catalogSource(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appending(path: "App/Resources/\(name).xcstrings")
    }
}
