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
            .pickerStyle(.segmented).labelsHidden()
            .frame(width: 340)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
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
                HStack(spacing: 10) {
                    TextField("Search Apps", text: $model.search).textFieldStyle(.roundedBorder)
                    if model.refreshingApps {
                        ProgressView().controlSize(.small).help("Updating the app list…")
                    }
                    Picker("", selection: $model.sort) {
                        Text("Name").tag(UninstallModel.Sort.name)
                        Text("Size").tag(UninstallModel.Sort.size)
                        Text("Least Recently Used").tag(UninstallModel.Sort.lastUsed)
                    }
                    .labelsHidden().frame(width: 100)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
                if model.loadingApps && model.apps.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.visibleApps, selection: $model.selectedAppID) { app in
                        HStack {
                            Image(nsImage: model.icon(for: app)).resizable().frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1).foregroundStyle(Palette.text)
                                Text(app.lastUsed.map { String(localized: "Last used \($0.formatted(date: .abbreviated, time: .omitted))") } ?? app.bundleID)
                                    .font(.mhCaption2).foregroundStyle(Palette.textMuted).lineLimit(1)
                            }
                            Spacer()
                            Text(Fmt.bytes(Int64(clamping: app.size))).font(.mhCaption).monospacedDigit().foregroundStyle(Palette.textMuted)
                        }
                        .opacity(app.canUninstall ? 1 : 0.5)
                        .tag(app.id)
                    }
                    .scrollContentBackground(.hidden)
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: model.icon(for: app)).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.mhTitle2.bold()).foregroundStyle(Palette.text)
                        Text("\(app.version ?? "") · \(app.bundleID)").font(.mhCaption).foregroundStyle(Palette.textMuted).textSelection(.enabled)
                        Text(app.path).font(.mhCaption2).foregroundStyle(Palette.textFaint).lineLimit(1).truncationMode(.middle)
                            .help(app.path)
                    }
                }
                if let reason = app.protectedReason {
                    Label("Can’t uninstall: \(reason)", systemImage: "lock.fill").foregroundStyle(Palette.textMuted)
                } else if app.isRunning {
                    HStack {
                        Label("\(app.name) is running. Quit it first.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                        Button("Quit \(app.name)") { Task { await model.quitApp() } }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if model.loadingPlan {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan = model.plan {
                Toggle("Also remove app data (Application Support, Containers, ~/.name: may contain your documents, settings or sign-in data)", isOn: $model.includeUserData)
                    .font(.mhCallout)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
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
                                            Text(Fmt.shortPath(item.path)).lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.text)
                                            Text(item.followsUserData && !item.kind.mayContainUserData
                                                 ? String(localized: "\(item.evidence.title); selected together with “Also remove app data”") : item.evidence.title)
                                                .font(.mhCaption2)
                                                .foregroundStyle(item.needsConfirmation ? AnyShapeStyle(Theme.orange) : AnyShapeStyle(Palette.textMuted))
                                        }
                                        Spacer()
                                        Text(Fmt.bytes(Int64(clamping: item.size))).monospacedDigit().foregroundStyle(Palette.textMuted)
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
                                    Text(Fmt.shortPath(k.path)).font(.mhCaption).foregroundStyle(Palette.text)
                                    Text(k.reason).font(.mhCaption2).foregroundStyle(Palette.textMuted)
                                }
                            }
                        }
                    }
                    if !plan.systemItems.isEmpty {
                        Section {
                            ForEach(plan.systemItems, id: \.self) { p in
                                HStack(spacing: 8) {
                                    Toggle(isOn: Binding(get: { model.systemSelection.contains(p) }, set: { _ in model.toggleSystem(p) })) { EmptyView() }
                                        .labelsHidden().disabled(!model.helperEnabled)
                                    Text(p).font(.mhCaption).foregroundStyle(model.helperEnabled ? Palette.text : Palette.textMuted)
                                        .lineLimit(1).truncationMode(.middle).help(p)
                                    Spacer(minLength: 4)
                                    if !UninstallModel.isStrongSystemMatch(p, bundleID: app.bundleID) {
                                        Text("Matched by name").font(.mhCaption2).foregroundStyle(Theme.amber)
                                    }
                                }
                                .contextMenu { Button("Show in Finder") { model.reveal(p) } }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("System Level")
                                Text(model.helperEnabled
                                     ? "Checked items are moved to your Trash by the Helper, so you can put them back. Items matched only by name are left unchecked; check them only if they clearly belong to this app."
                                     : "Enable the Helper in Settings to move these to the Trash; until then remove them manually.")
                                    .font(.mhCaption).foregroundStyle(Palette.textMuted).textCase(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                HStack(spacing: 12) {
                    if let m = model.message { Text(m).font(.mhCaption).foregroundStyle(Palette.textMuted).lineLimit(2) }
                    Spacer(minLength: 8)
                    Text("\(Fmt.bytes(Int64(clamping: plan.selectedSize))) selected").monospacedDigit().foregroundStyle(Palette.text)
                    Button("Uninstall…") { confirm = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!app.canUninstall || app.isRunning || plan.selectedSize == 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Palette.card)
                .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
                .confirmationDialog("Uninstall \(app.name)?", isPresented: $confirm, titleVisibility: .visible) {
                    Button("Move to Trash", role: .destructive) { Task { await model.uninstall() } }
                } message: {
                    let systemCount = plan.systemItems.filter(model.systemSelection.contains).count
                    Text("The \(plan.items.filter(\.selected).count) selected items (\(Fmt.bytes(Int64(clamping: plan.selectedSize)))) will be moved to the Trash, where you can get them back. App Store apps may ask for an administrator password.")
                        + Text(systemCount > 0 ? "\n" + String(localized: "\(systemCount) system-level items are moved to the Trash by the Helper.") : "")
                }
            } else {
                Spacer()
            }
        }
    }
}

private struct OrphansTab: View {
    @Bindable var model: UninstallModel
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("These items are named after a bundle ID whose app can no longer be found; for background items, the program they start no longer exists. Nothing is checked by default.")
                .font(.mhCallout).foregroundStyle(Palette.textMuted).fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(Palette.inset, in: SurfaceShape(cornerRadius: Theme.cardRadius, style: .continuous))
                .padding(16)
            if let orphans = model.orphans {
                List {
                    ForEach(orphans) { item in
                        HStack {
                            Toggle(isOn: Binding(get: { item.selected }, set: { _ in model.toggleOrphan(item) })) { EmptyView() }
                                .labelsHidden()
                            Text(item.kind.title).font(.mhCaption).foregroundStyle(Palette.textMuted).frame(width: 90, alignment: .leading)
                            Text(Fmt.shortPath(item.path)).lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.text)
                            Spacer()
                            Text(Fmt.bytes(Int64(clamping: item.size))).monospacedDigit().foregroundStyle(Palette.textMuted)
                        }
                        .contextMenu { Button("Show in Finder") { model.reveal(item.path) } }
                    }
                }
                .scrollContentBackground(.hidden)
                HStack(spacing: 12) {
                    if let m = model.message { Text(m).font(.mhCaption).foregroundStyle(Palette.textMuted) }
                    Spacer(minLength: 8)
                    Button("Search Again") { Task { await model.loadOrphans() } }
                    Button("Move to Trash…") { confirm = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedOrphanBytes == 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Palette.card)
                .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            } else {
                VStack(spacing: 10) {
                    if model.loadingOrphans { ProgressView() } else {
                        Button("Find Leftovers of Removed Apps") { Task { await model.loadOrphans() } }.buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog("Move the selected leftovers (\(Fmt.bytes(Int64(clamping: model.selectedOrphanBytes)))) to the Trash?",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { Task { await model.removeSelectedOrphans() } }
        }
    }
}
