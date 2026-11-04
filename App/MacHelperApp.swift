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
        }

        Settings {
            SettingsView(app: AppModel.shared)
        }
    }
}
