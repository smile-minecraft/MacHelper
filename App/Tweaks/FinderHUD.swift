import AppKit
import SwiftUI

/// A short, non-activating hint shown when a Finder tweak cannot act. The panel never takes focus:
/// the person is in the middle of a Finder action, so the message only explains what to allow.
@MainActor
enum FinderHUD {
    private static var panel: NSPanel?
    private static var hosted: NSHostingView<FinderHUDView>?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String) {
        if panel == nil { createPanel() }
        guard let panel, let hosted else { return }
        hosted.rootView = FinderHUDView(message: message)
        panel.setFrame(NSRect(x: 0, y: 0, width: 420, height: 52), display: false)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 210, y: frame.maxY - 100))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0.14
        panel.animator().alphaValue = 1
        NSAnimationContext.endGrouping()

        hideTask?.cancel()
        hideTask = Task { @MainActor in
            // A newer hint replaced this one: leave it on screen.
            guard (try? await Task.sleep(for: .milliseconds(4200))) != nil, !Task.isCancelled else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.2
            panel.animator().alphaValue = 0
            NSAnimationContext.endGrouping()
        }
    }

    private static func createPanel() {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosted = NSHostingView(rootView: FinderHUDView(message: ""))
        hosted.frame = NSRect(x: 0, y: 0, width: 420, height: 52)
        panel.contentView = hosted
        Self.panel = panel
        Self.hosted = hosted
    }
}

private struct FinderHUDView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape")
                .font(.mhCallout)
                .foregroundStyle(Palette.textMuted)
            Text(message)
                .font(.mhCallout.weight(.medium))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            SurfaceShape(cornerRadius: 10).fill(Palette.card)
            SurfaceShape(cornerRadius: 10).stroke(Palette.stroke, lineWidth: 1)
        }
        .contentTransition(.opacity)
        .animation(Motion.fade, value: message)
    }
}
