import AppKit
import Foundation

/// Detects the unit-test host and keeps a test run inside its own preferences.
///
/// `MacHelperTests` is a bundle hosted in MacHelper.app, so the app binary itself runs while the
/// tests do. In that mode `MacHelperMain` starts AppKit without the SwiftUI `App`, and the app
/// must not register the Helper, touch launchd or the login items, open a window or the menu bar
/// item, start Sparkle or the samplers, and it must not write the person's preferences: `make
/// test` compares the `com.machelper.MacHelper` domain before and after the run and fails when it
/// changed.
enum TestHost {
    /// True when Xcode or `xcodebuild test` launched the app to host the tests. Both harness
    /// variables are checked because Xcode has set either one across versions, and the scheme
    /// also passes `--unit-tests` so the guard still holds if that changes again.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        || CommandLine.arguments.contains("--unit-tests")

    /// The defaults domain the test host writes to. It is separate from the app's real domain so
    /// a test can exercise the stores that persist settings without changing the person's Mac.
    static let defaultsSuiteName = "com.machelper.MacHelper.unit-tests"

    /// Where every test-run preferences file lives: a folder of this run in the temporary
    /// directory, deleted when the host exits. A suite named by a path keeps its file there
    /// instead of in ~/Library/Preferences, where the preferences daemon would recreate an empty
    /// file after the domain was removed.
    static let defaultsDirectory: URL = FileManager.default.temporaryDirectory
        .appending(path: "MacHelperUnitTests-\(getpid())", directoryHint: .isDirectory)

    /// The suite name of a throwaway preferences domain called `name`, inside `defaultsDirectory`.
    static func scratchSuiteName(_ name: String) -> String {
        try? FileManager.default.createDirectory(at: defaultsDirectory, withIntermediateDirectories: true)
        return defaultsDirectory.appending(path: name).path
    }

    /// Every preference read and write the views and stores make during a test run goes here.
    /// Production uses the app's own domain.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isRunningTests else { return .standard }
        let name = scratchSuiteName(defaultsSuiteName)
        // Never fall back to the person's own domain while tests run.
        guard let suite = UserDefaults(suiteName: name) else {
            fatalError("MacHelper: could not open the test preferences at \(name)")
        }
        return suite
    }()

    /// The delegate of the bare application a test run starts. It exists only to clean up.
    nonisolated(unsafe) private static var delegate: TestHostDelegate?

    /// Runs AppKit without any SwiftUI scene. The test bundle needs a live application and its
    /// run loop; nothing is shown, and no launch work runs.
    static func runBareApplication() -> Never {
        FileHandle.standardError.write(Data("MacHelper: running as the unit-test host\n".utf8))
        let application = NSApplication.shared
        let delegate = TestHostDelegate()
        self.delegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        // XCTest ends the host with exit() once the tests finished, so the delegate never hears
        // `applicationWillTerminate`; clean up on exit as well.
        atexit { TestHost.removeDefaults() }
        application.run()
        exit(EXIT_SUCCESS)
    }

    /// Deletes this run's preferences folder, so a finished run leaves no preference file behind.
    static func removeDefaults() {
        guard isRunningTests else { return }
        try? FileManager.default.removeItem(at: defaultsDirectory)
    }
}

/// The whole delegate of a test host: `NSApplication` needs one to run, and the run must not leave
/// its throwaway preferences behind.
final class TestHostDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        TestHost.removeDefaults()
    }
}
