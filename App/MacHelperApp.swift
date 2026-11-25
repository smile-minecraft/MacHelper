import AppKit
import SwiftUI

@main
struct MacHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.dropFirst() == [AccessibilityAuthority.probeArgument] {
            AccessibilityAuthority.runProbeAndExit()
        }
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
        }
        ZoomInAlternateKey.install()
    }

    /// The original pages keep ⌘1–⌘9. Later pages use dedicated single-character keys so they
    /// never trap `Character("10")` or collide with ⌘0 (Actual Size).
    private static func sectionShortcut(_ index: Int, _ section: AppSection) -> KeyEquivalent {
        if index < 9 { return KeyEquivalent(Character(String(index + 1))) }
        switch section {
        case .tweaks: return "t"
        case .cable: return "u"
        default: return "0"
        }
    }

    /// ⇧⌘= zooms in as well as ⌘=, but the View menu shows one item only: the menu item's key
    /// equivalent can't match both, and a second item would read as a duplicate. A key monitor is
    /// used instead, because it survives the menu rebuilds SwiftUI does on state changes.
    private enum ZoomInAlternateKey {
        nonisolated(unsafe) private static var monitor: Any?

        static func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                // ⇧⌘= on most layouts, ⌘+ where + has its own key.
                guard flags == .command || flags == [.command, .shift],
                      event.charactersIgnoringModifiers == "+" else { return event }
                ThemeStore.shared.zoom(by: 1)
                return nil
            }
        }
    }

    var body: some Scene {
        Window("MacHelper", id: "main") {
            // The synthetic screenshot run draws its pages in its own off-screen windows; the
            // main window (sidebar, Helper status, first-launch sheets) never appears.
            if DemoData.snapshot {
                Color.clear.frame(width: 1, height: 1)
            } else {
                MainView(app: AppModel.shared)
            }
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(before: .sidebar) {
                // Keep the original number for every page; only omit the invisible ones.
                ForEach(Array(AppSection.allCases.enumerated()).filter { $0.element.isVisible }, id: \.element) { i, s in
                    Button(s.title) { AppModel.shared.show(s) }
                        .keyboardShortcut(Self.sectionShortcut(i, s), modifiers: .command)
                }
                Divider()
            }
            // Interface size: ⌘= / ⌘- / ⌘0 change the text size setting (80–150 %).
            CommandGroup(after: .toolbar) {
                Button("Make Interface Bigger") { ThemeStore.shared.zoom(by: 1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Make Interface Smaller") { ThemeStore.shared.zoom(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { ThemeStore.shared.settings.textScale = 1 }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            // The page's own commands, between View and Window.
            PageCommandsMenu()
            // Help → Welcome Guide replays the first-launch guide at any time.
            CommandGroup(after: .help) {
                Button(onboardingText("Welcome Guide…")) { OnboardingCenter.shared.present() }
            }
        }

        Settings {
            SettingsView(app: AppModel.shared)
        }
    }
}
