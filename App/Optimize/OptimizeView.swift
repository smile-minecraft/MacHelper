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
                if let e = model.loadError { Text(e).font(.caption).foregroundStyle(Theme.rose) }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 14) {
            ScanningArt(art: "px.empty.clean")
            Text(text).font(.callout).foregroundStyle(Palette.textMuted)
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
                systemSection
                Section("Maintenance") {
                    if let docker = model.dockerUsage { DockerUsageRow(result: docker) }
                    ForEach($model.tasks) { $row in
                        HStack(alignment: .top) {
                            Toggle(isOn: $row.selected) { EmptyView() }.labelsHidden().disabled(!row.available)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(row.task.title).foregroundStyle(Palette.text)
                                    RiskBadge(risk: row.task.risk)
                                    if row.task.requiresRoot { Text("Needs Helper").font(.caption2).foregroundStyle(Palette.textMuted) }
                                }
                                Text(row.task.description).font(.caption).foregroundStyle(Palette.textMuted)
                                if !row.available {
                                    Text(row.task.requiresRoot && row.task.isAvailable ? "Helper not enabled" : "Not applicable on this Mac")
                                        .font(.caption2).foregroundStyle(Theme.amber)
                                }
                            }
                        }
                        .opacity(row.available ? 1 : 0.5)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Fmt.bytes(Int64(clamping: model.selectedBytes))) selected, \(model.selectedTaskCount) maintenance tasks")
                        .font(Theme.smallNumeral)
                        .foregroundStyle(Palette.text)
                    Text("This is only a preview; nothing is deleted until you click Clean. Low-risk items are deleted directly, medium and high risk go to the Trash.").font(.caption).foregroundStyle(Palette.textMuted)
                }
                Spacer(minLength: 12)
                Button("Rescan") { Task { await model.scan() } }
                Button("Clean…") { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedBytes == 0 && model.selectedTaskCount == 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.card)
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
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
        let directBytes = model.selectedPermanentBytes - model.selectedEmptyTrashBytes - model.selectedSystemBytes
        if directBytes > 0 {
            lines.append(String(localized: "Delete directly: \(Fmt.bytes(Int64(clamping: directBytes))) of low-risk caches and logs that apps rebuild themselves. They don’t go to the Trash."))
        }
        if model.selectedSystemBytes > 0 {
            lines.append(String(localized: "Delete old system logs and diagnostic reports as administrator: \(Fmt.bytes(Int64(clamping: model.selectedSystemBytes))). Only files older than 30 days in the fixed system log folders."))
        }
        if model.selectedEmptyTrashBytes > 0 {
            lines.append(String(localized: "Empty the Trash: \(Fmt.bytes(Int64(clamping: model.selectedEmptyTrashBytes))). This can’t be undone."))
        }
        if model.selectedTaskCount > 0 {
            lines.append(String(localized: "Run \(model.selectedTaskCount) maintenance tasks."))
        }
        lines.append(String(localized: "Every item is recorded in the operation log so you can review it later."))
        return lines.joined(separator: "\n")
    }

    private var systemSection: some View {
        Section {
            ForEach($model.systemRows) { $row in
                HStack(alignment: .top) {
                    Toggle(isOn: $row.selected) { EmptyView() }.labelsHidden().disabled(row.count == 0)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.info.title).foregroundStyle(Palette.text)
                            RiskBadge(risk: row.info.risk)
                            Text("Deleted directly").font(.caption2).foregroundStyle(Palette.textMuted)
                            Text("Needs Helper").font(.caption2).foregroundStyle(Palette.textMuted)
                        }
                        Text(row.info.description).font(.caption).foregroundStyle(Palette.textMuted)
                        if let p = row.preview {
                            if let why = p.unavailable {
                                Text("Can’t read \(row.info.folder): \(why)").font(.caption2).foregroundStyle(Theme.amber)
                            } else {
                                Text(p.count == 0 ? String(localized: "Nothing older than 30 days") : String(localized: "\(p.count) files"))
                                    .font(.caption2).foregroundStyle(Palette.textFaint)
                            }
                        }
                    }
                    Spacer()
                    if row.preview != nil {
                        Text(Fmt.bytes(Int64(clamping: row.bytes))).monospacedDigit().foregroundStyle(Palette.text)
                    }
                }
                .opacity(row.preview == nil ? 0.5 : 1)
            }
        } header: {
            HStack(spacing: 8) {
                Text("System Logs")
                if let e = model.systemError {
                    Text(e).font(.caption).foregroundStyle(Theme.amber).lineLimit(1).truncationMode(.tail).help(e).textCase(nil)
                }
            }
        }
    }

    private func artifactSection(_ a: ArtifactScanResult) -> some View {
        Section {
            ForEach(a.artifacts.prefix(200)) { art in
                HStack {
                    Toggle(isOn: Binding(get: { art.selected }, set: { _ in model.toggleArtifact(art.path) })) { EmptyView() }
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text((art.path as NSString).lastPathComponent + "  ·  " + (art.projectPath as NSString).lastPathComponent)
                            .foregroundStyle(Palette.text)
                        Text(art.path).font(.caption2).foregroundStyle(Palette.textMuted).lineLimit(1).truncationMode(.head)
                    }
                    if art.recentlyUsed { Text("Recently used").font(.caption2).foregroundStyle(Theme.amber) }
                    Spacer()
                    Text(Fmt.bytes(Int64(clamping: art.size))).monospacedDigit().foregroundStyle(Palette.textMuted)
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
                .font(.caption).foregroundStyle(Palette.textMuted)
            rootsEditor
        }
    }

    private var rootsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.artifactRoots, id: \.self) { root in
                HStack {
                    Image(systemName: "folder").foregroundStyle(Palette.textMuted)
                    Text(root).font(.caption).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button { model.removeArtifactRoot(root) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            Button("Add Project Folder…") { model.addArtifactRoot() }.controlSize(.small)
        }
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Cleaning Complete", systemImage: "checkmark.seal.fill").font(.title2).foregroundStyle(Theme.mint)
                Grid(alignment: .leading, verticalSpacing: 6) {
                    GridRow { Text("Moved to Trash").foregroundStyle(Palette.textMuted); Text(Fmt.bytes(Int64(clamping: model.trashedBytes))).monospacedDigit().bold().foregroundStyle(Palette.text) }
                    GridRow { Text("Freed permanently").foregroundStyle(Palette.textMuted); Text(Fmt.bytes(Int64(clamping: model.freedBytes))).monospacedDigit().bold().foregroundStyle(Palette.text) }
                    if !model.failures.isEmpty { GridRow { Text("Not processed").foregroundStyle(Palette.textMuted); Text("\(model.failures.count) items").foregroundStyle(Theme.amber) } }
                }
                .card(padding: 16)
                if model.trashedBytes > 0 {
                    HStack {
                        Text("Space used by items in the Trash is freed when you empty the Trash.").font(.callout).foregroundStyle(Palette.textMuted)
                        Button("Empty Trash") { Task { await model.emptyTrash() } }
                    }
                }
                if !model.taskResults.isEmpty {
                    Divider()
                    ForEach(model.taskResults) { t in
                        Label(t.title + (t.ok ? "" : ": \(t.output.prefix(120))"), systemImage: t.ok ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(t.ok ? Palette.text : Theme.orange)
                    }
                }
                if !model.failures.isEmpty {
                    DisclosureGroup("Items not processed") {
                        ForEach(model.failures, id: \.path) { f in
                            Text(verbatim: "\(f.path): \(f.message ?? "")").font(.caption).foregroundStyle(Palette.textMuted)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 12) {
                Text("All operations are logged in ~/Library/Logs/MacHelper/operations.jsonl").font(.caption).foregroundStyle(Palette.textMuted)
                Spacer(minLength: 12)
                Button("Scan Again") { Task { await model.scan() } }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.card)
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }
    }
}

private struct RuleRow: View {
    let model: OptimizeModel
    let result: RuleResult
    @State private var expanded = false

    var body: some View {
        if result.candidates.isEmpty {
            HStack {
                Text(result.rule.title).foregroundStyle(Palette.textMuted)
                Spacer()
                if let reason = result.skippedReason {
                    Text("Skipped: \(reason)").font(.caption).foregroundStyle(Palette.textMuted)
                } else if result.rule.needsFullDiskAccess {
                    Button("Needs Full Disk Access") { model.openFullDiskAccessSettings() }.buttonStyle(.link).font(.caption)
                } else {
                    Text("Nothing to clean").font(.caption).foregroundStyle(Palette.textFaint)
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
                        Text((c.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.text)
                        if let note = c.note { Text(note).font(.caption2).foregroundStyle(Theme.amber) }
                        Spacer()
                        Text(Fmt.bytes(Int64(clamping: c.size))).monospacedDigit().foregroundStyle(Palette.textMuted)
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
                            Text(result.rule.title).foregroundStyle(Palette.text)
                            RiskBadge(risk: result.rule.risk)
                            Text(result.rule.action == .delete ? "Deleted directly" : "To Trash")
                                .font(.caption2).foregroundStyle(Palette.textMuted)
                            if model.isRuleSelected(result.rule.id) == nil { Text("Partial").font(.caption2).foregroundStyle(Palette.textMuted) }
                        }
                        Text(result.rule.description).font(.caption).foregroundStyle(Palette.textMuted)
                    }
                    Spacer()
                    Text(Fmt.bytes(Int64(clamping: result.totalSize))).monospacedDigit().foregroundStyle(Palette.text)
                }
            }
        }
    }
}

private struct RiskBadge: View {
    let risk: RiskLevel
    var body: some View {
        let (text, color): (String, Color) = switch risk {
        case .low: (String(localized: "Low risk"), Theme.mint)
        case .medium: (String(localized: "Medium risk"), Theme.amber)
        case .high: (String(localized: "High risk"), Theme.rose)
        }
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Read-only Docker disk usage shown above the Docker maintenance tasks.
private struct DockerUsageRow: View {
    let result: Result<DockerUsage, DockerUsage.Failure>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Docker disk usage").foregroundStyle(Palette.text)
            switch result {
            case .success(let usage):
                Text("\(Fmt.bytes(Int64(clamping: usage.totalSize))) used, \(Fmt.bytes(Int64(clamping: usage.totalReclaimable))) reclaimable according to Docker")
                    .font(.caption).foregroundStyle(Palette.textMuted)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                    ForEach(usage.rows) { r in
                        GridRow {
                            Text(label(r.kind, fallback: r.type))
                            Text("\(r.totalCount) (\(r.active) in use)").gridColumnAlignment(.trailing)
                            Text(Fmt.bytes(Int64(clamping: r.size))).gridColumnAlignment(.trailing)
                            Text("\(Fmt.bytes(Int64(clamping: r.reclaimable))) reclaimable").gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(Palette.textMuted)
                Text("Clearing all build cache or unused images can reclaim more than Docker’s estimate; volumes are never removed here.")
                    .font(.caption2).foregroundStyle(Palette.textMuted)
            case .failure(.engineNotRunning):
                Text("Docker is installed but its engine isn’t running. Start Docker Desktop or OrbStack, then rescan.")
                    .font(.caption).foregroundStyle(Theme.amber)
            case .failure(.notInstalled):
                EmptyView()
            case .failure(.unreadable(let message)):
                Text("Couldn’t read Docker disk usage: \(message)").font(.caption).foregroundStyle(Theme.amber).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func label(_ kind: DockerUsage.Row.Kind, fallback: String) -> String {
        switch kind {
        case .images: String(localized: "docker.kind.images", defaultValue: "Images")
        case .containers: String(localized: "docker.kind.containers", defaultValue: "Containers")
        case .volumes: String(localized: "docker.kind.volumes", defaultValue: "Volumes")
        case .buildCache: String(localized: "docker.kind.buildCache", defaultValue: "Build cache")
        case .other: fallback
        }
    }
}
