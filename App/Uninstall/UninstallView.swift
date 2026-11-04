import CleanEngine
import SwiftUI

struct UninstallView: View {
    @Bindable var model: UninstallModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                Text("App").tag(UninstallModel.Tab.apps)
                Text("Leftovers of Removed Apps").tag(UninstallModel.Tab.orphans)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 320).padding(10)
            Divider()
            switch model.tab {
            case .apps: appsTab
            case .orphans: OrphansTab(model: model)
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .task { await model.loadApps() }
    }

    private var appsTab: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search Apps", text: $model.search).textFieldStyle(.roundedBorder)
                    Picker("", selection: $model.sort) {
                        Text("Name").tag(UninstallModel.Sort.name)
                        Text("Size").tag(UninstallModel.Sort.size)
                        Text("Least Recently Used").tag(UninstallModel.Sort.lastUsed)
                    }
                    .labelsHidden().frame(width: 100)
                }
                .padding(8)
                if model.loadingApps && model.apps.isEmpty {
                    ProgressView().frame(maxHeight: .infinity)
                } else {
                    List(model.visibleApps, selection: $model.selectedAppID) { app in
                        HStack {
                            Image(nsImage: model.icon(for: app)).resizable().frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                Text(app.lastUsed.map { String(localized: "Last used \($0.formatted(date: .abbreviated, time: .omitted))") } ?? app.bundleID)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(Fmt.bytes(Int64(clamping: app.size))).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .opacity(app.canUninstall ? 1 : 0.5)
                        .tag(app.id)
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 330, maxWidth: 420)

            Group {
                if let app = model.selectedApp {
                    AppDetail(model: model, app: app)
                } else {
                    PixelEmptyState(art: "px.empty.box", title: "Choose an App to Uninstall",
                                    message: "MacHelper also finds the caches, settings and data it left behind, and you decide item by item what to delete.") { EmptyView() }
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AppDetail: View {
    @Bindable var model: UninstallModel
    let app: InstalledApp
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: model.icon(for: app)).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.title2.bold())
                    Text("\(app.version ?? "") · \(app.bundleID)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(app.path).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let reason = app.protectedReason {
                Label("Can’t uninstall: \(reason)", systemImage: "lock.fill").foregroundStyle(.secondary)
            } else if app.isRunning {
                HStack {
                    Label("\(app.name) is running. Quit it first.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Quit \(app.name)") { Task { await model.quitApp() } }
                }
            }

            if model.loadingPlan {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan = model.plan {
                Toggle("Also remove app data (Application Support, Containers, ~/.name: may contain your documents, settings or sign-in data)", isOn: $model.includeUserData)
                    .font(.callout)
                List {
                    ForEach(LeftoverKind.allCases, id: \.self) { kind in
                        let items = plan.items.filter { $0.kind == kind }
                        if !items.isEmpty {
                            Section(kind.title) {
                                ForEach(items) { item in
                                    HStack {
                                        Toggle(isOn: Binding(get: { item.selected }, set: { _ in model.toggle(item) })) { EmptyView() }
                                            .labelsHidden()
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(Fmt.shortPath(item.path)).lineLimit(1).truncationMode(.middle)
                                            Text(item.followsUserData && !item.kind.mayContainUserData
                                                 ? String(localized: "\(item.evidence.title); selected together with “Also remove app data”") : item.evidence.title)
                                                .font(.caption2)
                                                .foregroundStyle(item.needsConfirmation ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                        }
                                        Spacer()
                                        Text(Fmt.bytes(Int64(clamping: item.size))).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .contextMenu { Button("Show in Finder") { model.reveal(item.path) } }
                                }
                            }
                        }
                    }
                    if !plan.kept.isEmpty {
                        Section("Found but Kept") {
                            ForEach(plan.kept, id: \.self) { k in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Fmt.shortPath(k.path)).font(.caption)
                                    Text(k.reason).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !plan.systemItems.isEmpty {
                        Section("System Level (needs an administrator; remove manually)") {
                            ForEach(plan.systemItems, id: \.self) { p in
                                Text(p).font(.caption).foregroundStyle(.secondary)
                                    .contextMenu { Button("Show in Finder") { model.reveal(p) } }
                            }
                        }
                    }
                }
                HStack {
                    if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    Text("\(Fmt.bytes(Int64(clamping: plan.selectedSize))) selected").monospacedDigit()
                    Button("Uninstall…") { confirm = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!app.canUninstall || app.isRunning || plan.selectedSize == 0)
                }
                .confirmationDialog("Uninstall \(app.name)?", isPresented: $confirm, titleVisibility: .visible) {
                    Button("Move to Trash", role: .destructive) { Task { await model.uninstall() } }
                } message: {
                    Text("The \(plan.items.filter(\.selected).count) selected items (\(Fmt.bytes(Int64(clamping: plan.selectedSize)))) will be moved to the Trash, where you can get them back. App Store apps may ask for an administrator password.")
                }
            }
        }
        .padding(16)
    }
}

private struct OrphansTab: View {
    @Bindable var model: UninstallModel
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("These items are named after a bundle ID whose app can no longer be found; for background items, the program they start no longer exists. This is a guess: review each item before checking it. Nothing is checked by default.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let orphans = model.orphans {
                List {
                    ForEach(orphans) { item in
                        HStack {
                            Toggle(isOn: Binding(get: { item.selected }, set: { _ in model.toggleOrphan(item) })) { EmptyView() }
                                .labelsHidden()
                            Text(item.kind.title).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                            Text(Fmt.shortPath(item.path)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.bytes(Int64(clamping: item.size))).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contextMenu { Button("Show in Finder") { model.reveal(item.path) } }
                    }
                }
                HStack {
                    if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Search Again") { Task { await model.loadOrphans() } }
                    Button("Move to Trash…") { confirm = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedOrphanBytes == 0)
                }
                .confirmationDialog("Move the selected leftovers (\(Fmt.bytes(Int64(clamping: model.selectedOrphanBytes)))) to the Trash?",
                                    isPresented: $confirm, titleVisibility: .visible) {
                    Button("Move to Trash", role: .destructive) { Task { await model.removeSelectedOrphans() } }
                }
            } else {
                VStack(spacing: 10) {
                    if model.loadingOrphans { ProgressView() } else {
                        Button("Find Leftovers of Removed Apps") { Task { await model.loadOrphans() } }.buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
    }
}
