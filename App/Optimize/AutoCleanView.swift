import CleanEngine
import SwiftUI

struct AutoCleanView: View {
    @Bindable var model: AutoCleanModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Auto Clean", systemImage: "clock.arrow.circlepath").font(.mhTitle2.bold())
            Text("Regularly cleans low-risk items in the background: app caches, logs, browser and developer tool caches. Running apps are skipped, the Trash is never emptied, and MacHelper doesn’t need to be open.")
                .font(.mhCallout).foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Toggle("Enable Auto Clean", isOn: $model.enabled)
                Picker("Frequency", selection: $model.frequency) {
                    Text("Every 30 Minutes").tag(AutoCleanConfig.Frequency.every30Minutes)
                    Text("Hourly").tag(AutoCleanConfig.Frequency.hourly)
                    Text("Every 3 Hours").tag(AutoCleanConfig.Frequency.every3Hours)
                    Text("Daily").tag(AutoCleanConfig.Frequency.daily)
                    Text("Weekly").tag(AutoCleanConfig.Frequency.weekly)
                }
                .disabled(!model.enabled)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Move to the Trash instead of deleting", isOn: $model.trashInstead)
                    Text(model.trashInstead
                         ? "Cleaned items go to the Trash; the space is freed once you empty it."
                         : "Items are deleted directly and free space immediately: caches, logs, and (if enabled) expired temporary files. In-use items and items managed by the system are never touched.")
                        .font(.mhCaption).foregroundStyle(Palette.textMuted)
                }
                if let scheduleError = model.scheduleMigrationError {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Background schedule update failed", systemImage: "exclamationmark.triangle")
                            .font(.mhCaption).foregroundStyle(Theme.orange)
                        Text(scheduleError).font(.mhCaption).foregroundStyle(Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry schedule update") { model.retryScheduleMigration() }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Clean expired temporary files", isOn: Binding(get: { model.tempClean },
                                                                           set: { model.tempClean = $0 }))
                            .disabled(!model.enabled)
                        Text("Files and folders in your Mac’s temporary folder that are at least 7 days old, unchanged, and not in use move to the Trash — or are deleted permanently, whichever your “Move to the Trash instead of deleting” setting says. Anything in use, still being written, or managed by the system is skipped.")
                            .font(.mhCaption).foregroundStyle(Palette.textMuted)
                    }
                } header: {
                    Text("Temporary Files")
                } footer: {
                    Text("Off by default. Retention is 7 days regardless of schedule frequency. With the Trash setting off — the default for existing installs — expired files are deleted permanently, freeing space; with it on, they move to the Trash, freeing space once you empty it.")
                        .font(.mhCaption).foregroundStyle(Palette.textMuted)
                }
                Section {
                    ForEach(model.maintenanceRows, id: \.task.id) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(row.task.title, isOn: Binding(get: { model.isMaintenanceEnabled(row.task.id) },
                                                                 set: { model.setMaintenance(row.task.id, enabled: $0) }))
                            Text(row.available ? row.task.description : String(localized: "Not applicable on this Mac; skipped."))
                                .font(.mhCaption).foregroundStyle(Palette.textMuted)
                        }
                    }
                } header: {
                    Text("Maintenance")
                } footer: {
                    Text("Only tasks that are safe to repeat and lose nothing the system doesn’t rebuild can run unattended.")
                        .font(.mhCaption).foregroundStyle(Palette.textMuted)
                }
            }
            .formStyle(.grouped)

            GroupBox("Last Run") {
                VStack(alignment: .leading, spacing: 4) {
                    if let last = model.config.lastRun {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                        Text("\(model.config.lastItemCount) items · \(Fmt.bytes(Int64(clamping: model.config.lastTrashedBytes))) to the Trash · \(Fmt.bytes(Int64(clamping: model.config.lastFreedBytes))) deleted")
                            .font(.mhCaption).foregroundStyle(Palette.textMuted)
                    } else {
                        Text("Hasn’t run yet").foregroundStyle(Palette.textMuted)
                    }
                    ForEach(model.config.lastTasks ?? [], id: \.id) { t in
                        Label(model.title(forTask: t.id), systemImage: t.ok ? "checkmark.circle" : "xmark.circle")
                            .font(.mhCaption).foregroundStyle(t.ok ? Palette.textMuted : Theme.orange)
                    }
                    if let e = model.config.lastError { Text(e).font(.mhCaption).foregroundStyle(Theme.orange) }
                    if model.enabled, let next = model.config.nextRun {
                        Text("Next: after about \(next.formatted(date: .abbreviated, time: .shortened))").font(.mhCaption).foregroundStyle(Palette.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.enabled && model.agentStatus == .requiresApproval {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                    Text("The background schedule needs your approval in Login Items.")
                    Button("Open Login Items") { PermissionFlow.shared.openGuided(.autoCleanSchedule) }
                }
                .font(.mhCallout)
            }
            if let m = model.message { Text(m).font(.mhCaption).foregroundStyle(Palette.textMuted) }

            HStack {
                Text("You can also run it from the command line: machelper autoclean --now").font(.mhCaption).foregroundStyle(Palette.textFaint).textSelection(.enabled)
                Spacer()
                Button(model.isRunning ? "Cleaning…" : "Run Now") { Task { await model.runNow() } }
                    .disabled(model.isRunning)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { model.refresh() }
    }
}
