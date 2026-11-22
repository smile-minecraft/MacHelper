import AppKit
import SwiftUI

/// Debug aid: `MacHelper --snapshot-onboarding DIR` draws every page of the welcome guide, in the
/// light and dark appearance, to `DIR/onboarding-<n>-<step>-<light|dark>.png` and quits. Add
/// `--snapshot-preset pixel` for the Pixel Retro look. Like the other `--snapshot` modes it runs
/// beside the real app: it never saves settings, never drives the fans and never marks the guide
/// as seen. Each page is drawn from its own views, so no screen-recording permission is needed.
@MainActor
enum OnboardingSnapshot {
    /// Starts the snapshot run when the argument is present; true means the app is busy with it.
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-onboarding"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1])
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(2))
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for step in OnboardingStep.allCases {
                    await render(step, appearance: appearance,
                                 to: dir.appending(path: "onboarding-\(step.rawValue + 1)-\(step)-\(name).png"))
                }
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private static func render(_ step: OnboardingStep, appearance: NSAppearance.Name, to file: URL) async {
        let size = OnboardingFlowView.size
        let host = NSHostingView(rootView: OnboardingFlowView(start: step, finish: {}))
        host.frame = CGRect(origin: .zero, size: size)
        // An off-screen window, so the slime's AppKit view gets a window and draws.
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        // Let the page's entrance cascade finish.
        try? await Task.sleep(for: .seconds(1.5))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
        window.orderOut(nil)
        window.close()
    }
}
