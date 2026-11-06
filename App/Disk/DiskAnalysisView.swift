import DiskScan
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct DiskAnalysisView: View {
    @Bindable var model: DiskAnalysisModel
    @State private var sideTab: SideTab = .contents
    @State private var confirmTrash = false
    @State private var dropTargeted = false

    enum SideTab: String, CaseIterable, Identifiable {
        case contents, largest, duplicates, changes
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let scannedAt = model.restoredAt { savedScanBanner(scannedAt) }
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 560)
        .quickLookPreview($model.previewURL)
        .task { model.restoreSavedScanIfNeeded() }
    }

    /// The result on screen is a saved one: it may not match the disk any more.
    private func savedScanBanner(_ scannedAt: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.mh(size: 14, weight: .semibold))
                .foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved scan from \(scannedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.mh(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text("This result may be out of date. Scan again to update it.")
                    .font(.mhCaption)
                    .foregroundStyle(Palette.textMuted)
                Text("Collecting, removing, and duplicate search are disabled for a saved scan.")
                    .font(.mhCaption2)
                    .foregroundStyle(Palette.textFaint)
            }
            Spacer()
            Button("Clear Saved Scan") { model.clearSavedScan() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.inset)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.target) {
                ForEach(model.targets) { t in Label(t.title, systemImage: t.symbol).tag(t) }
            }
            .labelsHidden()
            .frame(width: 220)
            .disabled(model.phase == .scanning)

            if model.phase == .scanning {
                Button("Stop") { model.cancel() }
            } else {
                Button(model.root == nil ? "Scan" : "Rescan") { model.scan() }
                    .keyboardShortcut("r", modifiers: .command)
            }

            Spacer()

            Picker("", selection: $model.mode) {
                Label("Sunburst", systemImage: "chart.pie").tag(DiskAnalysisModel.ChartMode.sunburst)
                Label("Treemap", systemImage: "square.grid.2x2").tag(DiskAnalysisModel.ChartMode.treemap)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
        .padding(10)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle where model.root == nil:
            PixelEmptyState(art: "px.empty.scan", title: "Disk Analysis",
                            message: "Choose a location to analyze, then click Scan. Scanning only reads; it never changes any files.") {
                Button("Scan \(model.target.title)") { model.scan() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        case .scanning:
            VStack(spacing: 14) {
                ScanningArt(art: "px.empty.scan")
                Text("Scanned \(model.progress.files.formatted()) files · \(Fmt.bytes(Int64(clamping: model.progress.bytes)))")
                    .font(.mhCallout).monospacedDigit().foregroundStyle(Palette.textMuted)
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Scan Failed", systemImage: "exclamationmark.triangle", description: Text(message))
        default:
            if let focus = model.focus { results(focus) }
        }
    }

    private func results(_ focus: DiskNode) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                breadcrumbs
                summary
                ZStack(alignment: .bottomLeading) {
                    switch model.mode {
                    case .sunburst: SunburstChart(model: model, focus: focus)
                    case .treemap: TreemapChart(model: model, focus: focus)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A saved scan cannot be collected from; the banner explains why, so the
                // collector hint would contradict the disabled actions.
                if !model.isShowingSavedScan {
                    Text(model.mode == .sunburst ? "Click a ring to open a folder, click the center to go up; right-click or drag items to the collector." : "Click a block to open its folder; right-click or drag items to the collector.")
                        .font(.mhCaption).foregroundStyle(Palette.textMuted)
                }
            }
            .padding(12)

            Divider()

            VStack(spacing: 0) {
                Picker("", selection: $sideTab) {
                    Text("Contents").tag(SideTab.contents)
                    Text("Largest").tag(SideTab.largest)
                    Text("Duplicates").tag(SideTab.duplicates)
                    Text("Changes").tag(SideTab.changes)
                }
                .pickerStyle(.segmented).labelsHidden().padding(8)
                switch sideTab {
                case .contents:
                    List { ForEach(Array(focus.children.prefix(60))) { node in row(node, total: focus.size) } }
                        .listStyle(.plain)
                case .largest:
                    largestFilters
                    List { ForEach(model.largestFiles(in: focus)) { node in row(node, total: focus.size) } }
                        .listStyle(.plain)
                case .duplicates:
                    DuplicatesList(model: model)
                case .changes:
                    ChangesList(model: model)
                }
                Divider()
                collector
            }
            .frame(width: 320)
        }
    }

    private var largestFilters: some View {
        HStack {
            Picker("Kind", selection: $model.kindFilter) {
                Text("All kinds").tag(FileKind?.none)
                ForEach(FileKind.allCases) { Text($0.title).tag(FileKind?.some($0)) }
            }
            Picker("Modified", selection: $model.olderThanDays) {
                Text("Any time").tag(Int?.none)
                ForEach([30, 90, 365, 730], id: \.self) { d in Text("Unchanged for \(d) days").tag(Int?.some(d)) }
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 8)
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { i, node in
                    if i > 0 { Image(systemName: "chevron.right").font(.mhCaption2).foregroundStyle(Palette.textFaint) }
                    Button(i == 0 ? node.path : node.name) { model.zoom(to: node) }
                        .buttonStyle(.plain)
                        .foregroundStyle(i == model.breadcrumbs.count - 1 ? .primary : .secondary)
                }
            }
            .font(.mhCallout)
        }
    }

    @ViewBuilder private var summary: some View {
        HStack(spacing: 14) {
            if let root = model.root {
                Text("Found \(Fmt.bytes(Int64(clamping: root.size))) in \(model.progress.files.formatted()) files, \(String(format: "%.1f", model.elapsed)) s")
            }
            if let v = model.volume {
                Text("Disk used \(Fmt.bytes(v.used)) of \(Fmt.bytes(v.total))")
                if v.purgeable > 0 { Text("Purgeable \(Fmt.bytes(v.purgeable))").help("Space macOS frees automatically when needed (mostly local Time Machine snapshots and system caches).") }
                if v.localSnapshots > 0 { Text("\(v.localSnapshots) local snapshots") }
            }
        }
        .font(.mhCaption).foregroundStyle(Palette.textMuted)
        if model.progress.cloudOnlyDirectories > 0 {
            HStack {
                Image(systemName: "icloud.slash").foregroundStyle(Theme.orange)
                Text("\(model.progress.cloudOnlyDirectories) cloud-only folders were skipped; their contents were not downloaded.")
            }
            .font(.mhCaption)
        }
        if model.progress.unreadableDirectories > model.progress.cloudOnlyDirectories {
            HStack {
                Image(systemName: "lock.fill").foregroundStyle(Theme.orange)
                Text("\(model.progress.unreadableDirectories - model.progress.cloudOnlyDirectories) folders couldn’t be read; the results are incomplete.")
                Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }.buttonStyle(.link)
            }
            .font(.mhCaption)
        }
    }

    private func row(_ node: DiskNode, total: UInt64) -> some View {
        HStack {
            Image(systemName: node.isDirectory ? (node.skippedCloudOnly ? "icloud.slash" : "folder.fill") : "doc")
                .foregroundStyle(node.skippedCloudOnly ? Theme.orange : node.isDirectory ? Theme.accent : .secondary)
                .help(node.skippedCloudOnly ? String(localized: "Only in the cloud; contents were not downloaded") : "")
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).lineLimit(1).truncationMode(.middle)
                if sideTab == .largest {
                    Text(node.parent?.path ?? "").font(.mhCaption2).foregroundStyle(Palette.textMuted).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            Text(Fmt.bytes(Int64(clamping: node.size))).monospacedDigit().foregroundStyle(Palette.textMuted)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if node.isDirectory { model.zoom(to: node) } else { model.quickLook(node) } }
        .contextMenu { NodeMenu(model: model, node: node) }
        .draggable(node.url)
    }

    // MARK: Collector

    private var collector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Collector", systemImage: "tray.full")
                    .font(.mhHeadline)
                Spacer()
                Text(Fmt.bytes(Int64(clamping: model.collectorSize))).monospacedDigit()
            }
            if model.collector.isEmpty {
                Text(model.isShowingSavedScan
                     ? LocalizedStringKey("Collecting is disabled for a saved scan. Scan again to update it.")
                     : LocalizedStringKey("Drag items you want to delete here, then move them to the Trash in one go."))
                    .font(.mhCaption).foregroundStyle(Palette.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 50)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.collector) { node in
                            HStack {
                                Text(node.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Fmt.bytes(Int64(clamping: node.size))).monospacedDigit().foregroundStyle(Palette.textMuted)
                                Button { model.removeFromCollector(node) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(Palette.textFaint)
                            }
                            .font(.mhCaption)
                        }
                    }
                }
                .frame(maxHeight: 120)
                Button("Move to Trash…") { confirmTrash = true }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isShowingSavedScan)
            }
            if let m = model.lastMessage { Text(m).font(.mhCaption2).foregroundStyle(Palette.textMuted) }
        }
        .padding(10)
        .background(dropTargeted && !model.isShowingSavedScan ? Theme.accent.opacity(0.15) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isShowingSavedScan else { return false }
            for u in urls { model.addToCollector(path: u.standardizedFileURL.path) }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .confirmationDialog("Move \(model.collector.count) items (\(Fmt.bytes(Int64(clamping: model.collectorSize)))) to the Trash?",
                            isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { Task { await model.trashCollector() } }
        } message: {
            Text("Items go to the Trash and can be restored from there. System and important personal folders are protected and never removed.")
        }
    }
}

extension FileKind {
    var title: String {
        switch self {
        case .video: String(localized: "Videos")
        case .image: String(localized: "Images")
        case .audio: String(localized: "Audio")
        case .archive: String(localized: "Archives")
        case .diskImage: String(localized: "Disk images and installers")
        case .application: String(localized: "Apps")
        case .document: String(localized: "Documents")
        case .developer: String(localized: "Developer files")
        case .other: String(localized: "Other")
        }
    }
}

private struct DuplicatesList: View {
    @Bindable var model: DiskAnalysisModel

    var body: some View {
        if let groups = model.duplicates {
            let total = groups.reduce(0) { $0 + $1.reclaimable }
            if let note = model.duplicatesMessage {
                Text(note).font(.mhCaption).foregroundStyle(Theme.orange)
            }
            Text("\(groups.count) groups · \(Fmt.bytes(Int64(clamping: total))) reclaimable")
                .font(.mhCaption).foregroundStyle(Palette.textMuted)
            List {
                ForEach(groups.prefix(200)) { g in
                    Section {
                        ForEach(Array(g.files.enumerated()), id: \.element.id) { i, f in
                            HStack {
                                Image(systemName: i == 0 ? "star.fill" : "doc.on.doc").foregroundStyle(i == 0 ? Color.yellow : .secondary)
                                    .help(i == 0 ? String(localized: "Oldest copy (suggested to keep)") : "")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((f.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text(Fmt.shortPath((f.path as NSString).deletingLastPathComponent)).font(.mhCaption2)
                                        .foregroundStyle(Palette.textMuted).lineLimit(1).truncationMode(.head)
                                }
                                if f.sharesStorage {
                                    Text("Clone").font(.mhCaption2).foregroundStyle(Theme.orange)
                                        .help(String(localized: "Shares storage with another copy; deleting it alone frees almost nothing."))
                                }
                            }
                            .contextMenu {
                                Button("Add to Collector") { model.addToCollector(path: f.path) }
                                if let node = model.node(atPath: f.path) {
                                    Button("Show in Finder") { model.revealInFinder(node) }
                                    Button("Quick Look") { model.quickLook(node) }
                                }
                            }
                            .draggable(URL(fileURLWithPath: f.path))
                        }
                    } header: {
                        HStack {
                            Text("\(Fmt.bytes(Int64(clamping: g.size))) × \(g.files.count)")
                            Spacer()
                            Button("Collect All but the Oldest") { model.collectDuplicates(g) }
                                .buttonStyle(.link).font(.mhCaption)
                                .disabled(g.reclaimable == 0)
                        }
                    }
                }
            }
            .listStyle(.plain)
        } else if model.isShowingSavedScan {
            VStack(spacing: 8) {
                Spacer()
                Text("Duplicate search is disabled for a saved scan. Scan again to update it.")
                    .font(.mhCaption).foregroundStyle(Palette.textMuted).multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity).padding()
        } else {
            VStack(spacing: 8) {
                Spacer()
                if let note = model.duplicatesMessage {
                    Text(note).font(.mhCaption).foregroundStyle(Theme.orange).multilineTextAlignment(.center)
                }
                if model.findingDuplicates {
                    ProgressView()
                    Text("Comparing file contents…").font(.mhCaption).foregroundStyle(Palette.textMuted)
                } else {
                    Text("Finds files of 1 MB or more with identical content in this scan.")
                        .font(.mhCaption).foregroundStyle(Palette.textMuted).multilineTextAlignment(.center)
                    Button("Find Duplicates") { Task { await model.findDuplicates() } }.buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity).padding()
        }
    }
}

private struct ChangesList: View {
    let model: DiskAnalysisModel

    var body: some View {
        if let since = model.changesSince {
            Text("Compared with the scan of \(since.formatted(date: .abbreviated, time: .shortened))")
                .font(.mhCaption).foregroundStyle(Palette.textMuted)
            if model.changes.isEmpty {
                Text("No folder changed by more than 50 MB.").font(.mhCallout).foregroundStyle(Palette.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.changes) { c in
                    HStack {
                        Image(systemName: c.delta > 0 ? "arrow.up.right" : "arrow.down.right")
                            .foregroundStyle(c.delta > 0 ? Theme.orange : .green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((c.path as NSString).lastPathComponent).lineLimit(1)
                            Text(c.before == nil ? String(localized: "New") : (c.after == nil ? String(localized: "Gone or now small") : Fmt.shortPath(c.path)))
                                .font(.mhCaption2).foregroundStyle(Palette.textMuted).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Text((c.delta > 0 ? "+" : "−") + Fmt.bytes(Int64(clamping: c.delta.magnitude))).monospacedDigit()
                            .foregroundStyle(c.delta > 0 ? Theme.orange : .green)
                    }
                    .contextMenu {
                        if let node = model.node(atPath: c.path) {
                            Button("Open Folder") { model.zoom(to: node) }
                            Button("Show in Finder") { model.revealInFinder(node) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        } else {
            Text("Scan the same location again later to see which folders grew or shrank.")
                .font(.mhCaption).foregroundStyle(Palette.textMuted).multilineTextAlignment(.center)
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
