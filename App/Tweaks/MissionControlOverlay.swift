import AppKit
import Foundation
import Tweaks

/// Draws close and minimize buttons over Mission Control's window thumbnails.
///
/// Mission Control cannot be observed through notifications, so while the tweak is on a timer asks
/// the WindowManager for its `mc.display` group: a little less than once a second while Mission
/// Control is closed, several times a second while the buttons show, so they leave the screen right
/// after Mission Control does. The read runs off the main thread: a WindowManager that stops
/// answering must not stall the app's own windows.
///
/// Every button is its own small panel at the shielding window level (above Mission Control). Only
/// the buttons cover anything: a click anywhere else reaches Mission Control itself, because a
/// window that covers the screen takes every click inside its frame whatever its view hit-tests.
@MainActor
final class MissionControlOverlay {
    private var enabled = false
    private var showsClose = true
    private var showsMinimize = true
    private var timer: Timer?
    private var panels: [NSPanel] = []
    private var layoutSignature = ""
    private var tick = 0
    private var reading = false
    /// Bumped whenever polling restarts or stops, so a read that was in flight then is dropped.
    private var generation = 0

    private static let tickInterval: TimeInterval = 0.15
    /// While nothing shows, only every fifth tick reads (about 0.75 s).
    private static let idleTicks = 5
    private static let readTimeout: Float = 0.2

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
        generation += 1
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
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
        generation += 1
        hideOverlays()
    }

    private func poll() {
        guard enabled, !reading else { return }
        tick += 1
        guard !panels.isEmpty || tick % Self.idleTicks == 1 else { return }
        reading = true
        let generation = generation
        let timeout = Self.readTimeout
        Task { [weak self] in
            let thumbnails = await Task.detached(priority: .userInitiated) {
                MissionControlModel.thumbnails(timeout: timeout)
            }.value
            guard let self else { return }
            reading = false
            guard enabled, generation == self.generation else { return }
            show(thumbnails)
        }
    }

    private func show(_ thumbnails: [MissionControlThumbnail]) {
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
        removePanels()
        for thumbnail in thumbnails {
            var offset = Self.thumbnailInset
            if showsClose {
                addButton(.close, thumbnail: thumbnail, offset: offset, primaryHeight: primaryHeight)
                offset += Self.buttonSize + Self.buttonGap
            }
            if showsMinimize {
                addButton(.minimize, thumbnail: thumbnail, offset: offset, primaryHeight: primaryHeight)
            }
        }
    }

    private func addButton(_ action: WindowAction, thumbnail: MissionControlThumbnail,
                           offset: CGFloat, primaryHeight: CGFloat) {
        let size = Self.buttonSize
        // AppKit's global space, bottom left of the primary display: one conversion covers every screen.
        let frame = CGRect(x: thumbnail.frame.minX + offset,
                           y: primaryHeight - thumbnail.frame.minY - size - Self.thumbnailInset,
                           width: size, height: size)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        let button = OverlayButton(action: action, thumbnail: thumbnail,
                                   frame: CGRect(origin: .zero, size: frame.size))
        button.target = self
        button.action = #selector(runAction(_:))
        panel.contentView = button
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    private func removePanels() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    private func hideOverlays() {
        removePanels()
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

    /// MacHelper is never the active app while Mission Control shows, and a click on an inactive
    /// app's window only brings it forward unless the view accepts the first mouse: without this
    /// the button needs a second click, which Mission Control never waits for.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
