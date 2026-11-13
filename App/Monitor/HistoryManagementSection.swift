import Foundation
import Observation
import Storage
import SwiftUI

/// Settings row for the monitoring history database: size, retention, and clearing.
/// The window reads the size on appear and after each change; there is nothing to poll
/// because a running recorder prunes on its next write.
@MainActor
@Observable
final class HistoryManagementModel {
    private(set) var usage: HistoryDiskUsage?
    private(set) var retention: HistoryRetention = .default
    private(set) var processCollectionEnabled = false
    private(set) var seriesCollectionEnabled = false
    private(set) var message: String?

    @ObservationIgnored private var store: HistoryStore?

    func load() {
        do {
            let store = try self.store ?? HistoryStore()
            self.store = store
            retention = try store.retention()
            processCollectionEnabled = try store.isProcessCollectionEnabled()
            seriesCollectionEnabled = try store.isSeriesCollectionEnabled()
            usage = store.diskUsage()
            message = nil
        } catch {
            message = String(localized: "Couldn’t read monitoring history: \(error.localizedDescription)")
        }
    }

    /// Saves the chosen retention. A failure keeps the previous selection visible and shows why.
    func setRetention(_ retention: HistoryRetention) {
        guard let store else { return }
        do {
            try store.setRetention(retention)
            self.retention = try store.retention()
            usage = store.diskUsage()
            message = nil
        } catch {
            message = String(localized: "Couldn’t save the retention setting: \(error.localizedDescription)")
        }
    }

    /// Deletes every per-minute sample. Only called after the user confirms.
    func clear() {
        guard let store else { return }
        do {
            try store.clear(.minuteSamples)
            usage = store.diskUsage()
            message = nil
            // Only after the delete succeeded: a failed clear keeps the old points visible and
            // shows its error. The SSD page observes this and invalidates/requeries at once; a
            // clear from another process is picked up by its low-frequency refresh instead.
            NotificationCenter.default.post(name: .monitoringHistoryCleared, object: nil)
        } catch {
            message = String(localized: "Couldn’t clear monitoring history: \(error.localizedDescription)")
        }
    }

    /// Turns process name collection on or off. The running app and the background
    /// recorder read the stored switch on their next sample cycle.
    func setProcessCollectionEnabled(_ enabled: Bool) {
        guard let store else { return }
        do {
            try store.setProcessCollectionEnabled(enabled)
            processCollectionEnabled = try store.isProcessCollectionEnabled()
            message = nil
        } catch {
            message = String(localized: "Couldn’t save the process usage setting: \(error.localizedDescription)")
        }
    }

    /// Turns individual sensor and CPU-cluster collection on or off. The app and the
    /// background recorder read the stored switch on their next sample cycle.
    func setSeriesCollectionEnabled(_ enabled: Bool) {
        guard let store else { return }
        do {
            try store.setSeriesCollectionEnabled(enabled)
            seriesCollectionEnabled = try store.isSeriesCollectionEnabled()
            message = nil
        } catch {
            message = String(localized: "Couldn’t save the sensor and core usage setting: \(error.localizedDescription)")
        }
    }

    /// Deletes every stored sensor and core row. Only called after the user confirms.
    func clearSeriesHistory() {
        guard let store else { return }
        do {
            try store.clear(.seriesSamples)
            usage = store.diskUsage()
            message = nil
        } catch {
            message = String(localized: "Couldn’t clear sensor and core history: \(error.localizedDescription)")
        }
    }

    /// Deletes every stored process row. Only called after the user confirms.
    func clearProcessHistory() {
        guard let store else { return }
        do {
            try store.clear(.processSamples)
            usage = store.diskUsage()
            message = nil
        } catch {
            message = String(localized: "Couldn’t clear process usage history: \(error.localizedDescription)")
        }
    }
}

struct HistoryManagementSection: View {
    @State private var model = HistoryManagementModel()
    @State private var confirmClear = false
    @State private var confirmClearProcesses = false
    @State private var confirmClearSeries = false

    var body: some View {
        Section("Data management") {
            LabeledContent("Monitoring history", value: usageText)
            Picker("Keep monitoring history for", selection: retentionBinding) {
                ForEach(HistoryRetention.allCases, id: \.self) { retention in
                    Text(retentionLabel(retention)).tag(retention)
                }
            }
            Button("Clear Monitoring History…") { confirmClear = true }
                .disabled(model.usage == nil)
            Toggle("Record process usage", isOn: processCollectionBinding)
            Text("Only the process name, CPU use, and memory are recorded. Paths, command-line arguments, and user names are never saved. Process history follows the retention above and can be cleared at any time. The switch applies to MacHelper and to background recording; background recording keeps collecting process history even when no menu bar items are selected. Turning this off stops new process history sampling. Stored history stays until the next recording removes samples past the retention, or until you clear it. This switch only controls history recording; the live process list on the Monitor screen is not affected.")
                .settingsCaption()
            Button("Clear Process Usage History…") { confirmClearProcesses = true }
                .disabled(model.usage == nil)
                .confirmationDialog("Clear process usage history?", isPresented: $confirmClearProcesses, titleVisibility: .visible) {
                    Button("Clear Process Usage History", role: .destructive) { model.clearProcessHistory() }
                    Button("Cancel", role: .cancel) {}
                        .keyboardShortcut(.defaultAction)
                } message: {
                    Text("This permanently deletes every stored process name, its CPU use, and its memory use. It can’t be undone. Monitoring history, sensor and core history, settings, and the operation history are not affected.")
                }
            Toggle("Record sensor and core usage", isOn: seriesCollectionBinding)
            Text("Records one average per minute for every temperature sensor and CPU core cluster from the CPU and temperature samples. This adds several dozen rows per minute, so leave it off unless you need the detail. The switch applies to MacHelper and to background recording, but it needs the matching CPU or temperature menu bar item to be on. Turning this off stops new sensor and core sampling. Stored history stays until the next recording removes samples past the retention, or until you clear it.")
                .settingsCaption()
            Button("Clear Sensor and Core History…") { confirmClearSeries = true }
                .disabled(model.usage == nil)
                .confirmationDialog("Clear sensor and core history?", isPresented: $confirmClearSeries, titleVisibility: .visible) {
                    Button("Clear Sensor and Core History", role: .destructive) { model.clearSeriesHistory() }
                    Button("Cancel", role: .cancel) {}
                        .keyboardShortcut(.defaultAction)
                } message: {
                    Text("This permanently deletes every stored sensor temperature and CPU core cluster history. It can’t be undone. Monitoring history, process history, settings, and the operation history are not affected.")
                }
            if let message = model.message {
                Text(message).settingsCaption(Theme.rose)
            }
            Text("Changing the retention doesn’t delete anything right away. Samples older than the new limit are removed the next time history is recorded.")
                .settingsCaption()
        }
        .onAppear { model.load() }
        .confirmationDialog("Clear monitoring history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Monitoring History", role: .destructive) { model.clear() }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            // The dedicated catalog is shared with the SSD page; it names every recorded disk so
            // the confirmation cannot be read as clearing only the startup volume.
            Text(verbatim: DiskVolumeSelectionText.clearHistoryMessage.localized())
        }
    }

    private var usageText: String {
        guard let usage = model.usage else { return "–" }
        return Fmt.bytes(usage.totalBytes)
    }

    private var retentionBinding: Binding<HistoryRetention> {
        Binding(get: { model.retention }, set: { model.setRetention($0) })
    }

    private var processCollectionBinding: Binding<Bool> {
        Binding(get: { model.processCollectionEnabled }, set: { model.setProcessCollectionEnabled($0) })
    }

    private var seriesCollectionBinding: Binding<Bool> {
        Binding(get: { model.seriesCollectionEnabled }, set: { model.setSeriesCollectionEnabled($0) })
    }

    private func retentionLabel(_ retention: HistoryRetention) -> LocalizedStringKey {
        switch retention {
        case .oneDay: "1 day"
        case .threeDays: "3 days"
        case .sevenDays: "7 days"
        case .fourteenDays: "14 days"
        case .thirtyDays: "30 days"
        }
    }
}
