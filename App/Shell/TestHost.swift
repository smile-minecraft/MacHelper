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
    /// a test can exercise the stores that persist settings without changing the person's Mac;
    /// the domain is deleted when the host terminates.
    static let defaultsSuiteName = "com.machelper.MacHelper.unit-tests"

    /// Every preference read and write the views and stores make during a test run goes here.
    /// Production uses the app's own domain.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isRunningTests else { return .standard }
        guard let suite = UserDefaults(suiteName: defaultsSuiteName) else { return .standard }
        // A crashed run can leave the suite behind; start every run from the shipped defaults.
        suite.removePersistentDomain(forName: defaultsSuiteName)
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
        application.run()
        exit(EXIT_SUCCESS)
    }

    /// Deletes the throwaway domain, so a finished run leaves no preference file on the Mac.
    static func removeDefaults() {
        guard isRunningTests else { return }
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    }
}

/// The whole delegate of a test host: `NSApplication` needs one to run, and the run has to leave
/// the throwaway preferences domain behind it.
final class TestHostDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        TestHost.removeDefaults()
    }
}
