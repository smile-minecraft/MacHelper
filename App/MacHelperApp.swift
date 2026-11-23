import SwiftUI

@main
struct MacHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
        }
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
            // Interface size: ⌘+ / ⌘- / ⌘0 change the text size setting (80–150 %).
            CommandGroup(after: .toolbar) {
                Button("Make Interface Bigger") { ThemeStore.shared.zoom(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Make Interface Bigger") { ThemeStore.shared.zoom(by: 1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Make Interface Smaller") { ThemeStore.shared.zoom(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { ThemeStore.shared.settings.textScale = 1 }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
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
