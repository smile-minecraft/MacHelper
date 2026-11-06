import SwiftUI

@main
struct MacHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
        }
    }

    var body: some Scene {
        Window("MacHelper", id: "main") {
            MainView(app: AppModel.shared)
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(before: .sidebar) {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.title) { AppModel.shared.show(s) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
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
        }

        Settings {
            SettingsView(app: AppModel.shared)
        }
    }
}
