import Permissions
import SwiftUI

// MARK: - Status badge

/// A colored dot and the state in words. The words are what VoiceOver reads, so the color never
/// carries the meaning alone.
struct PermissionStatusBadge: View {
    let item: PermissionCenter.Item

    private var text: String {
        if item.requiresRelaunch { return String(localized: "Relaunch needed") }
        if item.id == .helper, item.state == .granted { return String(localized: "Running") }
        return item.state.label
    }

    private var color: Color {
        if item.requiresRelaunch { return Theme.amber }
        switch item.state {
        case .granted: return Theme.mint
        case .needsApproval: return Theme.amber
        case .denied: return Theme.rose
        case .notRequested: return item.isRequired ? Theme.amber : Palette.textMuted
        case .notApplicable, .checking: return Palette.textMuted
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if item.state == .checking {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.mhCaption.weight(.semibold))
                .foregroundStyle(item.state == .notApplicable ? Palette.textMuted : color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: SurfaceShape.capsule)
        .fixedSize()
        .contentTransition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Status: \(text)"))
    }
}

// MARK: - Primary button

/// The one button a row offers, with the explanation sheet handled by the caller.
struct PermissionActionButton: View {
    let item: PermissionCenter.Item
    var prominent = false
    var presentPrePrompt: (PermissionID) -> Void
    @State private var working = false

    var body: some View {
        if let action = PermissionFlow.primaryAction(for: item) {
            let button = Button {
                if action.needsPrePrompt {
                    presentPrePrompt(item.id)
                } else {
                    working = true
                    Task {
                        await PermissionFlow.shared.perform(action, for: item.id)
                        working = false
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if working || (item.id == .helper && HelperHealthMonitor.shared.isRepairing) {
                        ProgressView().controlSize(.small)
                    }
                    Text(action.title)
                }
            }
            .disabled(working)
            .help(PermissionInfo.info(for: item.id).title)
            if prominent && action != .turnOffAtLogin && action != .checkAgain {
                button.buttonStyle(.borderedProminent)
            } else {
                button
            }
        }
    }
}

// MARK: - Explanation before a system prompt

/// What MacHelper says before macOS asks: which feature needs the grant, what goes missing without
/// it, what it never reads, and exactly what appears next. Nothing is requested until Continue.
struct PermissionPrePromptSheet: View {
    let id: PermissionID
    /// Runs after Continue's request has finished, for screens that show the result themselves.
    var completed: (@MainActor () async -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var info: PermissionInfo { PermissionInfo.info(for: id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: PermissionSymbols.symbol(for: id))
                    .font(.mhTitle)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent.opacity(0.12), in: SurfaceShape(cornerRadius: Theme.cardRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PermissionPrePrompt.title(for: id))
                        .font(.mhTitle2.weight(.semibold))
                        .foregroundStyle(Palette.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(info.title).font(.mhCallout).foregroundStyle(Palette.textMuted)
                }
            }

            PermissionFacts(info: info)

            VStack(alignment: .leading, spacing: 8) {
                Text("What happens next")
                    .font(.mhCallout.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                PermissionStepList(steps: PermissionPrePrompt.steps(for: id))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    dismiss()
                    Task {
                        await PermissionFlow.shared.confirmPrePrompt(id)
                        await completed?()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(Palette.base)
    }
}

/// The three facts every permission carries, as labelled paragraphs.
struct PermissionFacts: View {
    let info: PermissionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            fact("Used by", symbol: "puzzlepiece.extension", text: info.purpose)
            fact("Without it", symbol: "minus.circle", text: info.withoutIt)
            fact("Never accessed", symbol: "hand.raised", text: info.neverAccessed)
        }
    }

    private func fact(_ title: LocalizedStringKey, symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.mhCaption)
                .foregroundStyle(Palette.textMuted)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.mhCaption.weight(.semibold)).foregroundStyle(Palette.textMuted)
                Text(text).font(.mhCallout).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The explanation's headline and the steps macOS takes after Continue.
enum PermissionPrePrompt {
    static func title(for id: PermissionID) -> String {
        switch id {
        case .helper: String(localized: "Before you install the Helper")
        case .accessibility: String(localized: "Before macOS asks about Accessibility")
        case .finderAutomation: String(localized: "Before macOS asks about Finder")
        case .notifications: String(localized: "Before macOS asks about notifications")
        default: PermissionInfo.info(for: id).title
        }
    }

    static func steps(for id: PermissionID) -> [String] {
        switch id {
        case .helper:
            [String(localized: "macOS adds the Helper to Login Items and shows a “Background Items Added” notification."),
             String(localized: "System Settings opens at Login Items & Extensions. Turn on MacHelper under “Allow in the Background” and enter your password."),
             String(localized: "A small guide stays beside System Settings and closes once MacHelper sees the Helper running.")]
        case .accessibility:
            [String(localized: "macOS may show an alert that MacHelper would like to control this computer. Choose Open System Settings, or close it."),
             String(localized: "In Privacy & Security → Accessibility, turn on the switch next to MacHelper."),
             String(localized: "Relaunch MacHelper when asked; macOS hands the grant only to a new copy.")]
        case .finderAutomation:
            [String(localized: "macOS asks whether MacHelper may control Finder. Click Allow."),
             String(localized: "If you choose Don’t Allow, you can change it later in Privacy & Security → Automation.")]
        case .notifications:
            [String(localized: "macOS shows a notification asking to allow MacHelper’s notifications. Click Allow; it may be under Options."),
             String(localized: "You can change the style or turn them off later in System Settings → Notifications.")]
        default:
            PermissionGuide.for(id).steps
        }
    }
}

enum PermissionSymbols {
    static func symbol(for id: PermissionID) -> String {
        switch id {
        case .helper: "lock.shield"
        case .fullDiskAccess: "internaldrive"
        case .accessibility: "accessibility"
        case .finderAutomation: "gearshape.2"
        case .finderExtension: "puzzlepiece.extension"
        case .notifications: "bell.badge"
        case .backgroundRecording: "waveform.path.ecg"
        case .autoCleanSchedule: "clock.arrow.circlepath"
        case .openAtLogin: "power"
        }
    }
}

// MARK: - Settings → Permissions

/// Every permission with its live state and the one button that moves it forward. Rows the current
/// setup needs come first; permissions no enabled feature uses sit at the bottom, dimmed.
struct PermissionsSettingsView: View {
    @Bindable private var center = PermissionCenter.shared
    @Bindable private var flow = PermissionFlow.shared
    @State private var expanded: Set<PermissionID> = []
    @State private var prePrompt: PermissionID?

    private var needed: [PermissionCenter.Item] { center.items.filter(\.isRequired) }
    private var optional: [PermissionCenter.Item] {
        center.items.filter { !$0.isRequired && $0.state != .notApplicable }
    }
    private var unused: [PermissionCenter.Item] {
        center.items.filter { !$0.isRequired && $0.state == .notApplicable }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    Text("MacHelper asks only for what a feature you use needs. Each row says what it unlocks, what goes missing without it and what it never reads.")
                        .settingsCaption()
                    if let error = center.lastActionError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .settingsCaption(Theme.rose)
                    }
                    if let error = flow.agentError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .settingsCaption(Theme.rose)
                    }
                }
                if !needed.isEmpty {
                    Section("Needed for your setup") { rows(needed) }
                }
                if !optional.isEmpty {
                    Section("Optional") { rows(optional) }
                }
                if !unused.isEmpty {
                    Section {
                        rows(unused).opacity(0.7)
                    } header: {
                        Text("Not needed right now")
                    } footer: {
                        Text("No feature you have turned on uses these. They move up when you turn one on.")
                            .settingsCaption()
                    }
                }
            }
            .formStyle(.grouped)
            .settingsSurface()
            .onAppear { applyFocus(proxy) }
            .onChange(of: flow.tabRequest) { applyFocus(proxy) }
        }
        .task { await PermissionCenter.shared.watch() }
        .task { await flow.followHelperApproval() }
        .sheet(item: $prePrompt) { id in PermissionPrePromptSheet(id: id) }
        .animation(Motion.stateChange, value: center.items.map(\.state))
    }

    @ViewBuilder private func rows(_ items: [PermissionCenter.Item]) -> some View {
        ForEach(items) { item in
            PermissionRow(item: item,
                          isExpanded: Binding(get: { expanded.contains(item.id) },
                                              set: { if $0 { expanded.insert(item.id) } else { expanded.remove(item.id) } }),
                          presentPrePrompt: { prePrompt = $0 })
                .id(item.id)
        }
    }

    /// Expands the row another screen asked for and starts its action when that was requested.
    private func applyFocus(_ proxy: ScrollViewProxy) {
        guard let id = flow.focus else { return }
        expanded.insert(id)
        flow.focus = nil
        withAnimation(Motion.stateChange) { proxy.scrollTo(id, anchor: .center) }
        if flow.pendingStart == id {
            flow.pendingStart = nil
            Task {
                // The first read may still be running when the tab opens from elsewhere.
                if center.item(id)?.state == .checking { await center.refresh() }
                // A reinstall is never started from a shortcut elsewhere; the row's button stays
                // the one place that repairs.
                guard let item = center.item(id), PermissionFlow.primaryAction(for: item) != .repairHelper else { return }
                flow.trigger(id) { prePrompt = $0 }
            }
        }
    }
}

/// One permission: name, state and purpose, the button on the right, and the three facts below
/// when expanded.
struct PermissionRow: View {
    let item: PermissionCenter.Item
    @Binding var isExpanded: Bool
    var presentPrePrompt: (PermissionID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: PermissionSymbols.symbol(for: item.id))
                    .font(.mhTitle3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.info.title)
                            .font(.mh(size: 13.5, weight: .semibold))
                            .foregroundStyle(Palette.text)
                        PermissionStatusBadge(item: item)
                    }
                    Text(item.info.purpose)
                        .settingsCaption()
                        .lineLimit(isExpanded ? nil : 1)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                PermissionActionButton(item: item, prominent: item.isRequired, presentPrePrompt: presentPrePrompt)
                Button {
                    withAnimation(Motion.stateChange) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.mhCaption.weight(.semibold))
                        .foregroundStyle(Palette.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide details" : "Show details")
                .accessibilityLabel(isExpanded ? "Hide details" : "Show details")
            }
            if isExpanded {
                PermissionFacts(info: item.info)
                    .padding(.leading, 34)
                    .padding(.top, 2)
                    .transition(Motion.stateSwap)
            }
        }
        .padding(.vertical, 2)
    }
}
