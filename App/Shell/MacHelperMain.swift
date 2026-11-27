import AppKit
import Foundation

/// The process entry point. A unit-test host starts AppKit on its own instead of the SwiftUI
/// `App`: the app then never opens a window, a menu bar item or a Dock icon, and the launch work
/// that belongs to a real session (Sparkle, the Helper, launchd agents, the fan switcher, the
/// tweak engine) never runs. The test bundle only needs a live `NSApplication` and its run loop.
@main
enum MacHelperMain {
    static func main() {
        if TestHost.isRunningTests {
            TestHost.runBareApplication()
            return
        }
        MacHelperApp.main()
    }
}
