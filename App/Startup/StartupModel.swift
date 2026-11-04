import AppKit
import CleanEngine
import Foundation
import Observation

@MainActor
@Observable
final class StartupModel {
    private(set) var items: [StartupItem] = []
    private(set) var loading = false
    var search = ""
    var onlyBroken = false
    private(set) var message: String?

    var visible: [StartupItem] {
        items.filter { item in
            (!onlyBroken || item.programMissing)
                && (search.isEmpty || item.label.localizedCaseInsensitiveContains(search)
                    || (item.ownerName?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    func load() async {
        guard !loading else { return }
        loading = true
        items = await Task.detached(priority: .userInitiated) { StartupItems.list() }.value
        loading = false
    }

    func setEnabled(_ item: StartupItem, _ enabled: Bool) async {
        message = nil
        do {
            try await Task.detached { try StartupItems.setEnabled(item, enabled) }.value
        } catch {
            message = "\(error)"
        }
        await reload()
    }

    func remove(_ item: StartupItem) async {
        message = nil
        do {
            let report = try await Task.detached { try StartupItems.remove(item) }.value
            if let f = report.failures.first { message = f.message }
        } catch {
            message = "\(error)"
        }
        await reload()
    }

    private func reload() async {
        loading = false
        await load()
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func icon(for item: StartupItem) -> NSImage {
        if let p = item.ownerPath { return NSWorkspace.shared.icon(forFile: p) }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }

    func openLoginItems() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}
