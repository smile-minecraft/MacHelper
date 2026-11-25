import AppKit
import Permissions
import SwiftUI

/// Debug aid: `MacHelper --snapshot-onboarding DIR` draws every page of the welcome guide, in the
/// light and dark appearance, to `DIR/onboarding-<n>-<step>-<light|dark>.png` and quits. Add
/// `--snapshot-preset pixel` for the Pixel Retro look. Like the other `--snapshot` modes it runs
/// beside the real app: it never saves settings, never drives the fans and never marks the guide
/// as seen. Each page is drawn from its own views, so no screen-recording permission is needed.
/// The run also draws the Helper's pre-prompt and two floating permission guides.
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
                    await render(OnboardingFlowView(start: step, finish: {}), size: OnboardingFlowView.size,
                                 appearance: appearance,
                                 to: dir.appending(path: "onboarding-\(step.rawValue + 1)-\(step)-\(name).png"))
                }
                // The permission pieces the guide opens: an explanation and a floating guide.
                await render(PermissionPrePromptSheet(id: .helper), size: nil, appearance: appearance,
                             to: dir.appending(path: "permission-preprompt-helper-\(name).png"))
                for id in [PermissionID.fullDiskAccess, .helper] {
                    await render(PermissionGuideView(id: id, close: {}), size: nil, appearance: appearance,
                                 to: dir.appending(path: "permission-guide-\(id.rawValue)-\(name).png"))
                }
            }
            NSApp.terminate(nil)
        }
        return true
    }

    /// Draws one view; a nil size uses the view's own fitting size.
    private static func render(_ view: some View, size: CGSize?, appearance: NSAppearance.Name, to file: URL) async {
        let host = NSHostingView(rootView: view)
        let size = size ?? host.fittingSize
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
