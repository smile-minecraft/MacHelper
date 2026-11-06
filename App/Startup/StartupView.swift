import CleanEngine
import SwiftUI

struct StartupView: View {
    @Bindable var model: StartupModel
    @State private var removing: StartupItem?
    @State private var disablingDaemon: StartupItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("View", selection: $model.tab) {
                    Text("Launch Agents").tag(StartupModel.Tab.launchd)
                    Text("Login & Background Items").tag(StartupModel.Tab.background)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                if model.tab == .launchd {
                    Toggle("Only items whose program is missing", isOn: $model.onlyBroken).toggleStyle(.checkbox)
                } else {
                    Toggle("Show disabled", isOn: $model.showDisabledBackground).toggleStyle(.checkbox)
                }
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    Task { if model.tab == .launchd { await model.load() } else { await model.loadBackground() } }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            if model.tab == .background {
                BackgroundItemsList(model: model)
            } else if model.loading && model.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(StartupItem.Scope.allCases, id: \.self) { scope in
                        let group = model.visible.filter { $0.scope == scope }
                        if !group.isEmpty {
                            Section {
                                ForEach(group) { item in row(item) }
                            } header: {
                                HStack(spacing: 8) {
                                    Text(scope.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Palette.textMuted)
                                    if let note = note(for: scope) {
                                        Text(note).font(.caption).foregroundStyle(Palette.textFaint)
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            HStack(spacing: 12) {
                if let m = model.message { Text(m).font(.caption).foregroundStyle(Theme.orange).lineLimit(2) }
                Spacer(minLength: 8)
                Text("Background items that apps register themselves are managed in Login Items.")
                    .font(.caption).foregroundStyle(Palette.textMuted)
                Button("Open Login Items") { model.openLoginItems() }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.card)
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }
        .frame(minWidth: 680, minHeight: 480)
        .task { await model.load() }
        .task(id: model.tab) { if model.tab == .background && model.backgroundGroups.isEmpty { await model.loadBackground() } }
        .confirmationDialog("Remove \(removing?.label ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Stop and Move to Trash", role: .destructive) {
                if let item = removing { Task { await model.remove(item) } }
            }
        } message: {
            Text("The job is stopped and its plist goes to the Trash. The app that installed it may add it again.")
        }
        .confirmationDialog("Disable \(disablingDaemon?.label ?? "")?", isPresented: Binding(get: { disablingDaemon != nil }, set: { if !$0 { disablingDaemon = nil } }),
                            titleVisibility: .visible) {
            Button("Disable") {
                if let item = disablingDaemon { Task { await model.setEnabled(item, false) } }
            }
        } message: {
            Text("This system daemon is stopped for all users and won’t start again until you enable it here. The app that installed it may stop working properly (for example its updater, VPN or network helper). The plist isn’t changed or removed.")
        }
    }

    private func note(for scope: StartupItem.Scope) -> String? {
        switch scope {
        case .userAgent: nil
        case .systemAgent: String(localized: "Switching affects only your account; can’t be removed")
        case .systemDaemon: model.helperEnabled
            ? String(localized: "Switched by the Helper for all users; can’t be removed")
            : String(localized: "Enable the Helper in Settings to switch these")
        }
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: model.icon(for: item)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.ownerName ?? item.label).bold().lineLimit(1).foregroundStyle(Palette.text)
                    StateBadge(item: item)
                    if item.programMissing {
                        Label("Program missing", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(Theme.orange)
                    }
                }
                if item.ownerName != nil {
                    Text(item.label).font(.caption).foregroundStyle(Palette.textMuted).textSelection(.enabled)
                }
                Text(item.commandLine).font(.caption2.monospaced()).foregroundStyle(Palette.textFaint).lineLimit(1).truncationMode(.middle)
                    .help(item.commandLine)
                Text(schedule(item)).font(.caption2).foregroundStyle(Palette.textMuted)
            }
            Spacer()
            if !item.isProtected {
                Toggle("Enabled", isOn: Binding(get: { !item.isDisabled }, set: { on in
                    if !on && item.scope == .systemDaemon { disablingDaemon = item } else { Task { await model.setEnabled(item, on) } }
                }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(!model.canToggle(item))
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Show in Finder") { model.reveal(item.plistPath) }
            Button("Copy Label") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.label, forType: .string)
            }
            if item.scope.canRemove {
                Divider()
                Button("Remove…", role: .destructive) { removing = item }
            }
        }
    }

    private func schedule(_ item: StartupItem) -> String {
        var parts: [String] = []
        if item.runAtLoad { parts.append(String(localized: "Starts at login")) }
        if item.keepAlive { parts.append(String(localized: "Kept running")) }
        if let s = item.interval { parts.append(String(localized: "Every \(Duration.seconds(s).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))")) }
        return parts.isEmpty ? String(localized: "Starts on demand") : parts.joined(separator: " · ")
    }
}

private struct StateBadge: View {
    let item: StartupItem
    var body: some View {
        let (text, color): (String, Color) =
            if item.isDisabled { (String(localized: "Disabled"), Palette.textMuted) }
            else if item.pid != nil { (String(localized: "Running"), Theme.mint) }
            else if item.isLoaded { (String(localized: "Loaded"), Theme.blue) }
            else { (String(localized: "Not loaded"), Palette.textMuted) }
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Read-only view of the Background Task Management list (System Settings → Login Items).
private struct BackgroundItemsList: View {
    let model: StartupModel

    var body: some View {
        if model.loadingBackground && model.backgroundGroups.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.backgroundError, model.backgroundGroups.isEmpty {
            Text("Couldn’t read the login items list: \(error)")
                .font(.callout).foregroundStyle(Theme.amber).textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else {
            List {
                Section {
                    ForEach(model.visibleBackgroundGroups) { group in GroupRow(group: group) }
                } header: {
                    Text("What macOS has registered to run at login or in the background, including items apps add themselves. This list is read-only; change it in Login Items.")
                        .font(.caption).foregroundStyle(Palette.textMuted).textCase(nil)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct GroupRow: View {
    let group: BackgroundItemGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(group.title).bold().foregroundStyle(Palette.text).lineLimit(1)
                if let developer = group.parent?.developerName, developer != group.title {
                    Text(developer).font(.caption).foregroundStyle(Palette.textMuted).lineLimit(1)
                }
                if !group.enabled {
                    Text("Off").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Palette.textMuted.opacity(0.15), in: Capsule()).foregroundStyle(Palette.textMuted)
                }
            }
            ForEach(group.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(kindLabel(item.kind)).font(.caption2.bold()).foregroundStyle(Palette.textMuted).frame(width: 96, alignment: .leading)
                    Text(item.displayName).font(.caption).foregroundStyle(item.isActive ? Palette.text : Palette.textMuted)
                    if item.uid != Int(getuid()) { Text("All users").font(.caption2).foregroundStyle(Palette.textFaint) }
                    if item.enabled && !item.allowed { Text("Not allowed").font(.caption2).foregroundStyle(Theme.amber) }
                    else if !item.enabled { Text("Disabled").font(.caption2).foregroundStyle(Palette.textMuted) }
                    Spacer(minLength: 4)
                    if let path = item.executablePath ?? item.url {
                        Text(path).font(.caption2.monospaced()).foregroundStyle(Palette.textFaint)
                            .lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(group.enabled ? 1 : 0.6)
    }

    private func kindLabel(_ kind: BackgroundItem.Kind) -> String {
        switch kind {
        case .loginItem: String(localized: "Login item")
        case .agent, .legacyAgent: String(localized: "Agent")
        case .daemon, .legacyDaemon: String(localized: "Daemon")
        case .backgroundTask: String(localized: "Background task")
        case .app, .developer, .other: String(localized: "Other")
        }
    }
}
