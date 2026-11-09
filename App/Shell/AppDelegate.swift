import AppKit
import DiskScan
import HelperProtocol
import SwiftUI

/// Menu bar app shell. NSStatusItem + NSHostingView rather than MenuBarExtra,
/// because MenuBarExtra's label cannot host custom drawn content like sparklines.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var app: AppModel { AppModel.shared }
    private var settings: MonitorSettingsStore { app.settings }
    private var store: MonitorStore { app.store }
    private var fanModel: FanControlModel { app.fanModel }
    private var fanSwitcher: FanAutoSwitcher { app.fanSwitcher }
    private var diskModel: DiskAnalysisModel { app.diskModel }
    private var heartbeatTask: Task<Void, Never>?

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    /// The Sparkle updater. Created eagerly below so background checks start
    /// with the rest of the app, and retained so the updater is never deallocated.
    private let updater: UpdaterController

    override init() {
        self.updater = UpdaterController.shared
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        observeWindowVisibility()
        AppModel.prepareDockPreference()
    }

    /// Re-evaluates the Dock mode whenever an ordinary window opens, closes, or leaves the Dock.
    /// The notification can arrive before `isVisible` changes, so the check runs on the next turn.
    private func observeWindowVisibility() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification,
                     NSWindow.didResignMainNotification,
                     NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            center.addObserver(self, selector: #selector(windowVisibilityChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        // Only main-window notifications move the overview's visibility flag; other windows
        // (Settings, etc.) still re-evaluate the Dock mode. willClose / didMiniaturize hide
        // the window even before isVisible flips, so set the flag directly for those.
        let window = notification.object as? NSWindow
        let isAboutMainWindow = window?.identifier?.rawValue.hasPrefix("main") == true
        let hiddenNow = notification.name == NSWindow.willCloseNotification
            || notification.name == NSWindow.didMiniaturizeNotification
        DispatchQueue.main.async {
            AppModel.applyDockPreference()
            if isAboutMainWindow { self.app.hasVisibleMainWindow = hiddenNow ? false : AppModel.mainWindowIsVisible() }
        }
    }

    /// The menu bar keeps running when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app.show(app.section) }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
        // Sparkle stops the background recorder before replacing the app; restore it if this
        // launch is the other side of an update and the user still wants it.
        app.backgroundRecording.resumeAfterUpdateIfNeeded()
        // The window scene may not have ordered the main window in yet. Give it a beat before
        // deciding that a `whileWindowOpen` app has no windows; the window observers also update
        // the policy as soon as it appears or closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            AppModel.applyDockPreference()
            self.app.hasVisibleMainWindow = AppModel.mainWindowIsVisible()
        }
        // Ad-hoc builds: launchd pins the helper's cdhash, so an updated bundle must re-register.
        _ = try? HelperClient.shared.refreshRegistrationIfNeeded()
        startHeartbeat()
        // The health score (overview, health page, menu bar) re-checks the last 24 hours every few minutes.
        app.healthModel.startScoreUpdates { [weak self] in self?.store.persistentHistory }
        let args = CommandLine.arguments
        // Snapshot instances run next to the real app: never let them drive the fans.
        if !args.contains(where: { $0.hasPrefix("--snapshot") || $0 == "--export-icon-template" }) {
            fanModel.onUserApplied = { [weak self] policy in self?.fanSwitcher.userApplied(policy) }
            fanSwitcher.start()
        }
        // After an update, rewrite the agent skills MacHelper installed (never a SKILL.md it didn't write).
        if !args.contains(where: { $0.hasPrefix("--snapshot") || $0 == "--export-icon-template" }) {
            Task.detached(priority: .utility) { AgentSkillSetup.refreshInstalled() }
        }
        if let dir = ThemeStore.shared.exportTemplateOnLaunch {
            do { try ThemeStore.shared.exportIconTemplate(to: dir) } catch { print("export failed: \(error)") }
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--export-mascot-icon"), i + 1 < args.count {
            exportMascotIcon(to: URL(fileURLWithPath: args[i + 1]))
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--snapshot-mascot"), i + 1 < args.count {
            renderMascotSheet(to: URL(fileURLWithPath: args[i + 1]))
            return
        }
        if let i = args.firstIndex(of: "--snapshot-disk"), i + 2 < args.count {
            renderDiskSnapshots(scan: args[i + 1], to: URL(fileURLWithPath: args[i + 2]))
            return
        }
        // Debug aid for measuring CPU per page: `--snapshot-section overview` opens that page and stays there.
        if let i = args.firstIndex(of: "--snapshot-section"), i + 1 < args.count, let section = AppSection(rawValue: args[i + 1]) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                app.show(section)
            }
            return
        }
        if let i = args.firstIndex(of: "--snapshot-window"), i + 1 < args.count {
            renderWindowSnapshots(to: URL(fileURLWithPath: args[i + 1]))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            renderSnapshots(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }

    /// Debug aid: `MacHelper --snapshot DIR` samples for a few seconds, renders the
    /// menu bar item and the panel (light + dark) to PNGs, then quits.
    private func renderSnapshots(to dir: URL) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            let actions = PanelActions(openSettings: {}, openDiagnostics: {}, openFanControl: {},
                                       openDiskAnalysis: {}, openOptimize: {}, openUninstall: {}, openStartup: {}, openHistory: {}, quit: {})
            // The panel reads its tab from defaults; put the user's choice back afterwards, since a
            // snapshot instance must never change the real settings.
            let savedTab = UserDefaults.standard.object(forKey: "panel.module")
            for scheme in [ColorScheme.light, .dark] {
                let name = scheme == .light ? "light" : "dark"
                let bg = scheme == .light ? Color(white: 0.93) : Color(white: 0.15)
                render(StatusItemView(store: store, health: app.healthModel).background(bg).environment(\.colorScheme, scheme), "menubar-\(name)", dir)
                for tab in MonitorPanel.Tab.allCases {
                    UserDefaults.standard.set(tab.rawValue, forKey: "panel.module")
                    render(MonitorPanel(store: store, actions: actions, scrollable: false).environment(\.colorScheme, scheme),
                           "panel-\(tab.rawValue)-\(name)", dir)
                }
            }
            render(MonitorSettingsView(settings: settings, available: store.availableModules).background(Color(white: 0.93)), "settings", dir)
            if let savedTab { UserDefaults.standard.set(savedTab, forKey: "panel.module") }
            else { UserDefaults.standard.removeObject(forKey: "panel.module") }
            NSApp.terminate(nil)
        }
    }

    /// Debug aid: `MacHelper --snapshot-window DIR [--dark]` shows every page of the main window and saves
    /// each as a PNG (drawn from the window's own views, so no screen-recording permission is needed).
    private func renderWindowSnapshots(to dir: URL) {
        Task { @MainActor in
            if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            try? await Task.sleep(for: .seconds(6))
            for section in AppSection.allCases {
                app.show(section)
                try? await Task.sleep(for: .seconds(section == .overview || section == .monitor ? 3 : 2))
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }),
                      let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "window-\(section.rawValue).png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// Build aid: `MacHelper --export-mascot-icon DIR` writes px.mascot@1x/2x/3x.png, the idle slime
    /// on a 32×32 pixel grid, so the empty-state art matches the animated mascot exactly.
    private func exportMascotIcon(to dir: URL) {
        var cells: [(Int, Int, CGColor)] = []
        SlimeRenderer.paint(SlimePose.make(mood: .init(), frame: 12, tappedAt: nil)) { x, y, color in   // eyes open (frames 0–1 blink)
            cells.append((x, y, NSColor(color).cgColor))
        }
        guard let minX = cells.map(\.0).min(), let maxX = cells.map(\.0).max(),
              let minY = cells.map(\.1).min(), let maxY = cells.map(\.1).max() else { return }
        let grid = 32
        // Centered, a little below the middle so it sits like the other pixel art.
        let offX = (grid - (maxX - minX + 1)) / 2 - minX
        let offY = (grid - (maxY - minY + 1) + 1) / 2 + 1 - minY
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for scale in 1...3 {
            let cell = 2 * scale, side = grid * cell
            guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            for (x, y, color) in cells {
                ctx.setFillColor(color)
                // CoreGraphics' origin is bottom-left; the renderer's is top-left.
                ctx.fill(CGRect(x: (x + offX) * cell, y: side - (y + offY + 1) * cell, width: cell, height: cell))
            }
            guard let image = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "px.mascot@\(scale)x.png"))
        }
    }

    /// Debug aid: `MacHelper --snapshot-mascot DIR` renders every mood at several frames (rows: moods,
    /// columns: frames), plus a tap reaction row, into mascot.png.
    private func renderMascotSheet(to dir: URL) {
        let moods: [SlimeMascot.Mood] = [.init(), .init(level: .attention, holdsSign: true), .init(level: .critical, holdsSign: true),
                                         .init(level: .critical), .init(level: .good, holdsSign: false, sleepy: true)]
        let frames = [0, 5, 12, 30, 35, 58, 62, 66, 70]
        let sheet = VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(moods.enumerated()), id: \.offset) { _, mood in
                HStack(spacing: 6) {
                    ForEach(frames, id: \.self) { f in
                        Canvas { ctx, _ in SlimeRenderer.draw(SlimePose.make(mood: mood, frame: f, tappedAt: nil), in: ctx, cell: 4) }
                            .frame(width: 160, height: 96)
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<9, id: \.self) { f in
                    Canvas { ctx, _ in SlimeRenderer.draw(SlimePose.make(mood: .init(), frame: f, tappedAt: 0), in: ctx, cell: 4) }
                        .frame(width: 160, height: 96)
                }
            }
        }
        .padding(10)
        .background(Color(white: 0.16))
        render(sheet, "mascot", dir)
        NSApp.terminate(nil)
    }

    /// Debug aid: `MacHelper --snapshot-disk PATH DIR` scans PATH and renders both charts.
    private func renderDiskSnapshots(scan path: String, to dir: URL) {
        Task { @MainActor in
            let root = await Task.detached { try? DiskScanner().scan(URL(fileURLWithPath: path)).root }.value
            guard let root else { NSApp.terminate(nil); return }
            let insights = await Task.detached { SpaceInsights.find(in: root) }.value
            diskModel.setInsights(insights, root: root)
            if let flagged = insights.bloatedFolders.first.flatMap({ root.descendant(atPath: $0.path) })
                ?? insights.unusedFiles.first.flatMap({ root.descendant(atPath: $0.path) }),
               let info = diskModel.hoverInfo(for: flagged) {
                render(ChartTooltip(info: info, share: Double(flagged.size) / Double(max(root.size, 1))).padding(20)
                    .background(Color(white: 0.12)).environment(\.colorScheme, .dark), "tooltip-dark", dir)
            }
            let size = CGSize(width: 640, height: 640)
            let sunburst = SunburstLayout(center: root, maxDepth: 4)
            let cells = TreemapLayout(center: root, bounds: CGRect(origin: .zero, size: size), minArea: size.width * size.height * 0.004).cells
            for scheme in [ColorScheme.light, .dark] {
                let name = scheme == .light ? "light" : "dark"
                let bg = scheme == .light ? Color.white : Color(white: 0.12)
                render(SunburstChart(model: diskModel, focus: root, precomputed: sunburst)
                    .frame(width: size.width, height: size.height).background(bg).environment(\.colorScheme, scheme),
                       "sunburst-\(name)", dir)
                render(TreemapChart(model: diskModel, focus: root, precomputed: cells)
                    .frame(width: size.width, height: size.height).background(bg).environment(\.colorScheme, scheme),
                       "treemap-\(name)", dir)
            }
            NSApp.terminate(nil)
        }
    }

    private func render<V: View>(_ view: V, _ name: String, _ dir: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: dir.appending(path: "\(name).png"))
    }

    /// Keeps heartbeat-guarded fan policies (fixed speed) alive while the app runs.
    private func startHeartbeat() {
        heartbeatTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if HelperClient.shared.status == .enabled {
                    try? await HelperClient.shared.heartbeat()
                }
                try? await Task.sleep(for: .seconds(HelperTiming.heartbeatInterval))
            }
        }
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 40)
        guard let button = statusItem.button else { return }

        let view = StatusItemView(store: store, health: app.healthModel) { [weak self] width in
            // Resize after the current SwiftUI update pass, not during it.
            DispatchQueue.main.async { self?.resizeStatusItem(to: width) }
        }
        let hosting = ClickThroughHostingView(rootView: view)
        // The item's width comes from the view's own measurement callback above; without size
        // constraints AppKit doesn't re-measure the SwiftUI tree (minSize) on every redraw of the
        // menu bar copies, which was most of the remaining CPU time.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: button.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        // Something else (the system re-laying out a crowded menu bar, or a menu bar manager moving
        // items) can leave the button narrower than the length we asked for, clipping the content
        // on both sides. Watch the button and ask for the full width again when that happens.
        button.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(statusButtonFrameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: button)
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.setAccessibilityLabel(String(localized: "MacHelper System Monitor"))
    }

    private func setUpPopover() {
        popover.behavior = .transient
        popover.animates = false
        let actions = PanelActions(
            openSettings: { [weak self] in self?.openSettings() },
            openDiagnostics: { [weak self] in self?.openDiagnostics() },
            openFanControl: { [weak self] in self?.openFanControl() },
            openDiskAnalysis: { [weak self] in self?.openDiskAnalysis() },
            openOptimize: { [weak self] in self?.openOptimize() },
            openUninstall: { [weak self] in self?.openUninstall() },
            openStartup: { [weak self] in self?.openStartup() },
            openHistory: { [weak self] in self?.openHistory() },
            openMain: { [weak self] in self?.openMain() },
            quit: { NSApp.terminate(nil) }
        )
        panelActions = actions
        popover.delegate = self
    }

    private var panelActions: PanelActions?

    /// The panel exists only while shown: a hidden hosting view would keep observing the store
    /// and re-rendering on every sample.
    private func makePanel() -> NSViewController? {
        guard let panelActions else { return nil }
        return NSHostingController(rootView: MonitorPanel(store: store, actions: panelActions))
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    /// The item only grows while values change ("9%" → "19%" → "9%" would otherwise shift every icon to
    /// its left); it is re-measured from scratch when the menu bar configuration changes.
    private var statusWidth: CGFloat = 0
    private var statusConfig: MonitorConfiguration?

    private var lastReassert = Date.distantPast

    @objc private func statusButtonFrameChanged(_ notification: Notification) {
        DispatchQueue.main.async { self.reassertStatusWidth() }
    }

    /// Re-applies the measured width when the button ended up narrower (at most once a second,
    /// so a manager that keeps shrinking it can't start a resize loop).
    private func reassertStatusWidth() {
        guard let button = statusItem?.button, statusWidth > 0,
              button.frame.width + 0.5 < statusWidth,
              Date().timeIntervalSince(lastReassert) > 1 else { return }
        lastReassert = Date()
        statusItem.length = statusWidth + 1
        statusItem.length = statusWidth
    }

    private func resizeStatusItem(to width: CGFloat) {
        let w = max(ceil(width), 22)
        if statusConfig != settings.configuration {
            statusConfig = settings.configuration
            statusWidth = w
        } else {
            statusWidth = max(statusWidth, w)
        }
        if statusItem.length != statusWidth { statusItem.length = statusWidth }
        reassertStatusWidth()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate()
            if popover.contentViewController == nil { popover.contentViewController = makePanel() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: Navigation (the panel's buttons open the main window on a page)

    private func open(_ section: AppSection) {
        popover.performClose(nil)
        app.show(section)
    }

    func openSettings() {
        popover.performClose(nil)
        app.showSettings()
    }
    func openFanControl() { open(.fans) }
    func openDiskAnalysis() { open(.disk) }
    func openOptimize() { open(.optimize) }
    func openUninstall() { open(.uninstall) }
    func openStartup() { open(.startup) }
    func openHistory() { open(.monitor) }
    func openDiagnostics() { openSettings() }
    func openMain() { open(.overview) }
}

/// Lets clicks fall through to the status item button underneath.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
