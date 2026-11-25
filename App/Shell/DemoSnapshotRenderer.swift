#if DEBUG
import AppKit
import DiskScan
import SwiftUI

/// Debug aid: `MacHelper --snapshot-demo DIR -AppleLanguages '(en)'` (or `make screenshots`)
/// writes the README screenshots — overview.png, monitor.png, health.png, disk.png and
/// menubar.png — from the synthetic Mac in `DemoData`, then quits.
///
/// Nothing on them comes from the Mac it runs on: there is no sampler, process list, saved scan,
/// history database, Helper call, fan driver or update check in this run (`DemoData.snapshot`
/// switches each of them off), and the app's settings are read but never written. The pages are
/// the production views, drawn into off-screen windows at 2× and the menu bar at 4×.
@MainActor
enum DemoSnapshotRenderer {
    /// The main window's detail column, title bar included (points). Monitor and Health sit side
    /// by side in the README, so they share one taller size that fits all eight monitor charts
    /// and the free space chart.
    private static let pages: [(section: AppSection, file: String, size: CGSize)] = [
        (.overview, "overview", CGSize(width: 860, height: 800)),
        (.monitor, "monitor", CGSize(width: 860, height: 960)),
        (.health, "health", CGSize(width: 860, height: 960)),
        (.disk, "disk", CGSize(width: 860, height: 700)),
    ]

    /// The same pages at another size, for checking a layout at one window width:
    /// `--snapshot-demo DIR --snapshot-size 520x428`. Without the argument the README sizes above
    /// are used, so `make screenshots` writes exactly what it always did.
    private static var requestedSize: CGSize? {
        let arguments = CommandLine.arguments
        guard let i = arguments.firstIndex(of: "--snapshot-size"), i + 1 < arguments.count else { return nil }
        let parts = arguments[i + 1].lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 320, parts[1] >= 240 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    static func run(app: AppModel, to dir: URL) {
        Task { @MainActor in
            let pages = requestedSize.map { size in Self.pages.map { (section: $0.section, file: $0.file, size: size) } } ?? Self.pages
            pinDisplayChoices()
            NSApp.appearance = NSAppearance(named: .darkAqua)
            for window in NSApp.windows { window.orderOut(nil) }
            if Bundle.main.preferredLocalizations.first != "en" {
                warn("the app is not running in English; pass -AppleLanguages '(en)'.")
            }
            app.hasVisibleMainWindow = true
            app.healthModel.showDemo(report: DemoData.healthReport(), diskPoints: DemoData.diskPoints(),
                                     security: DemoData.security)
            app.diskModel.showDemo(root: DemoData.homeTree().makeDemoLiveTree(rootPath: DemoData.homePath),
                                   volume: DemoData.volume, files: DemoData.scanFiles, elapsed: DemoData.scanElapsed)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for page in pages {
                    try await capture(page.section, size: page.size, app: app, to: dir.appending(path: "\(page.file).png"))
                }
                try renderMenuBar(app: app, to: dir.appending(path: "menubar.png"))
            } catch {
                warn("\(error)")
            }
            NSApp.terminate(nil)
        }
    }

    /// Choices the pages keep in `@AppStorage` (Monitor range, chart fill, the score in the menu
    /// bar) are pinned for this process through the argument domain, so the user's own choices
    /// neither show up nor change.
    private static func pinDisplayChoices() {
        let defaults = UserDefaults.standard
        var pinned = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        pinned["monitor.range"] = MonitorView.Range.live.rawValue
        pinned["monitor.fill"] = true
        pinned[HealthScoreMenuBar.key] = false
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(pinned, forName: UserDefaults.argumentDomain)
    }

    @ViewBuilder private static func view(for section: AppSection, app: AppModel) -> some View {
        switch section {
        case .overview: OverviewView(app: app)
        case .monitor: MonitorView(store: app.store, app: app)
        case .health: HealthView(app: app, model: app.healthModel)
        case .disk: DiskAnalysisView(model: app.diskModel)
        default: EmptyView()
        }
    }

    /// Hosts the page in a borderless window far off screen, lets it settle, and draws it into a
    /// 2× bitmap whatever the screen's scale.
    private static func capture(_ section: AppSection, size pageSize: CGSize, app: AppModel, to url: URL) async throws {
        let host = NSHostingView(rootView: DemoPageFrame(title: section.title, size: pageSize) { view(for: section, app: app) }
            .environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: pageSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Charts and lists lay out over a few runloop turns; the monitor draws eight charts.
        try await Task.sleep(for: .seconds(section == .monitor ? 3 : 2))
        host.layoutSubtreeIfNeeded()

        let scale = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pageSize.width) * scale,
                                         pixelsHigh: Int(pageSize.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw RenderError.bitmap(url.lastPathComponent) }
        rep.size = pageSize
        host.cacheDisplay(in: host.bounds, to: rep)
        try write(rep, to: url)
    }

    /// The menu bar item on a dark menu bar strip, at 4× so the README can show it enlarged.
    private static func renderMenuBar(app: AppModel, to url: URL) throws {
        let strip = StatusItemView(store: app.store, health: app.healthModel)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(red: 0.13, green: 0.14, blue: 0.17))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = 4
        guard let image = renderer.cgImage else { throw RenderError.bitmap(url.lastPathComponent) }
        try write(NSBitmapImageRep(cgImage: image), to: url)
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        guard let png = rep.representation(using: .png, properties: [:]) else { throw RenderError.bitmap(url.lastPathComponent) }
        try png.write(to: url)
        print("wrote \(url.path)")
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("snapshot-demo: \(message)\n".utf8))
    }

    private enum RenderError: Error, CustomStringConvertible {
        case bitmap(String)
        var description: String {
            switch self {
            case .bitmap(let name): "could not draw \(name)"
            }
        }
    }
}

/// The detail column as the main window shows it: the page title in the title bar, a hairline,
/// then the page.
private struct DemoPageFrame<Content: View>: View {
    let title: LocalizedStringKey
    let size: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 40)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The page picks its narrow layout from the width the split view gives it;
                // this frame stands in for that width when a page is drawn on its own.
                .pageContentWidth()
        }
        .frame(width: size.width, height: size.height)
        .background(Palette.base)
    }
}
#endif
