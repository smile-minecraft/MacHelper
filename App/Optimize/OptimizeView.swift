import CleanEngine
import SwiftUI

struct OptimizeView: View {
    @Bindable var model: OptimizeModel
    let autoClean: AutoCleanModel
    @State private var confirm = false
    @State private var showAutoClean = false
    @State private var showExclusions = false
    @State private var category: String?

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle: start
            case .scanning: scanning
            case .running: progress(String(localized: "Cleaning…"))
            case .ready: preview
            case .finished: results
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .toolbar {
            ToolbarItem {
                Button { showExclusions = true } label: { Label("Never Clean…", systemImage: "hand.raised") }
                    .help("Paths MacHelper never cleans")
            }
            ToolbarItem {
                Button { showAutoClean = true } label: {
                    Label(autoClean.config.enabled ? "Auto Clean: On" : "Auto Clean…", systemImage: "clock.arrow.circlepath")
                }
                .help("Regularly clean low-risk items in the background")
            }
        }
        .sheet(isPresented: $showAutoClean) { AutoCleanView(model: autoClean) }
        .sheet(isPresented: $showExclusions) { ExclusionsView(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheckFullDiskAccess()
        }
    }

    private var start: some View {
        PixelEmptyState(art: "px.empty.clean", title: "Optimize",
                        message: "Scan first to list what can be cleaned.") {
            VStack(spacing: 8) {
                Button("Start Scan") { Task { await model.scan() } }.buttonStyle(.borderedProminent).controlSize(.large)
                if model.scanStopped { Text("Scan stopped before any results were ready.").font(.mhCaption).foregroundStyle(Palette.textMuted) }
                if let e = model.loadError { Text(e).font(.mhCaption).foregroundStyle(Theme.rose) }
                if !model.fullDiskAccess {
                    Button("Allow Full Disk Access to see everything") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.link).font(.mhCaption)
                }
            }
        }
    }

    private var scanning: some View {
        VStack(spacing: 14) {
            ScanningArt(art: "px.empty.clean")
            Text("Scanning for items to clean…").font(.mhCallout).foregroundStyle(Palette.textMuted)
            if let p = model.scanProgress, p.total > 0 {
                ProgressView(value: Double(p.done), total: Double(p.total)).frame(width: 260)
                Text("\(p.done) of \(p.total) places checked").font(.mhCaption.monospacedDigit()).foregroundStyle(Palette.textFaint)
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Stop Scan") { model.stopScan() }
                .help("Stop and show what has been found so far")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 14) {
            ScanningArt(art: "px.empty.clean")
            Text(text).font(.mhCallout).foregroundStyle(Palette.textMuted)
            ProgressView().controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 0) {
            notices
            // Two panes: categories with their selected size on the left, the chosen category's items on the right.
            HStack(spacing: 0) {
                categoryList
                    .frame(width: 250)
                Rectangle().fill(Palette.hairline).frame(width: 1)
                categoryDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectionSummary)
                        .font(Theme.smallNumeral)
                        .foregroundStyle(Palette.text)
                    Text("Low-risk items are deleted directly, medium and high risk go to the Trash.").font(.mhCaption).foregroundStyle(Palette.textMuted)
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

    /// The running total in the footer. Maintenance tasks are only mentioned when some are selected,
    /// so an empty selection doesn’t read as “0 maintenance tasks”.
    private var selectionSummary: String {
        let bytes = Fmt.bytes(Int64(clamping: model.selectedBytes))
        if model.selectedTaskCount > 0 {
            return String(localized: "\(bytes) selected, \(model.selectedTaskCount) maintenance tasks")
        }
        return String(localized: "\(bytes) selected")
    }

    /// Why the preview may be incomplete: the scan was stopped, or Full Disk Access is off.
    @ViewBuilder private var notices: some View {
        if model.scanStopped {
            NoticeBar(icon: "pause.circle", text: String(localized: "Scan stopped early. Only the places checked before that are listed."),
                      action: String(localized: "Scan Everything")) { Task { await model.scan() } }
        }
        if model.hiddenByFullDiskAccess > 0 {
            NoticeBar(icon: "lock", text: String(localized: "\(model.hiddenByFullDiskAccess) places can’t be checked without Full Disk Access. MacHelper scans again once it’s on."),
                      action: String(localized: "Open System Settings")) { model.openFullDiskAccessSettings() }
        }
    }

    // MARK: Categories

    private struct Category: Identifiable {
        let id: String
        let title: String
        let icon: String
        let detail: String
    }

    private var categories: [Category] {
        var out: [Category] = []
        if let plan = model.plan, plan.results.contains(where: { !$0.candidates.isEmpty }) {
            out.append(Category(id: "all", title: String(localized: "All Items"), icon: "list.bullet",
                                detail: selectedText(plan.selectedSize, of: plan.totalSize)))
        }
        out += model.groups.map { g in
            Category(id: g.category, title: g.title, icon: Self.icon(g.category),
                     detail: selectedText(g.results.reduce(0) { $0 + $1.selectedSize }, of: g.results.reduce(0) { $0 + $1.totalSize }))
        }
        out.append(Category(id: "artifacts", title: String(localized: "Project Build Artifacts"), icon: "hammer",
                            detail: model.artifacts.map { selectedText($0.selectedSize, of: $0.totalSize) } ?? String(localized: "Add project folders")))
        out.append(Category(id: "system", title: String(localized: "System Logs"), icon: "lock.doc",
                            detail: model.systemError == nil
                                ? selectedText(model.selectedSystemBytes, of: model.systemRows.reduce(0) { $0 + $1.bytes })
                                : String(localized: "Needs Helper")))
        out.append(Category(id: "maintenance", title: String(localized: "Maintenance"), icon: "wrench.and.screwdriver",
                            detail: String(localized: "\(model.selectedTaskCount) of \(model.tasks.filter(\.available).count) tasks")))
        return out
    }

    private func selectedText(_ selected: UInt64, of total: UInt64) -> String {
        total == 0 ? String(localized: "Nothing to clean")
            : String(localized: "\(Fmt.bytes(Int64(clamping: selected))) of \(Fmt.bytes(Int64(clamping: total)))")
    }

    private static func icon(_ category: String) -> String {
        switch category {
        case "caches": "archivebox"
        case "logs": "doc.text"
        case "browsers": "globe"
        case "developer": "chevron.left.forwardslash.chevron.right"
        case "trash": "trash"
        case "downloads": "arrow.down.circle"
        case "mail": "envelope"
        case "backups": "iphone"
        case "ai": "brain"
        default: "folder"
        }
    }

    private var selectedCategory: String { category ?? categories.first?.id ?? "maintenance" }

    private var categoryList: some View {
        List(selection: Binding(get: { selectedCategory }, set: { category = $0 })) {
            ForEach(categories) { c in
                HStack(spacing: 10) {
                    Image(systemName: c.icon).frame(width: 18).foregroundStyle(Palette.textMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(.mhBody.weight(.medium)).foregroundStyle(Palette.text).lineLimit(1)
                        Text(c.detail).font(.mhCaption).foregroundStyle(Palette.textMuted).lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
                .tag(c.id)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Palette.card)
    }

    private var isRuleCategory: Bool { !["artifacts", "system", "maintenance"].contains(selectedCategory) }

    @ViewBuilder private var categoryDetail: some View {
        VStack(spacing: 0) {
            if isRuleCategory { filterBar }
            detailList
        }
    }

    private var filterBar: some View {
        // One row when there is room. Otherwise the search field keeps its own row and the three
        // pickers share the next one, so none of them is squeezed into unusable widths at the
        // window’s minimum size.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchField
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 260)
                sizePicker
                agePicker
                sortPicker
                Spacer(minLength: 0)
                matchingMenu
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    searchField
                    Spacer(minLength: 8)
                    matchingMenu
                }
                HStack(spacing: 10) {
                    sizePicker
                    agePicker
                    sortPicker
                    Spacer(minLength: 0)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.textFaint)
            TextField("Search names and paths", text: $model.filter.text).textFieldStyle(.plain)
            if !model.filter.text.isEmpty {
                Button { model.filter.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textFaint)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Palette.card, in: SurfaceShape(cornerRadius: 6))
    }

    private var sizePicker: some View {
        Picker("Size", selection: $model.filter.minBytes) {
            Text("Any size").tag(UInt64(0))
            Text("Over 10 MB").tag(UInt64(10_000_000))
            Text("Over 100 MB").tag(UInt64(100_000_000))
            Text("Over 1 GB").tag(UInt64(1_000_000_000))
        }
        .labelsHidden().fixedSize()
    }

    private var agePicker: some View {
        Picker("Age", selection: $model.filter.minAgeDays) {
            Text("Any age").tag(0)
            Text("Unused 1 week").tag(7)
            Text("Unused 1 month").tag(30)
            Text("Unused 3 months").tag(90)
        }
        .labelsHidden().fixedSize()
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $model.filter.sort) {
            Text("Largest first").tag(ItemFilter.Sort.size)
            Text("By name").tag(ItemFilter.Sort.name)
            Text("Oldest first").tag(ItemFilter.Sort.oldest)
        }
        .labelsHidden().fixedSize()
    }

    @ViewBuilder private var matchingMenu: some View {
        if model.filter.isActive {
            Menu("Matching") {
                Button("Select All Matching") { model.setMatching(selected: true, in: filterScope) }
                Button("Deselect All Matching") { model.setMatching(selected: false, in: filterScope) }
                Divider()
                Button("Clear Filters") { model.filter = ItemFilter(sort: model.filter.sort) }
            }
            .fixedSize()
        }
    }

    private var filterScope: String? { selectedCategory == "all" ? nil : selectedCategory }

    @ViewBuilder private var detailList: some View {
        List {
            switch selectedCategory {
            case "all":
                AllItemsSection(model: model)
            case "artifacts":
                if let a = model.artifacts { artifactSection(a) } else { rootsOnlySection }
            case "system":
                systemSection
            case "maintenance":
                maintenanceSection
            default:
                if let group = model.groups.first(where: { $0.category == selectedCategory }) {
                    let shown = model.filter.isActive ? group.results.filter { !model.filter.apply($0).isEmpty } : group.results
                    Section(group.title) {
                        ForEach(shown) { r in RuleRow(model: model, result: r) }
                        if shown.isEmpty { Text("Nothing matches the filters.").foregroundStyle(Palette.textMuted) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var maintenanceSection: some View {
        Section("Maintenance") {
            if let docker = model.dockerUsage { DockerUsageRow(result: docker) }
            ForEach($model.tasks) { $row in
                HStack(alignment: .top) {
                    Toggle(isOn: $row.selected) { EmptyView() }
                        .labelsHidden()
                        .accessibilityLabel(row.task.title)
                        .disabled(!row.available)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.task.title).foregroundStyle(Palette.text)
                            RiskBadge(risk: row.task.risk)
                            if row.task.requiresRoot { Text("Needs Helper").font(.mhCaption2).foregroundStyle(Palette.textMuted) }
                        }
                        Text(row.task.description).font(.mhCaption).foregroundStyle(Palette.textMuted)
                        if !row.available {
                            Text(row.task.requiresRoot && row.task.isAvailable ? "Helper not enabled" : "Not applicable on this Mac")
                                .font(.mhCaption2).foregroundStyle(Theme.amber)
                        }
                    }
                }
                .opacity(row.available ? 1 : 0.5)
            }
        }
    }

    /// Spells out what happens to the selection, with real numbers.
    private var confirmMessage: String {
        var lines: [String] = []
        if model.selectedTrashBytes > 0 {
            lines.append(String(localized: "Move to the Trash: \(Fmt.bytes(Int64(clamping: model.selectedTrashBytes)))."))
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
        return lines.joined(separator: "\n")
    }

    private var systemSection: some View {
        Section {
            ForEach($model.systemRows) { $row in
                HStack(alignment: .top) {
                    Toggle(isOn: $row.selected) { EmptyView() }
                        .labelsHidden()
                        .accessibilityLabel(row.info.title)
                        .disabled(row.count == 0)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.info.title).foregroundStyle(Palette.text)
                            RiskBadge(risk: row.info.risk)
                            Text("Deleted directly").font(.mhCaption2).foregroundStyle(Palette.textMuted)
                            Text("Needs Helper").font(.mhCaption2).foregroundStyle(Palette.textMuted)
                        }
                        Text(row.info.description).font(.mhCaption).foregroundStyle(Palette.textMuted)
                        if let p = row.preview {
                            if let why = p.unavailable {
                                Text("Can’t read \(row.info.folder): \(why)").font(.mhCaption2).foregroundStyle(Theme.amber)
                            } else {
                                Text(p.count == 0 ? String(localized: "Nothing older than 30 days") : String(localized: "\(p.count) files"))
                                    .font(.mhCaption2).foregroundStyle(Palette.textFaint)
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
                    Text(e).font(.mhCaption).foregroundStyle(Theme.amber).lineLimit(1).truncationMode(.tail).help(e).textCase(nil)
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
                        .accessibilityLabel((art.path as NSString).lastPathComponent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((art.path as NSString).lastPathComponent + "  ·  " + (art.projectPath as NSString).lastPathComponent)
                            .foregroundStyle(Palette.text)
                        Text(art.path).font(.mhCaption2).foregroundStyle(Palette.textMuted).lineLimit(1).truncationMode(.head)
                    }
                    if art.recentlyUsed { Text("Recently used").font(.mhCaption2).foregroundStyle(Theme.amber) }
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
                .font(.mhCaption).foregroundStyle(Palette.textMuted)
            rootsEditor
        }
    }

    private var rootsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.artifactRoots, id: \.self) { root in
                HStack {
                    Image(systemName: "folder").foregroundStyle(Palette.textMuted)
                    Text(root).font(.mhCaption).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button { model.removeArtifactRoot(root) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .help("Stop looking for build artifacts in this folder")
                        .accessibilityLabel("Remove \(root) from project folders")
                }
            }
            Button("Add Project Folder…") { model.addArtifactRoot() }.controlSize(.small)
        }
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Cleaning Complete", systemImage: "checkmark.seal.fill").font(.mhTitle2).foregroundStyle(Theme.mint)
                Grid(alignment: .leading, verticalSpacing: 6) {
                    GridRow {
                        Text("Moved to Trash").foregroundStyle(Palette.textMuted)
                        Text(Fmt.bytes(Int64(clamping: model.trashedBytes)))
                            .monospacedDigit().bold().foregroundStyle(Palette.text).gridColumnAlignment(.trailing)
                    }
                    GridRow {
                        Text("Freed permanently").foregroundStyle(Palette.textMuted)
                        Text(Fmt.bytes(Int64(clamping: model.freedBytes)))
                            .monospacedDigit().bold().foregroundStyle(Palette.text).gridColumnAlignment(.trailing)
                    }
                    if !model.failures.isEmpty {
                        GridRow {
                            Text("Not processed").foregroundStyle(Palette.textMuted)
                            Text("\(model.failures.count) items").foregroundStyle(Theme.amber).gridColumnAlignment(.trailing)
                        }
                    }
                }
                .card(padding: 16)
                if model.trashedBytes > 0 {
                    HStack {
                        Text("Space used by items in the Trash is freed when you empty the Trash.").font(.mhCallout).foregroundStyle(Palette.textMuted)
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
                            Text(verbatim: "\(f.path): \(f.message ?? "")").font(.mhCaption).foregroundStyle(Palette.textMuted)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 12) {
                Text("All operations are logged in ~/Library/Logs/MacHelper/operations.jsonl").font(.mhCaption).foregroundStyle(Palette.textMuted)
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
                    Text("Skipped: \(reason)").font(.mhCaption).foregroundStyle(Palette.textMuted)
                } else if result.rule.needsFullDiskAccess {
                    Button("Needs Full Disk Access") { model.openFullDiskAccessSettings() }.buttonStyle(.link).font(.mhCaption)
                } else {
                    Text("Nothing to clean").font(.mhCaption).foregroundStyle(Palette.textFaint)
                }
            }
        } else {
            let items = model.filter.apply(result)
            DisclosureGroup(isExpanded: Binding(get: { expanded || model.filter.isActive }, set: { expanded = $0 })) {
                ForEach(items.prefix(300)) { c in
                    HStack {
                        Toggle(isOn: Binding(get: { c.selected }, set: { _ in model.toggleCandidate(rule: result.rule.id, path: c.path) })) {
                            EmptyView()
                        }
                        .labelsHidden()
                        .accessibilityLabel((c.path as NSString).lastPathComponent)
                        Text((c.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.text)
                        if let note = c.note { Text(note).font(.mhCaption2).foregroundStyle(Theme.amber) }
                        Spacer()
                        if let m = c.modified { Text(m, format: .relative(presentation: .named)).foregroundStyle(Palette.textFaint) }
                        Text(Fmt.bytes(Int64(clamping: c.size))).monospacedDigit().foregroundStyle(Palette.textMuted)
                    }
                    .font(.mhCallout)
                    .help(c.path)
                    .contextMenu { CandidateMenu(model: model, path: c.path) }
                }
            } label: {
                HStack(alignment: .top) {
                    Toggle(isOn: Binding(get: { model.isRuleSelected(result.rule.id) ?? false },
                                         set: { model.setRule(result.rule.id, selected: $0) })) { EmptyView() }
                        .labelsHidden()
                        .accessibilityLabel(result.rule.title)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(result.rule.title).foregroundStyle(Palette.text)
                            RiskBadge(risk: result.rule.risk)
                            Text(result.rule.action == .delete ? "Deleted directly" : "To Trash")
                                .font(.mhCaption2).foregroundStyle(Palette.textMuted)
                            if model.isRuleSelected(result.rule.id) == nil { Text("Partial").font(.mhCaption2).foregroundStyle(Palette.textMuted) }
                        }
                        Text(result.rule.description).font(.mhCaption).foregroundStyle(Palette.textMuted)
                    }
                    Spacer()
                    Text(Fmt.bytes(Int64(clamping: model.filter.isActive ? items.reduce(0) { $0 + $1.size } : result.totalSize)))
                        .monospacedDigit().foregroundStyle(Palette.text)
                }
            }
        }
    }
}

/// Every item from every rule in one list, so search, filters and sorting work across categories.
private struct AllItemsSection: View {
    let model: OptimizeModel

    var body: some View {
        let now = Date()
        let rows = model.plan?.results.flatMap { r in r.candidates.filter { model.filter.matches($0, ruleTitle: r.rule.title, now: now) }.map { (r.rule, $0) } } ?? []
        let sorted = model.filter.sorted(rows.map(\.1))
        let rules = Dictionary(rows.map { ($0.1.path, $0.0) }, uniquingKeysWith: { a, _ in a })
        Section {
            ForEach(sorted.prefix(500)) { c in
                HStack {
                    Toggle(isOn: Binding(get: { c.selected }, set: { _ in model.toggleCandidate(rule: c.ruleID, path: c.path) })) { EmptyView() }
                        .labelsHidden()
                        .accessibilityLabel((c.path as NSString).lastPathComponent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((c.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.text)
                        Text([rules[c.path]?.title, c.note].compactMap { $0 }.joined(separator: ", "))
                            .font(.mhCaption2).foregroundStyle(Palette.textMuted).lineLimit(1)
                    }
                    Spacer()
                    if let m = c.modified { Text(m, format: .relative(presentation: .named)).font(.mhCaption).foregroundStyle(Palette.textFaint) }
                    Text(Fmt.bytes(Int64(clamping: c.size))).monospacedDigit().foregroundStyle(Palette.textMuted)
                }
                .font(.mhCallout)
                .help(c.path)
                .contextMenu { CandidateMenu(model: model, path: c.path) }
            }
            if sorted.isEmpty { Text("Nothing matches the filters.").foregroundStyle(Palette.textMuted) }
        } header: {
            Text(sorted.count > 500 ? "\(sorted.count) items, showing the first 500" : "\(sorted.count) items")
        }
    }
}

private struct CandidateMenu: View {
    let model: OptimizeModel
    let path: String

    var body: some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        Divider()
        Button("Never Clean This") { model.exclude(path) }
    }
}

/// A one-line strip above the preview explaining why it may be incomplete.
private struct NoticeBar: View {
    let icon: String
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.amber)
            Text(text).font(.mhCallout).foregroundStyle(Palette.text).lineLimit(2)
            Spacer(minLength: 12)
            Button(action, action: perform).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Palette.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

/// The paths MacHelper never cleans: add files, folders or globs, or remove them again.
struct ExclusionsView: View {
    let model: OptimizeModel
    @Environment(\.dismiss) private var dismiss
    @State private var pattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Never Clean").font(.mhTitle2).foregroundStyle(Palette.text)
            Text("MacHelper skips these files and folders, and everything inside them, when cleaning, uninstalling and moving disk analysis items to the Trash. Right-click an item in the preview and choose Never Clean This to add it.")
                .font(.mhCallout).foregroundStyle(Palette.textMuted).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(model.exclusions, id: \.self) { e in
                    HStack {
                        Image(systemName: e.contains("*") || e.contains("?") ? "asterisk" : "folder").foregroundStyle(Palette.textMuted).frame(width: 16)
                        Text(e).font(.mhCallout).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button { model.removeExclusion(e) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Palette.textMuted)
                            .help("Clean this again")
                            .accessibilityLabel("Clean \(e) again")
                    }
                }
                if model.exclusions.isEmpty {
                    Text("Nothing excluded yet.").foregroundStyle(Palette.textMuted)
                }
            }
            .frame(height: 220)
            HStack {
                TextField("Path or pattern, e.g. ~/Library/Caches/com.example.*", text: $pattern)
                    .onSubmit(add)
                Button("Add", action: add).disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let e = model.exclusionError { Text(e).font(.mhCaption).foregroundStyle(Theme.rose) }
            VStack(alignment: .leading, spacing: 8) {
                Text("Saved in clean-whitelist.txt, also used by the command-line tool.")
                    .font(.mhCaption).foregroundStyle(Palette.textFaint).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Choose Files or Folders…") { model.addExclusionsFromPanel() }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.base)
    }

    private func add() {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        model.addExclusion(p)
        pattern = ""
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
            .font(.mhCaption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: SurfaceShape.capsule)
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
                    .font(.mhCaption).foregroundStyle(Palette.textMuted)
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
                .font(.mhCaption.monospacedDigit()).foregroundStyle(Palette.textMuted)
            case .failure(.engineNotRunning):
                Text("Docker is installed but its engine isn’t running. Start Docker Desktop or OrbStack, then rescan.")
                    .font(.mhCaption).foregroundStyle(Theme.amber)
            case .failure(.notInstalled):
                EmptyView()
            case .failure(.unreadable(let message)):
                Text("Couldn’t read Docker disk usage: \(message)").font(.mhCaption).foregroundStyle(Theme.amber).textSelection(.enabled)
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
