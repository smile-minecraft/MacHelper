import AppKit
import Darwin
import SwiftUI

/// Whether macOS lets MacHelper read protected folders (Mail, Safari, other apps' containers).
/// There is no API for this; opening a file only Full Disk Access can read is the usual test.
enum FullDiskAccess {
    /// Files that exist on every Mac and only open with Full Disk Access.
    private static let probes = ["Library/Application Support/com.apple.TCC/TCC.db", "Library/Safari/Bookmarks.plist",
                                 "Library/Containers/com.apple.stocks"]

    /// True when granted, or when nothing could be tested (never nag on a guess).
    static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var denied = false
        for p in probes {
            let fd = open(home + "/" + p, O_RDONLY | O_NOFOLLOW)
            if fd >= 0 { close(fd); return true }
            if errno == EPERM || errno == EACCES { denied = true }
        }
        return !denied
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The onboarding sheet is offered once, on the first launch without access; never in snapshot runs.
    static let onboardingKey = "onboarding.fullDiskAccess.shown"
    static var shouldOfferOnboarding: Bool {
        !CommandLine.arguments.contains { $0.hasPrefix("--snapshot") } && !UserDefaults.standard.bool(forKey: onboardingKey) && !isGranted
    }
}

/// First-launch explanation of Full Disk Access, with a live status line that turns green once granted.
struct FullDiskAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var granted = FullDiskAccess.isGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                SlimeMascot(mood: .init(level: granted ? .good : .attention), cell: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Let MacHelper see the whole disk").font(.mhTitle2).foregroundStyle(Palette.text)
                    Text("macOS hides some folders from apps until you allow it. Without Full Disk Access, MacHelper can’t measure or clean Mail downloads, some app caches and other protected places, and disk analysis misses them.")
                        .font(.mhCallout).foregroundStyle(Palette.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click Open System Settings.")
                Text("2. Turn on MacHelper in the Full Disk Access list.")
                Text("3. Come back here. MacHelper checks again by itself.")
            }
            .font(.mhCallout).foregroundStyle(Palette.text)
            Label(granted ? "Full Disk Access is on" : "Full Disk Access is off",
                  systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.mhCallout.weight(.medium))
                .foregroundStyle(granted ? Theme.mint : Palette.textMuted)
            HStack {
                Spacer()
                if granted {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { dismiss() }
                    Button("Open System Settings") { FullDiskAccess.openSettings() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Palette.base)
        .task {
            // Re-check while the sheet is open; the switch is flipped in another app.
            while !Task.isCancelled && !granted {
                try? await Task.sleep(for: .seconds(1.5))
                granted = FullDiskAccess.isGranted
            }
        }
        .onDisappear { UserDefaults.standard.set(true, forKey: FullDiskAccess.onboardingKey) }
    }
}
