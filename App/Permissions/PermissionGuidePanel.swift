import AppKit
import Permissions
import SwiftUI

/// A small always-on-top window beside System Settings that walks through the switch to flip.
///
/// It never takes focus from System Settings (`.nonactivatingPanel`), stays visible while MacHelper
/// is in the background, and closes by itself: shortly after the grant shows up, when the user comes
/// back to MacHelper, or with its close button. Only one guide is on screen at a time.
@MainActor
final class PermissionGuideController: NSObject, NSWindowDelegate {
    static let shared = PermissionGuideController()

    private(set) var current: PermissionID?
    private var panel: NSPanel?
    private var activationObserver: NSObjectProtocol?
    private var placementTask: Task<Void, Never>?

    static let width: CGFloat = 340

    override private init() { super.init() }

    func show(_ id: PermissionID) {
        close()
        current = id
        let host = NSHostingView(rootView: PermissionGuideView(id: id) { [weak self] in self?.close() })
        let size = host.fittingSize
        let panel = GuidePanel(contentRect: CGRect(origin: .zero, size: CGSize(width: Self.width, height: max(size.height, 200))),
                               styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        panel.title = PermissionInfo.info(for: id).title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.contentView = host
        panel.delegate = self
        panel.setContentSize(CGSize(width: Self.width, height: size.height))
        place(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        // Coming back to MacHelper means the user is done with System Settings.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        // System Settings takes a moment to open; move beside its window once it is there.
        placementTask = Task { @MainActor [weak self] in
            for delay in [0.6, 1.4] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, let panel = self.panel else { return }
                self.place(panel)
            }
        }
    }

    func close() {
        placementTask?.cancel()
        placementTask = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        let closing = panel
        panel = nil
        current = nil
        closing?.delegate = nil
        closing?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSPanel) === panel else { return }
        close()
    }

    /// Beside the System Settings window when one is on screen, otherwise at the right edge of the
    /// screen MacHelper is on.
    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let gap: CGFloat = 12
        var origin = CGPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 80)
        if let settings = Self.systemSettingsFrame() {
            let top = min(settings.maxY, visible.maxY) - size.height
            if settings.maxX + gap + size.width <= visible.maxX {
                origin = CGPoint(x: settings.maxX + gap, y: top)
            } else if settings.minX - gap - size.width >= visible.minX {
                origin = CGPoint(x: settings.minX - gap - size.width, y: top)
            }
        }
        origin.y = max(origin.y, visible.minY + 20)
        panel.setFrameOrigin(origin)
    }

    /// The System Settings window in AppKit coordinates. Window bounds and owners are readable
    /// without Screen Recording; titles are not needed.
    private static func systemSettingsFrame() -> CGRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                  w > 200, h > 200 else { continue }
            return CGRect(x: x, y: primaryHeight - y - h, width: w, height: h)
        }
        return nil
    }
}

/// A panel that can take clicks without becoming the key window.
private final class GuidePanel: NSPanel {
    override var canBecomeMain: Bool { false }
}

// MARK: - Content

/// Numbered steps for one permission, a live status line, and the MacHelper icon to drag where
/// macOS lists apps by hand.
struct PermissionGuideView: View {
    let id: PermissionID
    var close: () -> Void
    @Bindable private var center = PermissionCenter.shared
    @State private var succeeded = false

    private var item: PermissionCenter.Item? { center.item(id) }
    private var guide: PermissionGuide { PermissionGuide.for(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: succeeded ? "checkmark.seal.fill" : "hand.point.up.left.fill")
                    .font(.mhTitle3)
                    .foregroundStyle(succeeded ? Theme.mint : Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(guide.title).font(.mhCallout.weight(.semibold)).foregroundStyle(Palette.text)
                    Text(PermissionInfo.info(for: id).title).font(.mhCaption).foregroundStyle(Palette.textMuted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.mhTitle3)
                        .foregroundStyle(Palette.textFaint)
                }
                .buttonStyle(.borderless)
                .help("Close")
                .accessibilityLabel("Close guide")
            }

            if succeeded {
                Label(guide.success, systemImage: "checkmark.circle.fill")
                    .font(.mhCallout.weight(.medium))
                    .foregroundStyle(Theme.mint)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(Motion.stateSwap)
            } else {
                PermissionStepList(steps: guide.steps)
                if guide.offersAppIcon { DraggableAppIcon() }
                statusLine
            }
        }
        .padding(16)
        .padding(.top, 10)
        .frame(width: PermissionGuideController.width, alignment: .leading)
        .background(Palette.base)
        .animatesStateChanges(succeeded)
        .task { await PermissionCenter.shared.watch() }
        .task(id: id) {
            if id == .helper { await PermissionFlow.shared.followHelperApproval() }
        }
        .onChange(of: item?.state) { _, state in
            guard state == .granted, !succeeded else { return }
            succeeded = true
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: guide.success, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                close()
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let item {
            HStack(spacing: 8) {
                PermissionStatusBadge(item: item)
                Spacer(minLength: 4)
                if item.requiresRelaunch {
                    Button(PermissionPrimaryAction.relaunch.title) { AppRelauncher.relaunch() }
                        .controlSize(.small)
                } else {
                    Text("Closes by itself when it’s done.")
                        .font(.mhCaption)
                        .foregroundStyle(Palette.textFaint)
                }
            }
        }
    }
}

/// 1, 2, 3 in circles, each with one sentence.
struct PermissionStepList: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: "\(index + 1)")
                        .font(.mhCaption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 20, height: 20)
                        .background(Theme.accent.opacity(0.14), in: SurfaceShape.capsule)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        .accessibilityHidden(true)
                    Text(step)
                        .font(.mhCallout)
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Step \(index + 1): \(step)"))
            }
        }
    }
}

/// MacHelper's icon as a file to drop into a System Settings app list.
private struct DraggableAppIcon: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .onDrag {
                    let provider = NSItemProvider(object: Bundle.main.bundleURL as NSURL)
                    provider.suggestedName = Bundle.main.bundleURL.lastPathComponent
                    return provider
                }
                .help("Drag MacHelper into the list")
                .accessibilityLabel("MacHelper app icon")
                .accessibilityHint("Drag it into the Full Disk Access list in System Settings.")
            VStack(alignment: .leading, spacing: 2) {
                Text("Drag this icon into the list")
                    .font(.mhCallout.weight(.semibold))
                    .foregroundStyle(Palette.text)
                Text("Or click + below the list and choose MacHelper in Applications.")
                    .font(.mhCaption)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.inset, in: SurfaceShape(cornerRadius: Theme.cardRadius))
        .overlay {
            SurfaceShape(cornerRadius: Theme.cardRadius)
                .strokeBorder(Palette.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}

// MARK: - Copy

/// The steps shown in the floating guide for one permission.
struct PermissionGuide {
    let title: String
    let steps: [String]
    let success: String
    var offersAppIcon = false

    static func `for`(_ id: PermissionID) -> PermissionGuide {
        switch id {
        case .helper:
            PermissionGuide(
                title: String(localized: "Allow the Helper"),
                steps: [
                    String(localized: "System Settings opens at General → Login Items & Extensions."),
                    String(localized: "Under “Allow in the Background”, turn on the switch next to MacHelper."),
                    String(localized: "Enter your password or use Touch ID when macOS asks."),
                ],
                success: String(localized: "The Helper is running."))
        case .backgroundRecording, .autoCleanSchedule:
            PermissionGuide(
                title: String(localized: "Allow the background task"),
                steps: [
                    String(localized: "System Settings opens at General → Login Items & Extensions."),
                    String(localized: "Under “Allow in the Background”, turn on the switch next to MacHelper."),
                    String(localized: "Enter your password or use Touch ID when macOS asks."),
                ],
                success: String(localized: "Allowed. It now runs while MacHelper is closed."))
        case .fullDiskAccess:
            PermissionGuide(
                title: String(localized: "Add MacHelper to Full Disk Access"),
                steps: [
                    String(localized: "System Settings opens at Privacy & Security → Full Disk Access."),
                    String(localized: "If MacHelper isn’t in the list, drag the icon below into it."),
                    String(localized: "Turn on the switch next to MacHelper and confirm with your password."),
                    String(localized: "If macOS offers to quit and reopen MacHelper, you can choose Later."),
                ],
                success: String(localized: "Full Disk Access is on."),
                offersAppIcon: true)
        case .accessibility:
            PermissionGuide(
                title: String(localized: "Turn on Accessibility"),
                steps: [
                    String(localized: "System Settings opens at Privacy & Security → Accessibility."),
                    String(localized: "Turn on the switch next to MacHelper and confirm with your password."),
                    String(localized: "Relaunch MacHelper when this guide asks; macOS hands the grant only to a new copy."),
                ],
                success: String(localized: "Accessibility is on."))
        case .finderExtension:
            PermissionGuide(
                title: String(localized: "Turn on the Finder extension"),
                steps: [
                    String(localized: "System Settings opens at General → Login Items & Extensions."),
                    String(localized: "Scroll to Extensions and click ⓘ next to Finder."),
                    String(localized: "Turn on MacHelper, then click Done."),
                ],
                success: String(localized: "The Finder extension is on."))
        case .finderAutomation, .notifications, .openAtLogin:
            PermissionGuide(
                title: PermissionInfo.info(for: id).title,
                steps: [String(localized: "Turn on the switch next to MacHelper.")],
                success: String(localized: "Done."))
        }
    }
}
