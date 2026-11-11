import AppKit
import CleanEngine
import Foundation
import Observation

/// Homebrew app updates: check → choose → update one by one → report. Nothing changes before `update`.
@MainActor
@Observable
final class UpdatesModel {
    enum Phase: Equatable { case idle, checking, ready, updating }

    private(set) var phase: Phase = .idle
    private(set) var casks: [OutdatedCask] = []
    private(set) var brewMissing = HomebrewUpdates.brew == nil
    private(set) var failure: String?
    private(set) var lastChecked: Date?
    var selected: Set<String> = []
    /// Outcome of the last update of each cask, kept after the list is checked again.
    private(set) var results: [String: HomebrewUpdates.UpgradeOutcome] = [:]
    /// The cask being updated right now, and how far the batch is.
    private(set) var current: String?
    private(set) var progress: (done: Int, total: Int)?

    /// The App bundle this model belongs to and the cask that installs it, never offered as an
    /// update: Homebrew keeps the version it installed while the app updates itself through
    /// Sparkle, so the row would read like a downgrade.
    private let ownAppBundleName = Bundle.main.bundleURL.lastPathComponent
    private let ownCaskToken = HomebrewUpdates.appCaskToken

    @ObservationIgnored static let greedyKey = "updates.includeSelfUpdating"
    var includeSelfUpdating = UserDefaults.standard.bool(forKey: UpdatesModel.greedyKey) {
        didSet {
            UserDefaults.standard.set(includeSelfUpdating, forKey: Self.greedyKey)
            Task { await check() }
        }
    }

    /// Casks that can be updated from here (not pinned, no administrator password needed).
    func canUpdate(_ c: OutdatedCask) -> Bool { !c.pinned && !c.needsAdmin }

    var selectedCasks: [OutdatedCask] { casks.filter { selected.contains($0.token) && canUpdate($0) } }

    func check(refresh: Bool = false) async {
        guard phase != .checking, phase != .updating else { return }
        brewMissing = HomebrewUpdates.brew == nil
        guard !brewMissing else { phase = .idle; return }
        phase = .checking
        let greedy = includeSelfUpdating
        let ownBundles: Set<String> = [ownAppBundleName], ownTokens: Set<String> = [ownCaskToken]
        let result = await Task.detached(priority: .userInitiated) {
            HomebrewUpdates.outdated(greedy: greedy, refresh: refresh,
                                     excludingAppBundleNames: ownBundles, excludingTokens: ownTokens)
        }.value
        switch result {
        case .success(let list):
            let previous = Set(casks.map(\.token))
            casks = list
            // New entries start selected; the user's choices for the others are kept.
            selected = Set(list.filter { canUpdate($0) && (selected.contains($0.token) || !previous.contains($0.token)) }.map(\.token))
            failure = nil
            lastChecked = Date()
        case .failure(.notInstalled):
            brewMissing = true
        case .failure(.failed(let message)):
            failure = message
        }
        phase = .ready
    }

    /// Running copies of the cask's apps (they are quit before updating and reopened after).
    func runningApps(_ c: OutdatedCask) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard let name = app.bundleURL?.lastPathComponent else { return false }
            return c.appNames.contains(name) && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    func appIcon(_ c: OutdatedCask) -> NSImage? {
        for name in c.appNames {
            for dir in ["/Applications", NSHomeDirectory() + "/Applications"] where FileManager.default.fileExists(atPath: dir + "/" + name) {
                return NSWorkspace.shared.icon(forFile: dir + "/" + name)
            }
        }
        return nil
    }

    func update() async {
        let batch = selectedCasks
        guard !batch.isEmpty, phase == .ready else { return }
        phase = .updating
        for (i, cask) in batch.enumerated() {
            current = cask.token
            progress = (i, batch.count)
            let running = runningApps(cask)
            let reopen = running.compactMap(\.bundleURL)
            if !running.isEmpty, !(await quit(running)) {
                results[cask.token] = .init(token: cask.token, ok: false, neededPassword: false,
                                            output: String(localized: "\(cask.name) didn’t quit. Quit it yourself and try again."))
                continue
            }
            let token = cask.token
            let outcome = await Task.detached(priority: .userInitiated) { HomebrewUpdates.upgrade(token) }.value
            results[cask.token] = outcome
            if outcome.ok { selected.remove(cask.token) }
            // Reopen what was running, updated or not (a failed upgrade puts the old version back).
            for url in reopen where FileManager.default.fileExists(atPath: url.path) {
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        }
        current = nil
        progress = nil
        phase = .ready
        await check()
    }

    /// Asks the apps to quit (they may show a save prompt) and waits up to 20 seconds.
    private func quit(_ apps: [NSRunningApplication]) async -> Bool {
        for app in apps { app.terminate() }
        for _ in 0..<40 {
            if apps.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return apps.allSatisfy(\.isTerminated)
    }

    func copyCommand(_ c: OutdatedCask) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.terminalCommand, forType: .string)
    }

    func openTerminal() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
