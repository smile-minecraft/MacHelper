import CleanEngine
import SwiftUI

/// Installs the `machelper` skill for AI agents (Claude Code, Codex): offered once on first launch
/// when an agent is found, and from Settings → General.
enum AgentSkillSetup {
    static let askedKey = "onboarding.agentSkill.asked"
    static var appCLI: String { Bundle.main.bundlePath + "/Contents/MacOS/machelper-cli" }

    /// `machelper` once the Terminal command is installed, with the app's copy as a fallback.
    static var command: (command: String, fallback: String?) {
        CommandLineToolRow.isInstalled ? ("machelper", appCLI) : (appCLI, nil)
    }

    static var detectedTargets: [AgentSkill.Target] { AgentSkill.targets().filter(\.detected) }

    static var shouldOffer: Bool {
        !CommandLine.arguments.contains { $0.hasPrefix("--snapshot") } && !UserDefaults.standard.bool(forKey: askedKey)
            && detectedTargets.contains { AgentSkill.state($0) == .notInstalled }
    }

    static func install(_ targets: [AgentSkill.Target]) throws {
        let c = command
        for t in targets { try AgentSkill.install(t, command: c.command, fallback: c.fallback) }
    }

    nonisolated static func refreshInstalled() {
        let c = CommandLineToolRow.isInstalled
            ? ("machelper", Bundle.main.bundlePath + "/Contents/MacOS/machelper-cli")
            : (Bundle.main.bundlePath + "/Contents/MacOS/machelper-cli", nil as String?)
        AgentSkill.refreshInstalled(command: c.0, fallback: c.1)
    }
}

/// First-launch question: install the skill so the user's AI agents can use MacHelper.
struct AgentSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = Set(AgentSkillSetup.detectedTargets.filter { AgentSkill.state($0) == .notInstalled }.map(\.id))
    @State private var linkCLI = !CommandLineToolRow.isInstalled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Let your AI agents use MacHelper").font(.mhTitle2).foregroundStyle(Palette.text)
            Text("MacHelper can add a skill to the coding agents on this Mac. With it, you can ask the agent things like “free up some space” or “why is my Mac hot?”, and it runs MacHelper’s command-line tool to check. It always shows you what it would remove and asks before removing anything.")
                .font(.mhCallout).foregroundStyle(Palette.textMuted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(AgentSkillSetup.detectedTargets) { t in
                    Toggle(isOn: Binding(get: { chosen.contains(t.id) }, set: { on in if on { chosen.insert(t.id) } else { chosen.remove(t.id) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).foregroundStyle(Palette.text)
                            Text(Fmt.shortPath(t.file.path)).font(.mhCaption.monospaced()).foregroundStyle(Palette.textFaint)
                        }
                    }
                    .disabled(AgentSkill.state(t) == .foreign)
                }
                if !CommandLineToolRow.isInstalled {
                    Toggle(isOn: $linkCLI) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Also add the machelper command to Terminal").foregroundStyle(Palette.text)
                            Text(verbatim: "~/.local/bin/machelper").font(.mhCaption.monospaced()).foregroundStyle(Palette.textFaint)
                        }
                    }
                }
            }
            .toggleStyle(.checkbox)
            Text("You can add or remove it later in Settings → General.").font(.mhCaption).foregroundStyle(Palette.textFaint)
            if let error { Text(error).font(.mhCaption).foregroundStyle(Theme.rose) }
            HStack {
                Spacer()
                Button("Not Now") { dismiss() }
                Button("Install") { install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Palette.base)
        .onDisappear { UserDefaults.standard.set(true, forKey: AgentSkillSetup.askedKey) }
    }

    private func install() {
        do {
            if linkCLI { try CommandLineToolRow.install() }
            try AgentSkillSetup.install(AgentSkillSetup.detectedTargets.filter { chosen.contains($0.id) })
            dismiss()
        } catch let e {
            error = e.localizedDescription
        }
    }
}

/// Settings → General: the skill for each agent, with Install / Remove.
struct AgentSkillRow: View {
    @State private var states: [String: AgentSkill.State] = [:]
    @State private var error: String?

    var body: some View {
        ForEach(AgentSkill.targets()) { t in
            LabeledContent(String(localized: "Skill for \(t.title)")) {
                HStack {
                    Text(label(t)).font(.mhCaption).foregroundStyle(Palette.textMuted)
                    switch states[t.id] ?? .notInstalled {
                    case .installed, .outdated: Button("Remove") { act { try AgentSkill.uninstall(t) } }
                    case .notInstalled: Button("Install") { act { try AgentSkillSetup.install([t]) } }
                    case .foreign: EmptyView()
                    }
                }
            }
        }
        if let error { Text(error).settingsCaption(Theme.rose) }
        Text("Lets Claude Code or Codex check and clean up this Mac through the machelper command. It previews first and asks before removing anything.")
            .settingsCaption()
            .onAppear(perform: reload)
    }

    private func label(_ t: AgentSkill.Target) -> String {
        switch states[t.id] ?? .notInstalled {
        case .installed: String(localized: "Installed")
        case .outdated: String(localized: "Will update on next launch")
        case .foreign: String(localized: "Another skill named machelper is there; left alone")
        case .notInstalled: t.detected ? String(localized: "Not installed") : String(localized: "Agent not found")
        }
    }

    private func act(_ f: () throws -> Void) {
        error = nil
        do { try f() } catch let e { error = e.localizedDescription }
        reload()
    }

    private func reload() {
        states = Dictionary(uniqueKeysWithValues: AgentSkill.targets().map { ($0.id, AgentSkill.state($0)) })
    }
}
