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

    /// The app's English strings. Tests that compare English text look strings up here: the
    /// main bundle follows the Mac's preferred languages, which differ between machines.
    static var english: Bundle {
        get throws { try localization("en") }
    }

    /// The `.xcstrings` source document of a catalog, as it is in `App/Resources`.
    ///
    /// The test bundle carries a verbatim copy (see the MacHelperTests target in project.yml), so
    /// the tests never read the checkout itself: the test host may not be allowed to read files
    /// outside the build products, for example when the checkout is on an external volume.
    static func catalogSource(_ name: String) throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        return try #require(bundle.url(forResource: name, withExtension: "xcstrings",
                                       subdirectory: "CatalogSources"),
                            "\(name).xcstrings is missing from the test bundle")
    }

    /// The launchd agent that MacHelper.app ships in `Contents/Library/LaunchAgents`.
    static func shippedLaunchAgent(_ label: String) throws -> URL {
        let url = Bundle.main.bundleURL
            .appending(path: "Contents/Library/LaunchAgents/\(label).plist")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(label).plist is missing from the app")
        return url
    }
}

private final class BundleToken {}
