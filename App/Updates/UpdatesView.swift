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
                            .disabled(model.phase == .checking || model.phase == .updating || model.isRefreshingIndex)
                            .help("Also list apps such as browsers that normally install their own updates")
                        IconButton(symbol: "arrow.clockwise", help: "Check Again") { Task { await model.check(refresh: true) } }
                            .disabled(model.phase == .checking || model.phase == .updating || model.isRefreshingIndex)
                    }
                    content
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }
            if !model.casks.isEmpty { bottomBar }
        }
        // The previous list stays on screen while the check runs, so re-opening the page shows the
        // previous result and replaces it when Homebrew answers.
        .task { await model.check() }
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
                // The page can stay open for days; keep "last result from …" honest as time passes.
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Homebrew couldn’t check for updates: \(f)")
                            .font(.mhCallout).foregroundStyle(Theme.amber).textSelection(.enabled)
                        if let d = model.lastChecked {
                            Text("Showing the last result from \(relative(d, at: context.date)).")
                                .font(.mhCaption).foregroundStyle(Palette.textMuted)
                        }
                    }
                }
            }
            if model.lastChecked != nil || model.failure == nil {
                summary
            } else if model.showsFreshnessWithoutSummary {
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        freshness(at: context.date)
                    }
                }
            }
            if let notice = model.detailNotice {
                switch notice {
                case .detailsFailed(let f):
                    Text("Homebrew couldn’t read app details: \(f). These apps can only be updated in Terminal.")
                        .font(.mhCaption).foregroundStyle(Theme.amber).textSelection(.enabled)
                case .missingDetails(let tokens):
                    Text("Homebrew didn’t return details for: \(tokens.joined(separator: ", ")). These apps can only be updated in Terminal.")
                        .font(.mhCaption).foregroundStyle(Theme.amber).textSelection(.enabled)
                case .notReconfirmedAfterRefresh:
                    Text("Homebrew’s index may have changed, but the new list couldn’t be read. These are the previous results and can only be updated in Terminal.")
                        .font(.mhCaption).foregroundStyle(Theme.amber).textSelection(.enabled)
                }
            }
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
        // The page can stay open for days. SwiftUI only re-evaluates a body when state changes, so
        // the freshness decision and every relative date are recomputed on a minute schedule. The
        // decision itself is `model.headline(at:)`, shared with the tests.
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(headline(at: context.date)).font(.display(26)).foregroundStyle(Palette.text)
                freshness(at: context.date)
            }
        }
    }

    private func headline(at now: Date) -> String {
        switch model.headline(at: now) {
        case .notChecked:
            return String(localized: "Not checked yet.")
        case .allUpToDate:
            return String(localized: "All Homebrew apps are up to date.")
        case .noUpdates(let date):
            if let date {
                return String(localized: "No updates in Homebrew’s index from \(relative(date, at: now)).")
            }
            return String(localized: "No updates in Homebrew’s index (its age is unknown).")
        case .updates(let n):
            return String(localized: "\(n) apps have updates.")
        }
    }

    /// Says whether the list is the first result from the existing catalog or the refreshed one.
    @ViewBuilder private func freshness(at now: Date) -> some View {
        if model.detailsPending {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if model.willRefresh {
                    Text("First result; updating Homebrew’s index…")
                } else {
                    Text("First result; checking app details…")
                }
            }
            .font(.mhCaption).foregroundStyle(Palette.textMuted)
        } else if model.isRefreshingIndex {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if model.phase == .checking || model.lastChecked == nil {
                    Text("Updating Homebrew’s index…")
                } else if let d = model.indexUpdatedAt {
                    Text("First result; Homebrew’s index is from \(relative(d, at: now)). Updating it now…")
                } else {
                    Text("First result. Updating Homebrew’s index…")
                }
            }
            .font(.mhCaption).foregroundStyle(Palette.textMuted)
        } else if model.phase == .checking && !model.casks.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            }
            .font(.mhCaption).foregroundStyle(Palette.textMuted)
        } else if model.indexRefreshed {
            // Show when the index was actually updated. The app can stay open for days, so a fixed
            // "just now" would keep claiming a freshness the catalog no longer has.
            if let d = model.indexRefreshedAt {
                if model.failure != nil && model.lastChecked != nil {
                    Text("Homebrew’s index was updated \(relative(d, at: now)), but this list is from before that update.")
                        .font(.mhCaption).foregroundStyle(Palette.textMuted)
                } else {
                    Text("Homebrew’s index was updated \(relative(d, at: now)).")
                        .font(.mhCaption).foregroundStyle(Palette.textMuted)
                }
            } else {
                Text("Homebrew’s index was updated, but its time is unavailable.")
                    .font(.mhCaption).foregroundStyle(Palette.textMuted)
            }
        } else if let d = model.indexUpdatedAt {
            Text("Homebrew’s repository was last fetched \(relative(d, at: now)).")
                .font(.mhCaption).foregroundStyle(Palette.textMuted)
        } else {
            Text("Homebrew’s index age is unknown.")
                .font(.mhCaption).foregroundStyle(Palette.textMuted)
        }
        // A failed explicit refresh must be visible even while the first list's details are still
        // being read; otherwise an offline update looks like it succeeded until info finishes.
        if let f = model.refreshFailure {
            Text("Couldn’t update Homebrew’s index: \(f)")
                .font(.mhCaption).foregroundStyle(Theme.amber).textSelection(.enabled)
        }
        if let w = model.refreshWarning {
            Text("Homebrew reported: \(w)")
                .font(.mhCaption).foregroundStyle(Theme.amber).textSelection(.enabled)
        }
        if !model.isRefreshingIndex, let d = model.lastChecked {
            Text("Checked \(relative(d, at: now))").font(.mhCaption).foregroundStyle(Palette.textMuted)
        }
    }

    private func relative(_ date: Date, at now: Date) -> String {
        UpdatesFreshness.relative(date, to: now)
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
        if let warning = model.refreshWarning {
            // A cached fallback is not a failure, but the user must see it before confirming an
            // update whose versions may come from an older catalog.
            lines.append("")
            lines.append(String(localized: "Homebrew reported: \(warning)"))
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
                                     set: { model.setSelected(cask.token, $0) })) { EmptyView() }
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "\(cask.name), \(cask.installedVersion) to \(cask.currentVersion)"))
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
                        if model.unconfirmed.contains(cask.token) {
                            tag(model.detailsPending
                                ? String(localized: "Reading details…")
                                : model.detailNotice == .notReconfirmedAfterRefresh
                                    ? String(localized: "Not reconfirmed")
                                    : String(localized: "Details unavailable"))
                        }
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
