import Foundation
import Observation
import Tweaks

/// Observable mirror of tweaks.json for the Tweaks page. Writes go through TweakStore, and changes
/// made by the CLI arrive as distributed notifications (with a poll as a fallback).
@MainActor
@Observable
final class TweakSettingsModel {
    private(set) var settings: TweakSettings
    private(set) var status: TweakRuntimeStatus?
    @ObservationIgnored private let store = TweakStore()
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var poll: Timer?

    init() {
        settings = store.load()
        status = TweakRuntimeStatus.load(from: store.statusURL)
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(TweakStore.changeNotification), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        poll?.invalidate()
    }

    func reload() {
        let fresh = store.load()
        if fresh != settings { settings = fresh }
        let freshStatus = TweakRuntimeStatus.load(from: store.statusURL)
        if freshStatus != status { status = freshStatus }
    }

    func setEnabled(_ id: TweakID, _ enabled: Bool) {
        var next = settings
        guard next.setEnabled(id, enabled) else { return }
        save(next)
    }

    func setValue(_ option: String, for id: TweakID, to value: TweakValue) {
        var next = settings
        guard next.setValue(option, for: id, to: value) else { return }
        save(next)
    }

    func reset(_ id: TweakID? = nil) {
        var next = settings
        next.reset(id)
        save(next)
    }

    private func save(_ next: TweakSettings) {
        do {
            try store.save(next)
            settings = next
        } catch {
            // A failed write must not make the UI look as though the setting was applied.
            settings = store.load()
        }
    }
}
