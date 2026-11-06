import CleanEngine
import SwiftUI

struct UpdatesView: View {
    @Bindable var model: UpdatesModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(section: .updates, subtitle: String(localized: "Apps you installed with Homebrew that have a newer version.")) {
                        Toggle("Include apps that update themselves", isOn: $model.includeSelfUpdating)
                            .toggleStyle(.checkbox).font(.mhCallout)
                            .disabled(model.phase == .checking || model.phase == .updating)
                            .help("Also list apps such as browsers that normally install their own updates")
                        IconButton(symbol: "arrow.clockwise", help: "Check Again") { Task { await model.check(refresh: true) } }
                            .disabled(model.phase == .checking || model.phase == .updating)
                    }
                    content
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }
            if !model.casks.isEmpty { bottomBar }
        }
        .task { if model.phase == .idle { await model.check() } }
        .confirmationDialog(confirmTitle, isPresented: $confirm, titleVisibility: .visible) {
            Button("Update") { Task { await model.update() } }
        } message: {
            Text(confirmMessage)
        }
    }

    @ViewBuilder private var content: some View {
        if model.brewMissing {
            PixelEmptyState(art: "px.empty.box", title: "Homebrew isn’t installed",
                            message: "This page updates apps installed with Homebrew (brew install --cask). Install Homebrew from brew.sh to use it.") {
                Link("Open brew.sh", destination: URL(string: "https://brew.sh")!)
            }
            .frame(maxWidth: .infinity).padding(.top, 40)
        } else if model.phase == .checking && model.casks.isEmpty {
            VStack(spacing: 12) {
                ScanningArt(art: "px.empty.scan")
                Text("Checking for updates…").font(.mhCallout).foregroundStyle(Palette.textMuted)
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
        } else {
            if let f = model.failure {
                Text("Homebrew couldn’t check for updates: \(f)").font(.mhCallout).foregroundStyle(Theme.amber).textSelection(.enabled)
            }
            summary
            if !model.casks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.casks.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                        CaskRow(model: model, cask: c)
                    }
                }
                .card(padding: 0)
            }
            let done = model.results.values.filter { r in r.ok && !model.casks.contains { $0.token == r.token } }.map(\.token).sorted()
            if !done.isEmpty {
                Label("Updated: \(done.joined(separator: ", "))", systemImage: "checkmark.circle")
                    .font(.mhCallout).foregroundStyle(Palette.textMuted)
            }
            Text("Updates run brew upgrade --cask for each app, one at a time, and are recorded in the operation history. Apps that are open are quit first and reopened afterwards.")
                .font(.mhCaption).foregroundStyle(Palette.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var summary: some View {
        let n = model.casks.count
        VStack(alignment: .leading, spacing: 4) {
            Text(n == 0 ? String(localized: "All Homebrew apps are up to date.") : String(localized: "\(n) apps have updates."))
                .font(.display(26)).foregroundStyle(Palette.text)
            if let d = model.lastChecked {
                Text("Checked \(d, format: .relative(presentation: .named))").font(.mhCaption).foregroundStyle(Palette.textMuted)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if let p = model.progress, let current = model.current {
                ProgressView().controlSize(.small)
                Text("Updating \(model.casks.first { $0.token == current }?.name ?? current) (\(p.done + 1) of \(p.total))…")
                    .font(.mhCallout).foregroundStyle(Palette.text)
            } else {
                Text("\(model.selectedCasks.count) of \(model.casks.filter(model.canUpdate).count) selected")
                    .font(Theme.smallNumeral).foregroundStyle(Palette.text)
            }
            Spacer(minLength: 12)
            Button(String(localized: "Update \(model.selectedCasks.count) Apps…")) { confirm = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedCasks.isEmpty || model.phase != .ready)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Palette.card)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var confirmTitle: String { String(localized: "Update \(model.selectedCasks.count) apps?") }

    private var confirmMessage: String {
        var lines = model.selectedCasks.map { "\($0.name): \($0.installedVersion) → \($0.currentVersion)" }
        let running = model.selectedCasks.filter { !model.runningApps($0).isEmpty }.map(\.name)
        if !running.isEmpty {
            lines.append("")
            lines.append(String(localized: "Open now, will be quit and reopened: \(running.joined(separator: ", ")). Save your work in them first."))
        }
        return lines.joined(separator: "\n")
    }
}

private struct CaskRow: View {
    let model: UpdatesModel
    let cask: OutdatedCask
    @State private var showOutput = false

    var body: some View {
        let result = model.results[cask.token]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { model.selected.contains(cask.token) && model.canUpdate(cask) },
                                     set: { on in if on { model.selected.insert(cask.token) } else { model.selected.remove(cask.token) } })) { EmptyView() }
                    .labelsHidden()
                    .disabled(!model.canUpdate(cask) || model.phase == .updating)
                Group {
                    if let icon = model.appIcon(cask) { Image(nsImage: icon).resizable() } else { Image(systemName: "shippingbox").resizable().scaledToFit().foregroundStyle(Palette.textFaint) }
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(cask.name).font(.mhBody.weight(.medium)).foregroundStyle(Palette.text)
                        if cask.name != cask.token { Text(cask.token).font(.mhCaption).foregroundStyle(Palette.textFaint) }
                    }
                    HStack(spacing: 8) {
                        Text(verbatim: "\(cask.installedVersion) → \(cask.currentVersion)").font(.mhCaption.monospacedDigit()).foregroundStyle(Palette.textMuted)
                        if cask.autoUpdates { tag(String(localized: "Updates itself")) }
                        if cask.pinned { tag(String(localized: "Pinned")) }
                        if !model.runningApps(cask).isEmpty { tag(String(localized: "Open")) }
                    }
                }
                Spacer(minLength: 8)
                status(result)
            }
            if cask.needsAdmin || result?.neededPassword == true {
                HStack(spacing: 8) {
                    Text("Its installer needs your administrator password, which only Terminal can ask for:")
                        .font(.mhCaption).foregroundStyle(Theme.amber)
                    Text(verbatim: cask.terminalCommand).font(.mhCaption.monospaced()).foregroundStyle(Palette.text).textSelection(.enabled)
                    Button("Copy") { model.copyCommand(cask) }.controlSize(.small)
                    Button("Open Terminal") { model.openTerminal() }.controlSize(.small)
                }
                .padding(.leading, 66)
            }
            if let r = result, !r.ok, !r.output.isEmpty {
                DisclosureGroup("What Homebrew said", isExpanded: $showOutput) {
                    Text(r.output).font(.mhCaption.monospaced()).foregroundStyle(Palette.textMuted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.mhCaption).padding(.leading, 66)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .opacity(model.canUpdate(cask) ? 1 : 0.75)
    }

    @ViewBuilder private func status(_ result: HomebrewUpdates.UpgradeOutcome?) -> some View {
        if model.current == cask.token {
            ProgressView().controlSize(.small)
        } else if let r = result, !r.ok {
            Label("Not updated", systemImage: "xmark.circle").font(.mhCaption).foregroundStyle(Theme.amber)
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.mhCaption2).foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(SurfaceShape.capsule.stroke(Palette.hairline))
    }
}
