import AppKit
import Foundation
import Tweaks

/// Draws close and minimize buttons over Mission Control's window thumbnails.
///
/// Mission Control cannot be observed through notifications, so while the tweak is on a timer asks
/// the WindowManager for its `mc.display` group a little less than once a second. While Mission
/// Control is closed that group is gone and the overlays stay hidden, which is also what makes the
/// cost of the poll small: one accessibility read of one small tree.
///
/// The overlays are transparent panels at the screen saver window level (above Mission Control) whose
/// content view only claims clicks on the buttons themselves; every other click falls through to
/// Mission Control and keeps its own gestures working.
@MainActor
final class MissionControlOverlay {
    private var enabled = false
    private var showsClose = true
    private var showsMinimize = true
    private var timer: Timer?
    private var panels: [NSPanel] = []
    private var layoutSignature = ""

    private static let buttonSize: CGFloat = 22
    private static let buttonGap: CGFloat = 4
    private static let thumbnailInset: CGFloat = 8

    func configure(enabled: Bool, settings: TweakSettings) {
        let buttons = Set(settings.stringList("buttons", for: .missionControlWindowButtons))
        let close = buttons.contains("close")
        let minimize = buttons.contains("minimize")
        if enabled == self.enabled, close == showsClose, minimize == showsMinimize { return }
        self.enabled = enabled
        showsClose = close
        showsMinimize = minimize
        layoutSignature = ""
        if enabled { startPolling() } else { stopPolling() }
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // .common keeps the timer alive while a menu is tracking or a window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        hideOverlays()
    }

    private func poll() {
        guard enabled else { return }
        let thumbnails = MissionControlModel.thumbnails()
        guard !thumbnails.isEmpty else {
            if !panels.isEmpty { hideOverlays() }
            layoutSignature = ""
            return
        }
        let signature = "\(showsClose)\(showsMinimize)|" + thumbnails
            .map { "\($0.identifier)|\($0.title)|\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height))" }
            .joined(separator: ";")
        guard signature != layoutSignature else { return }
        layoutSignature = signature
        layout(thumbnails)
    }

    // MARK: - Overlay geometry

    private func layout(_ thumbnails: [MissionControlThumbnail]) {
        // AX and CGWindowList measure from the top left of the primary display; AppKit measures from
        // its bottom left. One conversion covers every screen.
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
        ensurePanels()
        for panel in panels { panel.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        for thumbnail in thumbnails {
            let center = CGPoint(x: thumbnail.frame.midX, y: thumbnail.frame.midY)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
                  let panel = panels.first(where: { $0.frame == screen.frame }),
                  let content = panel.contentView else { continue }
            var offset = Self.thumbnailInset
            if showsClose {
                addButton(.close, thumbnail: thumbnail, content: content, offset: offset,
                          primaryHeight: primaryHeight, screen: screen)
                offset += Self.buttonSize + Self.buttonGap
            }
            if showsMinimize {
                addButton(.minimize, thumbnail: thumbnail, content: content, offset: offset,
                          primaryHeight: primaryHeight, screen: screen)
            }
        }
        for panel in panels where !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func addButton(_ action: WindowAction, thumbnail: MissionControlThumbnail, content: NSView,
                           offset: CGFloat, primaryHeight: CGFloat, screen: NSScreen) {
        let size = Self.buttonSize
        let x = thumbnail.frame.minX + offset
        let y = primaryHeight - thumbnail.frame.minY - size - Self.thumbnailInset
        // The panels cover one screen each; a thumbnail belongs to the screen it sits on.
        let frame = CGRect(x: x - screen.frame.minX, y: y - screen.frame.minY, width: size, height: size)
        let button = OverlayButton(action: action, thumbnail: thumbnail, frame: frame)
        button.target = self
        button.action = #selector(runAction(_:))
        content.addSubview(button)
    }

    private func ensurePanels() {
        for screen in NSScreen.screens where !panels.contains(where: { $0.frame == screen.frame }) {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.ignoresMouseEvents = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.contentView = OverlayContentView(frame: CGRect(origin: .zero, size: screen.frame.size))
            panels.append(panel)
        }
        // A display that went away takes its panel with it.
        panels.removeAll { panel in
            guard NSScreen.screens.contains(where: { $0.frame == panel.frame }) else {
                panel.orderOut(nil)
                return true
            }
            return false
        }
    }

    private func hideOverlays() {
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        }
        layoutSignature = ""
    }

    @objc private func runAction(_ sender: OverlayButton) {
        _ = MissionControlModel.perform(sender.windowAction, on: sender.thumbnail)
        // The thumbnail that was just closed or minimized is stale: rebuild on the next poll.
        layoutSignature = ""
    }

    // MARK: - Debug aid

    /// The thumbnails Mission Control publishes right now, as plain lines. `--dump-mission-control`
    /// prints them: this is the accessibility data the overlay is positioned from, so the evidence
    /// for "the thumbnails can be read" is the same call the tweak makes.
    static func thumbnailsDescription() -> [String] {
        guard MissionControlModel.windowManagerPID() != nil else {
            return ["WindowManager (com.apple.WindowManager) is not running."]
        }
        let thumbnails = MissionControlModel.thumbnails()
        guard !thumbnails.isEmpty else {
            return ["Mission Control is closed (no mc.display group)."]
        }
        var lines = ["\(thumbnails.count) thumbnail(s) from the WindowManager mc.display group:"]
        for thumbnail in thumbnails {
            let bundle = thumbnail.bundleID ?? "(unknown app)"
            let title = thumbnail.title.isEmpty ? "(untitled)" : thumbnail.title
            let frame = thumbnail.frame
            lines.append("  \(bundle) \"\(title)\" id=\(thumbnail.identifier) "
                + "frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        }
        return lines
    }
}

/// One traffic-light-sized control drawn above a Mission Control thumbnail.
private final class OverlayButton: NSButton {
    let windowAction: WindowAction
    let thumbnail: MissionControlThumbnail

    init(action: WindowAction, thumbnail: MissionControlThumbnail, frame: CGRect) {
        self.windowAction = action
        self.thumbnail = thumbnail
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = frame.height / 2
        layer?.backgroundColor = NSColor(Palette.inset).withAlphaComponent(0.92).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(Palette.stroke).cgColor
        imagePosition = .imageOnly
        let symbol = action == .close ? "xmark" : "minus"
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        contentTintColor = NSColor(Palette.text)
        toolTip = action == .close ? String(localized: "Close") : String(localized: "Minimize")
        setAccessibilityLabel(action == .close ? String(localized: "Close Window") : String(localized: "Minimize Window"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Transparent content that lets every click that is not on a button through to Mission Control.
private final class OverlayContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
