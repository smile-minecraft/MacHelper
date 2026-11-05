import CleanEngine
import SwiftUI

struct StartupView: View {
    @Bindable var model: StartupModel
    @State private var removing: StartupItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("Only items whose program is missing", isOn: $model.onlyBroken).toggleStyle(.checkbox)
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await model.load() } }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            if model.loading && model.items.isEmpty {
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
                                    if scope.needsAdmin {
                                        Text("Needs an administrator to change").font(.caption).foregroundStyle(Palette.textFaint)
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
        .confirmationDialog("Remove \(removing?.label ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Stop and Move to Trash", role: .destructive) {
                if let item = removing { Task { await model.remove(item) } }
            }
        } message: {
            Text("The job is stopped and its plist goes to the Trash. The app that installed it may add it again.")
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
            if !item.scope.needsAdmin {
                Toggle("Enabled", isOn: Binding(get: { !item.isDisabled }, set: { on in Task { await model.setEnabled(item, on) } }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Show in Finder") { model.reveal(item.plistPath) }
            Button("Copy Label") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.label, forType: .string)
            }
            if !item.scope.needsAdmin {
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
