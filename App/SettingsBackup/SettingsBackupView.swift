import AppKit
import SettingsPortability
import SMCKit
import SwiftUI
import UniformTypeIdentifiers

/// Export and import entry point in Settings → General.
@MainActor
struct SettingsBackupSection: View {
    let app: AppModel

    @State private var selected: Set<String>
    @State private var hasEditedSelection = false
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var plan: ImportPlan?
    @State private var planFileName = ""
    @State private var planDetails: [String: [String]] = [:]
    @State private var showingPlan = false
    @State private var showsRelaunch = false
    @State private var isWorking = false

    init(app: AppModel) {
        self.app = app
        var categories = Set(SettingsCategory.allCases.map(\.rawValue))
        // Only a status that is already known can turn Fans off. Before the first refresh the
        // section starts with every category selected, and the refresh below corrects it.
        if app.fanModel.status?.canControl == false {
            categories.remove(SettingsCategory.fans.rawValue)
        }
        _selected = State(initialValue: categories)
    }

    var body: some View {
        Section("Backup & Restore") {
            Text("Export the settings you select to one file, or import a file on this or another Mac. Settings files never include monitoring history, scan caches, operation logs, background recording, or the Helper registration.")
                .settingsCaption()
            ForEach(SettingsCategory.allCases, id: \.self) { category in
                Toggle(category.title, isOn: selectionBinding(category))
                    .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Export Selected Settings…") { export() }
                    .disabled(selected.isEmpty || isWorking)
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Importing replaces each category marked “Will replace”. Categories that aren’t in the file are left as they are.")
                    .settingsCaption()
                Spacer()
                Button("Import Settings…") { prepareImport() }
                    .disabled(isWorking || isOptimizeBusy)
            }
            Text("The cleaning whitelist and extra purge folders are replaced as a whole list. Comments and blank lines in the current text files aren’t kept.")
                .settingsCaption()
            if let status {
                Text(status).settingsCaption(Theme.mint)
            }
            if let errorMessage {
                Text(errorMessage).settingsCaption(Theme.rose)
            }
            if showsRelaunch {
                HStack {
                    Text("The new language is used after MacHelper relaunches.")
                        .settingsCaption()
                    Spacer()
                    Button("Relaunch") { relaunch() }
                }
            }
        }
        .sheet(isPresented: $showingPlan) {
            if let plan {
                ImportPlanView(plan: plan, fileName: planFileName, details: planDetails,
                               isOptimizeBusy: isOptimizeBusy,
                               onCancel: { showingPlan = false },
                               onApply: { apply(plan) })
            }
        }
        .task {
            // The section can appear before the first fan refresh (or while the Helper is not
            // running). Refresh once so the Fans default reflects this Mac, not a missing status.
            await app.fanModel.refresh()
            guard !hasEditedSelection, app.fanModel.status?.canControl == false else { return }
            selected.remove(SettingsCategory.fans.rawValue)
        }
    }

    private func selectionBinding(_ category: SettingsCategory) -> Binding<Bool> {
        Binding(
            get: { selected.contains(category.rawValue) },
            set: { on in
                hasEditedSelection = true
                if on { selected.insert(category.rawValue) } else { selected.remove(category.rawValue) }
            }
        )
    }

    private var fansAvailable: Bool {
        canControlFans(app.fanModel.status)
    }

    /// Importing changes the rule and whitelist files a scan is reading, so it waits until Optimize
    /// is neither scanning nor cleaning.
    private var isOptimizeBusy: Bool {
        app.optimizeModel.phase == .scanning || app.optimizeModel.phase == .running
    }

    private func sections() -> [any SettingsSection] {
        SettingsBackupSections.all(hasFans: fansAvailable)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacHelper Settings.json"
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let ids = SettingsCategory.allCases.map(\.rawValue).filter(selected.contains)
            let exporter = SettingsExporter(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                machineIdentifier: sysctlString("hw.model") ?? ""
            )
            let data = try exporter.export(ids, from: sections())
            try data.write(to: url, options: .atomic)
            status = String(format: String(localized: "Exported to %@."), url.lastPathComponent)
            errorMessage = nil
        } catch {
            errorMessage = String(format: String(localized: "Couldn’t export settings: %@"),
                                  String(describing: error))
            status = nil
        }
    }

    private func prepareImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            errorMessage = String(format: String(localized: "Couldn’t read the file: %@"), String(describing: error))
            status = nil
            return
        }

        isWorking = true
        Task { @MainActor in
            // The fan plan needs the same fan list the fan screen uses.
            await app.fanModel.refresh()
            defer { isWorking = false }
            do {
                let importer = SettingsImporter(sections: sections())
                let incoming = try importer.plan(for: data)
                plan = incoming
                planFileName = url.lastPathComponent
                planDetails = sectionDetails(from: data)
                status = nil
                errorMessage = nil
                showingPlan = true
            } catch let error as SettingsArchiveError {
                errorMessage = error.isNewerVersion
                    ? String(localized: "This file was created by a newer version of MacHelper and can’t be imported. Nothing was changed.")
                    : String(localized: "This file isn’t a MacHelper settings file. Nothing was changed.")
                status = nil
            } catch {
                errorMessage = String(format: String(localized: "Couldn’t read the file: %@"), String(describing: error))
                status = nil
            }
        }
    }

    /// Lines shown under a category in the plan. Only categories whose value is a list need them.
    private func sectionDetails(from data: Data) -> [String: [String]] {
        guard let archive = try? SettingsArchive.decode(data) else { return [:] }
        var details: [String: [String]] = [:]

        if let rules = archive.sections[SettingsCategory.cleanRules.rawValue],
           case .valid(let payload) = CleanRulesPayload.validated(rules) {
            details[SettingsCategory.cleanRules.rawValue] = payload.details
        }
        for category in [SettingsCategory.cleanWhitelist, .cleanPurgePaths, .optimizeRoots] {
            guard let section = archive.sections[category.rawValue],
                  case .valid(let payload) = PathListPayload.validated(section),
                  let paths = try? JSONDecoder().decode(PathListPayload.self, from: payload.data)
            else { continue }
            details[category.rawValue] = paths.paths
        }
        return details
    }

    private func apply(_ plan: ImportPlan) {
        // A scan or clean can start after the plan was prepared; writing the rule files now would
        // change what that run is reading, so the apply waits for the next attempt.
        guard !isOptimizeBusy else { return }
        let overwritten = Set(plan.entries.compactMap { entry -> String? in
            if case .overwrite = entry.status { return entry.section }
            return nil
        })
        let languageBefore = GeneralSettingsSection.currentLanguage()

        do {
            try SettingsImporter(sections: sections()).apply(plan)
            reload(overwritten)
            showsRelaunch = overwritten.contains(SettingsCategory.general.rawValue)
                && GeneralSettingsSection.currentLanguage() != languageBefore
            status = String(localized: "Settings imported.")
            errorMessage = nil
        } catch {
            errorMessage = importMessage(error)
            status = nil
        }
        showingPlan = false
    }

    private func reload(_ ids: Set<String>) {
        if ids.contains(SettingsCategory.general.rawValue) {
            AppModel.applyDockPreference()
        }
        if ids.contains(SettingsCategory.monitor.rawValue) {
            app.settings.reload()
        }
        if ids.contains(SettingsCategory.alerts.rawValue) {
            app.store.alerts.reload()
        }
        if ids.contains(SettingsCategory.fans.rawValue) {
            app.fanSwitcher.reload()
            app.fanModel.reload()
        }
        let scanInputs: Set<String> = [
            SettingsCategory.cleanRules.rawValue, SettingsCategory.cleanWhitelist.rawValue,
            SettingsCategory.cleanPurgePaths.rawValue, SettingsCategory.optimizeRoots.rawValue,
        ]
        if !ids.isDisjoint(with: scanInputs) {
            app.optimizeModel.reload()
        }
    }

    private func importMessage(_ error: Error) -> String {
        guard case SettingsImportError.applyFailed(let section, let reason, let rollbackFailures) = error else {
            return String(format: String(localized: "Couldn’t import settings: %@"), String(describing: error))
        }
        let name = SettingsCategory(rawValue: section)?.title ?? section
        var text = String(format: String(localized: "Couldn’t import %@: %@"), name, reason)
        if !rollbackFailures.isEmpty {
            text += " " + String(format: String(localized: "These categories could not be restored: %@."),
                                 rollbackFailures.joined(separator: ", "))
        }
        return text
    }

    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// The confirmation dialog. Nothing is written until the destructive button is pressed.
@MainActor
private struct ImportPlanView: View {
    let plan: ImportPlan
    let fileName: String
    let details: [String: [String]]
    let isOptimizeBusy: Bool
    let onCancel: () -> Void
    let onApply: () -> Void

    private var hasOverwrite: Bool {
        plan.entries.contains { entry in
            if case .overwrite = entry.status { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Settings").font(.mhHeadline)
                Text("Review what each category will do. Nothing changes until you choose Apply Import.")
                    .settingsCaption()
            }

            Text(String(format: String(localized: "File: %@"), fileName))
                .font(.mhCallout)
            Text(String(format: String(localized: "Exported by MacHelper %@ on %@."),
                        plan.appVersion,
                        plan.exportedAt.formatted(date: .abbreviated, time: .shortened)))
                .settingsCaption()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.entries, id: \.section) { entry in
                        entryRow(entry)
                        if entry.section != plan.entries.last?.section {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 320)

            if !hasOverwrite {
                Text("Nothing in this file will replace a setting on this Mac. No changes will be made.")
                    .settingsCaption(Theme.amber)
            }
            Text("Settings files never include monitoring history, scan caches, operation logs, or background recording.")
                .settingsCaption()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                if hasOverwrite {
                    Button("Apply Import", role: .destructive) { onApply() }
                        .disabled(isOptimizeBusy)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private func entryRow(_ entry: ImportPlan.Entry) -> some View {
        let title = SettingsCategory(rawValue: entry.section)?.title ?? entry.section
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.mhCallout.weight(.medium))
                Spacer()
                Text(statusLabel(entry.status))
                    .font(.mhCaption.weight(.semibold))
                    .foregroundStyle(statusColor(entry.status))
            }
            if let detail = statusDetail(entry.status), detail != title {
                Text(detail).settingsCaption()
            }
            if let lines = details[entry.section] {
                if lines.isEmpty {
                    if case .overwrite = entry.status {
                        Text("This category is empty in the file. Importing clears the current value.")
                            .settingsCaption(Theme.amber)
                    }
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.mhCaption2).foregroundStyle(Palette.textMuted)
                    }
                    if entry.section == SettingsCategory.cleanRules.rawValue, case .overwrite = entry.status {
                        Text("Imported rules are not selected by default.")
                            .settingsCaption(Theme.amber)
                    }
                }
            }
        }
    }

    private func statusLabel(_ status: ImportStatus) -> String {
        switch status {
        case .overwrite: String(localized: "Will replace")
        case .unchanged: String(localized: "No change")
        case .incompatible: String(localized: "Not compatible")
        case .invalid: String(localized: "Invalid")
        }
    }

    private func statusColor(_ status: ImportStatus) -> Color {
        switch status {
        case .overwrite: Theme.amber
        case .unchanged: Palette.textMuted
        case .incompatible, .invalid: Theme.rose
        }
    }

    private func statusDetail(_ status: ImportStatus) -> String? {
        switch status {
        case .overwrite(let summary): summary.isEmpty ? nil : summary
        case .unchanged: nil
        case .incompatible(let reason), .invalid(let reason): reason
        }
    }
}

extension SettingsCategory {
    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .monitor: String(localized: "Menu Bar")
        case .alerts: String(localized: "Alerts")
        case .fans: String(localized: "Fans")
        case .cleanRules: String(localized: "Custom Cleaning Rules")
        case .cleanWhitelist: String(localized: "Cleaning Whitelist")
        case .cleanPurgePaths: String(localized: "Extra Purge Folders")
        case .optimizeRoots: String(localized: "Optimize Scan Folders")
        }
    }
}

private extension SettingsArchiveError {
    var isNewerVersion: Bool {
        if case .unsupportedVersion = self { return true }
        return false
    }
}
