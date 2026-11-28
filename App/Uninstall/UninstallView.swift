import CleanEngine
import SwiftUI

struct UninstallView: View {
    @Bindable var model: UninstallModel
    /// Shared with the details pane: its Uninstall button and the Delete key open the same dialog.
    @State private var confirmUninstall = false
    @State private var dropTargeted = false
    /// Half a screen narrows the app list so the leftover paths and Uninstall button keep room.
    @Environment(\.isCompactPage) private var compact

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
            if let notice = model.dropNotice { dropNoticeBar(notice) }
            ZStack {
                switch model.tab {
                case .apps:
                    // The search filters the app list only, so it leaves the toolbar with that tab.
                    appsTab
                        .searchable(text: $model.search, placement: .toolbar, prompt: Text("Search Apps"))
                        .transition(Motion.pageIn)
                case .orphans: OrphansTab(model: model).transition(Motion.pageIn)
                }
            }
            .frame(maxHeight: .infinity)
            .animatesStates(model.tab)
        }
        .animatesStateChanges(model.dropNotice)
        // Any app bundle can be dropped anywhere on the page, whichever tab is showing.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: AppUninstaller.isAppBundle) else { return false }
            return model.handleDrop(url)
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                ZStack {
                    SurfaceShape(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.accent.opacity(0.08))
                    SurfaceShape(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2)
                }
                .allowsHitTesting(false)
            }
        }
        .task { await model.loadApps() }
        // A dialog for one app must not carry over to the next one.
        .onChange(of: model.selectedAppID) { confirmUninstall = false }
        // The list reload sits in the window toolbar, beside the app search.
        .focusedSceneValue(\.pageCommands, pageCommands.withSearch(model.tab == .apps))
    }

    /// Reloads the tab on screen: the installed app list, or the leftovers of removed apps.
    private var pageCommands: PageCommands {
        switch model.tab {
        case .apps:
            PageCommands(refresh: PageCommand(id: "refresh", title: "Refresh", systemImage: "arrow.clockwise",
                                              isEnabled: !model.loadingApps && !model.refreshingApps) {
                Task { await model.loadApps(forceRefresh: true) }
            })
        case .orphans:
            PageCommands(refresh: PageCommand(id: "refresh", title: "Search Again", systemImage: "arrow.clockwise",
                                              isEnabled: !model.loadingOrphans) {
                Task { await model.loadOrphans() }
            })
        }
    }

    /// Says why a dropped bundle isn't opened, right under the tabs, so a drop that can't be taken
    /// doesn't look like nothing happened.
    private func dropNoticeBar(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.amber)
                .accessibilityHidden(true)
            Text(notice)
                .font(.mhCallout)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Palette.inset, in: SurfaceShape(cornerRadius: Theme.cardRadius, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 10)
        .transition(Motion.stateSwap)
    }

    private var appsTab: some View {
        let showsAppsLoading = (model.loadingApps || !model.hasLoadedApps) && model.apps.isEmpty
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if model.refreshingApps {
                        ProgressView().controlSize(.small).help("Updating the app list…")
                    }
                    Spacer(minLength: 0)
                    Picker("", selection: $model.sort) {
                        Text("Name").tag(UninstallModel.Sort.name)
                        Text("Size").tag(UninstallModel.Sort.size)
                        Text("Least Recently Used").tag(UninstallModel.Sort.lastUsed)
                    }
                    .labelsHidden().frame(width: 100)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
                ZStack {
                    if showsAppsLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
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
                        // The Delete key asks the same question as the Uninstall button.
                        .onDeleteCommand { if model.canUninstallSelected { confirmUninstall = true } }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Motion.fade, value: showsAppsLoading)
            }
            // Both panes give way at half a screen: the list keeps the app names readable and
            // the details keep the leftover paths and the Uninstall button on screen. Using a
            // fixed-divider HStack (like Optimize and Startup) avoids NSSplitView's multi-pass
            // width jumps during page and tab transitions.
            .frame(minWidth: 200, idealWidth: compact ? 220 : 300, maxWidth: compact ? 240 : 320)

            Rectangle().fill(Palette.hairline).frame(width: 1)

            ZStack {
                if let app = model.selectedApp {
                    AppDetail(model: model, app: app, confirm: $confirmUninstall)
                        .id(app.id)
                        .transition(.opacity)
                } else {
                    ScrollingCenter {
                        PixelEmptyState(art: "px.empty.box", title: "Choose an App to Uninstall",
                                        message: "MacHelper also finds the caches, settings and data it left behind, and you decide item by item what to delete.") {
                            Text("Or drag an app from Finder onto this window.")
                                .font(.mhCaption).foregroundStyle(Palette.textFaint)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            // A short cross-fade when another app is picked, so the details don't flash.
            .animation(Motion.fade, value: model.selectedAppID)
        }
    }
}

private struct AppDetail: View {
    @Bindable var model: UninstallModel
    let app: InstalledApp
    @Binding var confirm: Bool

    private var showsPlan: Bool {
        !model.loadingPlan && model.plan?.app.id == app.id
    }

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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Keep the spinner and the loaded leftover list inside their own ZStack so they
            // cross-fade in place without stacking vertically or shifting the app header above.
            ZStack {
                if model.loadingPlan {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else if let plan = model.plan, plan.app.id == app.id {
                    // Only this app's own plan: the page never lists another app's leftovers (and their
                    // sizes) under the app on screen, not even for the update between two selections.
                    VStack(alignment: .leading, spacing: 0) {
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
                        .actionBar {
                            if let m = model.message { Text(m).font(.mhCaption).foregroundStyle(Palette.textMuted).lineLimit(2) }
                            Spacer(minLength: 8)
                            Text("\(Fmt.bytes(Int64(clamping: plan.selectedSize))) selected").monospacedDigit().foregroundStyle(Palette.text)
                            Button("Uninstall…") { confirm = true }
                                .buttonStyle(.borderedProminent)
                                .disabled(!app.canUninstall || app.isRunning || plan.selectedSize == 0)
                        }
                        .confirmationDialog("Uninstall \(app.name)?", isPresented: $confirm, titleVisibility: .visible) {
                            Button("Move to Trash", role: .destructive) { Task { await model.uninstall() } }
                        } message: {
                            let systemCount = plan.systemItems.filter(model.systemSelection.contains).count
                            Text("The \(plan.items.filter(\.selected).count) selected items (\(Fmt.bytes(Int64(clamping: plan.selectedSize)))) will be moved to the Trash, where you can get them back. App Store apps may ask for an administrator password.")
                                + Text(systemCount > 0 ? "\n" + String(localized: "\(systemCount) system-level items are moved to the Trash by the Helper.") : "")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.fade, value: showsPlan)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct OrphansTab: View {
    @Bindable var model: UninstallModel
    @State private var confirm = false

    private enum ContentState: Equatable { case idle, loading, loaded }
    private var contentState: ContentState {
        if model.orphans != nil { return .loaded }
        return model.loadingOrphans ? .loading : .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("These items are named after a bundle ID whose app can no longer be found; for background items, the program they start no longer exists. Nothing is checked by default.")
                .font(.mhCallout).foregroundStyle(Palette.textMuted).fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(Palette.inset, in: SurfaceShape(cornerRadius: Theme.cardRadius, style: .continuous))
                .padding(16)
            ZStack {
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
                    // Delete asks the same question as the Move to Trash button: only when something
                    // is checked, since the button is disabled otherwise.
                    .onDeleteCommand { if model.selectedOrphanBytes > 0 { confirm = true } }
                    .actionBar {
                        if let m = model.message { Text(m).font(.mhCaption).foregroundStyle(Palette.textMuted) }
                        Spacer(minLength: 8)
                        Button("Search Again") { Task { await model.loadOrphans() } }
                        Button("Move to Trash…") { confirm = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.selectedOrphanBytes == 0)
                    }
                    .transition(.opacity)
                } else if model.loadingOrphans {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    Button("Find Leftovers of Removed Apps") { Task { await model.loadOrphans() } }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.fade, value: contentState)
        }
        .confirmationDialog("Move the selected leftovers (\(Fmt.bytes(Int64(clamping: model.selectedOrphanBytes)))) to the Trash?",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { Task { await model.removeSelectedOrphans() } }
        }
    }
}
