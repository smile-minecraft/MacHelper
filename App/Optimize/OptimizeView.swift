import CleanEngine
import SwiftUI

struct OptimizeView: View {
    @Bindable var model: OptimizeModel
    let autoClean: AutoCleanModel
    @State private var confirm = false
    @State private var showAutoClean = false

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle: start
            case .scanning: progress(String(localized: "Scanning for items to clean…"))
            case .running: progress(String(localized: "Cleaning…"))
            case .ready: preview
            case .finished: results
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .toolbar {
            ToolbarItem {
                Button { showAutoClean = true } label: {
                    Label(autoClean.config.enabled ? "Auto Clean: On" : "Auto Clean…", systemImage: "clock.arrow.circlepath")
                }
                .help("Regularly clean low-risk items in the background")
            }
        }
        .sheet(isPresented: $showAutoClean) { AutoCleanView(model: autoClean) }
    }

    private var start: some View {
        PixelEmptyState(art: "px.empty.clean", title: "Optimize",
                        message: "Scan first to list what can be cleaned. Nothing is cleaned until you’ve reviewed and checked it; by default items go to the Trash and can be restored.") {
            VStack(spacing: 8) {
                Button("Start Scan") { Task { await model.scan() } }.buttonStyle(.borderedProminent).controlSize(.large)
                if let e = model.loadError { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 14) {
            ScanningArt(art: "px.empty.clean")
            Text(text).font(.callout).foregroundStyle(.secondary)
            ProgressView().controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.groups, id: \.category) { group in
                    Section(group.title) {
                        ForEach(group.results) { r in RuleRow(model: model, result: r) }
                    }
                }
                if let a = model.artifacts { artifactSection(a) } else { rootsOnlySection }
                Section("Maintenance") {
                    ForEach($model.tasks) { $row in
                        HStack(alignment: .top) {
                            Toggle(isOn: $row.selected) { EmptyView() }.labelsHidden().disabled(!row.available)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(row.task.title)
                                    RiskBadge(risk: row.task.risk)
                                    if row.task.requiresRoot { Text("Needs Helper").font(.caption2).foregroundStyle(.secondary) }
                                }
                                Text(row.task.description).font(.caption).foregroundStyle(.secondary)
                                if !row.available {
                                    Text(row.task.requiresRoot && row.task.isAvailable ? "Helper not enabled" : "Not applicable on this Mac")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                        .opacity(row.available ? 1 : 0.5)
                    }
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading) {
                    Text("\(Fmt.bytes(Int64(clamping: model.selectedBytes))) selected, \(model.selectedTaskCount) maintenance tasks").bold()
                    Text("This is only a preview; nothing is deleted until you click Clean.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rescan") { Task { await model.scan() } }
                Button("Clean…") { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedBytes == 0 && model.selectedTaskCount == 0)
            }
            .padding(12)
        }
        .confirmationDialog("Clean the selected \(Fmt.bytes(Int64(clamping: model.selectedBytes)))?", isPresented: $confirm,
                            titleVisibility: .visible) {
            Button("Clean", role: .destructive) { Task { await model.run() } }
        } message: {
            Text(confirmMessage)
        }
    }

    /// Spells out what happens to the selection, with real numbers.
    private var confirmMessage: String {
        var lines: [String] = []
        if model.selectedTrashBytes > 0 {
            lines.append(String(localized: "Move to the Trash: \(Fmt.bytes(Int64(clamping: model.selectedTrashBytes))). Anything removed by mistake can be restored from the Trash."))
        }
        if model.selectedPermanentBytes > 0 {
            lines.append(String(localized: "Delete permanently: \(Fmt.bytes(Int64(clamping: model.selectedPermanentBytes))). This empties what’s already in the Trash and can’t be undone."))
        }
        if model.selectedTaskCount > 0 {
            lines.append(String(localized: "Run \(model.selectedTaskCount) maintenance tasks."))
        }
        lines.append(String(localized: "Every item is recorded in the operation log so you can review it later."))
        return lines.joined(separator: "\n")
    }

    private func artifactSection(_ a: ArtifactScanResult) -> some View {
        Section {
            ForEach(a.artifacts.prefix(200)) { art in
                HStack {
                    Toggle(isOn: Binding(get: { art.selected }, set: { _ in model.toggleArtifact(art.path) })) { EmptyView() }
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text((art.path as NSString).lastPathComponent + "  ·  " + (art.projectPath as NSString).lastPathComponent)
                        Text(art.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    if art.recentlyUsed { Text("Recently used").font(.caption2).foregroundStyle(.orange) }
                    Spacer()
                    Text(Fmt.bytes(Int64(clamping: art.size))).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            rootsEditor
        } header: {
            Text("Project Build Artifacts (\(Fmt.bytes(Int64(clamping: a.totalSize))))")
        } footer: {
            if !a.skipped.isEmpty { Text("Skipped \(a.skipped.count) items: they contain git-tracked files or a nested repository.") }
        }
    }

    private var rootsOnlySection: some View {
        Section("Project Build Artifacts") {
            Text("Add the folders where you keep projects to find rebuildable artifacts such as node_modules, target and .build.")
                .font(.caption).foregroundStyle(.secondary)
            rootsEditor
        }
    }

    private var rootsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.artifactRoots, id: \.self) { root in
                HStack {
                    Image(systemName: "folder")
                    Text(root).font(.caption).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button { model.removeArtifactRoot(root) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            Button("Add Project Folder…") { model.addArtifactRoot() }.controlSize(.small)
        }
    }

    // MARK: Results

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Cleaning Complete", systemImage: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow { Text("Moved to Trash"); Text(Fmt.bytes(Int64(clamping: model.trashedBytes))).monospacedDigit().bold() }
                GridRow { Text("Freed permanently"); Text(Fmt.bytes(Int64(clamping: model.freedBytes))).monospacedDigit().bold() }
                if !model.failures.isEmpty { GridRow { Text("Not processed"); Text("\(model.failures.count) items").foregroundStyle(.orange) } }
            }
            if model.trashedBytes > 0 {
                HStack {
                    Text("Space used by items in the Trash is freed when you empty the Trash.").font(.callout).foregroundStyle(.secondary)
                    Button("Empty Trash") { Task { await model.emptyTrash() } }
                }
            }
            if !model.taskResults.isEmpty {
                Divider()
                ForEach(model.taskResults) { t in
                    Label(t.title + (t.ok ? "" : ": \(t.output.prefix(120))"), systemImage: t.ok ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(t.ok ? Color.primary : Color.orange)
                }
            }
            if !model.failures.isEmpty {
                DisclosureGroup("Items not processed") {
                    ForEach(model.failures, id: \.path) { f in
                        Text(verbatim: "\(f.path): \(f.message ?? "")").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            HStack {
                Text("All operations are logged in ~/Library/Logs/MacHelper/operations.jsonl").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Scan Again") { Task { await model.scan() } }
            }
        }
        .padding(20)
    }
}

private struct RuleRow: View {
    let model: OptimizeModel
    let result: RuleResult
    @State private var expanded = false

    var body: some View {
        if result.candidates.isEmpty {
            HStack {
                Text(result.rule.title).foregroundStyle(.secondary)
                Spacer()
                if let reason = result.skippedReason {
                    Text("Skipped: \(reason)").font(.caption).foregroundStyle(.secondary)
                } else if result.rule.needsFullDiskAccess {
                    Button("Needs Full Disk Access") { model.openFullDiskAccessSettings() }.buttonStyle(.link).font(.caption)
                } else {
                    Text("Nothing to clean").font(.caption).foregroundStyle(.tertiary)
                }
            }
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(result.candidates.prefix(300)) { c in
                    HStack {
                        Toggle(isOn: Binding(get: { c.selected }, set: { _ in model.toggleCandidate(rule: result.rule.id, path: c.path) })) {
                            EmptyView()
                        }
                        .labelsHidden()
                        Text((c.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        if let note = c.note { Text(note).font(.caption2).foregroundStyle(.orange) }
                        Spacer()
                        Text(Fmt.bytes(Int64(clamping: c.size))).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .help(c.path)
                }
            } label: {
                HStack(alignment: .top) {
                    Toggle(isOn: Binding(get: { model.isRuleSelected(result.rule.id) ?? false },
                                         set: { model.setRule(result.rule.id, selected: $0) })) { EmptyView() }
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(result.rule.title)
                            RiskBadge(risk: result.rule.risk)
                            if model.isRuleSelected(result.rule.id) == nil { Text("Partial").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(result.rule.description).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Fmt.bytes(Int64(clamping: result.totalSize))).monospacedDigit()
                }
            }
        }
    }
}

struct RiskBadge: View {
    let risk: RiskLevel
    var body: some View {
        let (text, color): (String, Color) = switch risk {
        case .low: (String(localized: "Low risk"), .green)
        case .medium: (String(localized: "Medium risk"), .orange)
        case .high: (String(localized: "High risk"), .red)
        }
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
