import CleanEngine
import SwiftUI
import Theming

// MARK: - 1. Welcome

struct OnboardingWelcomeStep: View {
    private struct Pillar: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
    }

    private var pillars: [Pillar] {
        [Pillar(id: "monitor", icon: "px.monitor", title: onboardingText("System Monitor"),
                detail: onboardingText("CPU, GPU, memory, temperatures and power, live in the menu bar.")),
         Pillar(id: "disk", icon: "px.disk", title: onboardingText("Disk Analysis & Cleanup"),
                detail: onboardingText("See what fills your disk and clear caches and leftovers safely.")),
         Pillar(id: "fans", icon: "px.fans", title: onboardingText("Fan Control"),
                detail: onboardingText("Quiet or cool: fan curves that switch by themselves.")),
         Pillar(id: "agent", icon: "px.mascot", title: onboardingText("AI Agent & CLI"),
                detail: onboardingText("Let Claude Code or Codex check and tidy your Mac."))]
    }

    var body: some View {
        VStack(spacing: 14) {
            SlimeMascot(mood: .init(level: .good, reaction: .singleTap), cell: 4)
                .accessibilityLabel(onboardingText("MacHelper’s slime waving hello"))
                .onboardingAppear(0)
            VStack(spacing: 6) {
                Text(onboardingText("Welcome to MacHelper"))
                    .font(.display(26, weight: .bold))
                    .foregroundStyle(Palette.text)
                Text(onboardingText("Everything your Mac needs, right in your menu bar — local-first and free."))
                    .font(.mhBody)
                    .foregroundStyle(Palette.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onboardingAppear(1)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(pillars.enumerated()), id: \.element.id) { index, pillar in
                    HStack(alignment: .top, spacing: 12) {
                        PixelIcon(name: pillar.icon, size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pillar.title).font(.mhCallout.weight(.semibold)).foregroundStyle(Palette.text)
                            Text(pillar.detail).font(.mhCaption).foregroundStyle(Palette.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                    .surface()
                    .accessibilityElement(children: .combine)
                    .onboardingAppear(2 + index)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

// MARK: - 2. Personalize

struct OnboardingPersonalizeStep: View {
    @Bindable var model: OnboardingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingHeadline(title: onboardingText("Choose your experience"),
                               subtitle: onboardingText("Everything here applies right away, so the window behind is your preview. Change it anytime in Settings."))
            HStack(spacing: 12) {
                OnboardingChoiceCard(selected: model.mode == .simple, action: { set(.simple) }) {
                    modeCard(icon: "px.overview", title: onboardingText("Simple"),
                             points: [onboardingText("Everyday essentials"),
                                      onboardingText("Plain-language health and cleanup"),
                                      onboardingText("Fewer pages, less jargon")])
                }
                OnboardingChoiceCard(selected: model.mode == .advanced, action: { set(.advanced) }) {
                    modeCard(icon: "px.monitor", title: onboardingText("Advanced"),
                             points: [onboardingText("Every chart and live graph"),
                                      onboardingText("Fan curves and startup items"),
                                      onboardingText("Technical details everywhere")])
                }
            }

            Text(onboardingText("Look")).font(.mhCaption.weight(.semibold)).foregroundStyle(Palette.textMuted)
                .padding(.top, 2)
            HStack(spacing: 12) {
                OnboardingChoiceCard(selected: model.preset == .standard, action: { model.apply(.standard) }) {
                    lookCard(preview: LookPreview(pixel: false), title: onboardingText("Standard"),
                             detail: onboardingText("Instrument panel: calm, rounded, follows Light and Dark."))
                }
                OnboardingChoiceCard(selected: model.preset == .pixelRetro, action: { model.apply(.pixelRetro) }) {
                    lookCard(preview: LookPreview(pixel: true), title: onboardingText("Pixel Retro"),
                             detail: onboardingText("Game-style pixel corners, colors and font."))
                }
            }
            if model.preset == nil {
                Text(onboardingText("You’re using a custom look. Picking one here replaces it."))
                    .font(.mhCaption).foregroundStyle(Palette.textFaint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(onboardingText("Open at login")).font(.mhCallout.weight(.medium)).foregroundStyle(Palette.text)
                        Text(onboardingText("Start quietly in the menu bar when you log in."))
                            .font(.mhCaption).foregroundStyle(Palette.textMuted)
                    }
                }
                .toggleStyle(.switch)
                if let error = model.loginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.mhCaption).foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        }
    }

    private func set(_ mode: AppearanceSettings.Mode) {
        withAnimation(Motion.snappy) { model.mode = mode }
    }

    private func modeCard(icon: String, title: String, points: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PixelIcon(name: icon, size: 26)
                Text(title).font(.display(16)).foregroundStyle(Palette.text)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(points, id: \.self) { point in
                    Label {
                        Text(point).font(.mhCaption).foregroundStyle(Palette.textMuted)
                    } icon: {
                        Image(systemName: "checkmark").font(.mhCaption.weight(.bold)).foregroundStyle(Theme.mint)
                    }
                }
            }
        }
    }

    private func lookCard(preview: LookPreview, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.mhCallout.weight(.semibold)).foregroundStyle(Palette.text)
                Text(detail).font(.mhCaption).foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A thumbnail of each look: rounded card with a ring, or a notched card with pixel blocks.
private struct LookPreview: View {
    let pixel: Bool

    var body: some View {
        var shape = SurfaceShape(cornerRadius: 8)
        shape.pixel = pixel
        return ZStack {
            shape.fill(Palette.inset)
            if pixel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Aa").font(.custom(ThemeStore.pixelFontName, size: 13)).foregroundStyle(Palette.text)
                    PixelBlocks(fraction: 0.6, color: Theme.mint, track: Palette.text.opacity(0.12), block: 4, gap: 1)
                        .frame(width: 34, height: 6)
                }
            } else {
                ZStack {
                    Circle().stroke(Palette.text.opacity(0.12), lineWidth: 4)
                    Circle().trim(from: 0, to: 0.62).stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 26, height: 26)
            }
        }
        .overlay(shape.stroke(Palette.stroke, lineWidth: pixel ? 2 : 1))
        .frame(width: 52, height: 44)
        .accessibilityHidden(true)
    }
}

// MARK: - 3. Menu bar tour

struct OnboardingTourStep: View {
    @Bindable var model: OnboardingFlowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingHeadline(title: onboardingText("MacHelper lives in your menu bar"),
                               subtitle: onboardingText("Your Mac’s vitals are always one click away, even with the window closed."))
            HStack(alignment: .top, spacing: 18) {
                menuBarMock
                    .frame(width: 290)
                VStack(alignment: .leading, spacing: 12) {
                    tip(symbol: "cursorarrow.click.2", title: onboardingText("Click for the quick panel"),
                        detail: onboardingText("CPU, GPU, memory, SSD, network, battery and power, each on its own tab."))
                    tip(symbol: "menubar.arrow.up.rectangle", title: onboardingText("Close the window, keep the help"),
                        detail: onboardingText("MacHelper keeps running quietly in the menu bar. Quit it from the panel."))
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "command")
                            .font(.mhTitle3)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(onboardingText("Jump between pages")).font(.mhCallout.weight(.semibold)).foregroundStyle(Palette.text)
                                OnboardingKeyCap(text: "⌘1")
                                Text(verbatim: "–").font(.mhCaption).foregroundStyle(Palette.textFaint)
                                OnboardingKeyCap(text: "⌘9")
                            }
                            Text(onboardingText("Works anywhere in the main window, like the sidebar."))
                                .font(.mhCaption).foregroundStyle(Palette.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(onboardingText("Show in the menu bar")).font(.mhCaption.weight(.semibold)).foregroundStyle(Palette.textMuted)
                    Spacer()
                    Text(onboardingText("More options in Settings → Menu Bar"))
                        .font(.mhCaption).foregroundStyle(Palette.textFaint)
                }
                OnboardingFlowLayout(spacing: 8) {
                    ForEach(model.menuBarModules) { module in
                        let on = model.isInMenuBar(module)
                        Button {
                            withAnimation(Motion.snappy) { model.setInMenuBar(module, !on) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(on ? Theme.accent : Palette.textFaint)
                                Text(module.title).foregroundStyle(on ? Palette.text : Palette.textMuted)
                            }
                            .font(.mhCallout)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(on ? Theme.accent.opacity(0.14) : Palette.card, in: SurfaceShape.capsule)
                            .overlay(SurfaceShape.capsule.strokeBorder(on ? Theme.accent.opacity(0.5) : Palette.stroke, lineWidth: 1))
                            .contentShape(SurfaceShape.capsule)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
        .onAppear {
            guard !reduceMotion, !Motion.reduced else { return }
            withAnimation(Motion.shimmer(duration: 1.1)) { pulse = true }
        }
    }

    /// A drawn menu bar with MacHelper's items and the quick panel dropping from it.
    private var menuBarMock: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "apple.logo").font(.mhCaption).foregroundStyle(Palette.textMuted)
                Spacer()
                Text(verbatim: "CPU 12%").font(.mh(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent.opacity(pulse ? 0.30 : 0.14), in: SurfaceShape(cornerRadius: 4))
                Text(verbatim: "MEM 48%").font(.mh(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Palette.text)
                Image(systemName: "wifi").font(.mhCaption).foregroundStyle(Palette.textMuted)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Palette.raised, in: SurfaceShape(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Array(PanelPage.allCases.prefix(4).enumerated()), id: \.element) { index, page in
                        Text(page.title)
                            .font(.mh(size: 9, weight: index == 0 ? .bold : .regular))
                            .foregroundStyle(index == 0 ? Palette.text : Palette.textMuted)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(index == 0 ? Theme.accent.opacity(0.18) : Color.clear, in: SurfaceShape.capsule)
                    }
                }
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(verbatim: "12").font(.display(22).monospacedDigit()).foregroundStyle(Palette.text)
                    Text(verbatim: "%").font(.mhCaption).foregroundStyle(Palette.textMuted)
                }
                AreaSparkline(values: [0.18, 0.12, 0.22, 0.15, 0.3, 0.2, 0.14, 0.26, 0.12, 0.17, 0.12], maxValue: 0.5, color: Theme.cyan)
                    .frame(height: 38)
            }
            .padding(10)
            .frame(width: 210, alignment: .leading)
            .surface()
            .padding(.trailing, 36)
        }
        .padding(10)
        .background(Palette.inset, in: SurfaceShape(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(onboardingText("Illustration: the MacHelper item in the menu bar opens a panel with live readings."))
    }

    private func tip(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.mhTitle3)
                .foregroundStyle(Theme.accent)
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.mhCallout.weight(.semibold)).foregroundStyle(Palette.text)
                Text(detail).font(.mhCaption).foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 4. Permissions

struct OnboardingPermissionsStep: View {
    @Bindable var model: OnboardingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                OnboardingHeadline(title: onboardingText("Two optional permissions"),
                                   subtitle: onboardingText("Both are optional — skip anytime and MacHelper still works. Each one unlocks a little more."))
                Spacer(minLength: 0)
                SlimeMascot(mood: .init(level: .good, holdsSign: !allSet,
                                        reaction: model.helperResponding ? .helperConnected : nil), cell: 2)
                    .accessibilityHidden(true)
            }

            permissionCard(
                icon: "px.disk",
                title: onboardingText("Full Disk Access"),
                unlocks: onboardingText("Lets MacHelper measure and clean Mail downloads, other apps’ caches and protected folders, so disk analysis sees everything."),
                status: model.fullDiskAccess ? .on(onboardingText("On")) : .off(onboardingText("Off")),
                hint: model.fullDiskAccess ? nil : onboardingText("Turn on MacHelper in Privacy & Security → Full Disk Access. MacHelper notices by itself.")
            ) {
                if !model.fullDiskAccess {
                    Button(onboardingText("Open System Settings")) { FullDiskAccess.openSettings() }
                }
            }

            permissionCard(
                icon: "px.fans",
                title: onboardingText("Privileged Helper"),
                unlocks: onboardingText("A small helper with administrator rights for fan control, cleaning system caches and logs, and reading system processes."),
                status: helperBadge,
                hint: helperHint
            ) {
                if !model.helperInstalled {
                    Button(onboardingText("Install Helper")) { model.installHelper() }
                        .disabled(model.helperWorking)
                } else if !model.helperResponding {
                    Button(onboardingText("Open Login Items")) { HelperClient.shared.openLoginItemsSettings() }
                }
            }

            if let error = model.helperError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.mhCaption).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var allSet: Bool { model.fullDiskAccess && model.helperResponding }

    private var helperBadge: OnboardingStatusBadge.Status {
        if model.helperResponding { return .on(onboardingText("Running")) }
        switch model.helperStatus {
        case .enabled: return .waiting(onboardingText("Starting…"))
        case .requiresApproval: return .waiting(onboardingText("Waiting for approval"))
        default: return .off(onboardingText("Not installed"))
        }
    }

    private var helperHint: String? {
        if model.helperResponding { return nil }
        switch model.helperStatus {
        case .requiresApproval:
            return onboardingText("In General → Login Items & Extensions, turn on MacHelper under “Allow in the Background”.")
        case .enabled:
            return onboardingText("Allowed. MacHelper is checking that the Helper answers.")
        default:
            return onboardingText("macOS adds it to Login Items; nothing runs until you allow it.")
        }
    }

    private func permissionCard(icon: String, title: String, unlocks: String, status: OnboardingStatusBadge.Status,
                                hint: String?, @ViewBuilder actions: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PixelIcon(name: icon, size: 24)
                Text(title).font(.mhTitle3.weight(.semibold)).foregroundStyle(Palette.text)
                Pill(text: onboardingText("Optional"), color: Palette.textMuted)
                Spacer()
                OnboardingStatusBadge(state: status)
            }
            Text(unlocks).font(.mhCallout).foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 10) {
                if let hint {
                    Text(hint).font(.mhCaption).foregroundStyle(Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                actions()
            }
        }
        .card()
        .animation(Motion.standard, value: status)
    }
}

// MARK: - 5. AI agents and the command line

struct OnboardingAgentStep: View {
    @Bindable var model: OnboardingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OnboardingHeadline(title: onboardingText("Power up your AI agents"),
                               subtitle: onboardingText("Add the machelper skill and ask Claude Code or Codex things like “free up some space” or “why is my Mac hot?”."))

            VStack(alignment: .leading, spacing: 10) {
                if model.detectedAgents.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        PixelIcon(name: "px.empty.box", size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(onboardingText("No AI coding agents found on this Mac"))
                                .font(.mhCallout.weight(.semibold)).foregroundStyle(Palette.text)
                            Text(onboardingText("That’s fine. Install Claude Code or Codex later, then add the skill in Settings → General."))
                                .font(.mhCaption).foregroundStyle(Palette.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ForEach(model.agentTargets) { target in agentRow(target) }
                    if !model.commandLineInstalled {
                        Toggle(isOn: $model.linkCommandLine) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(onboardingText("Also add the machelper command to Terminal")).font(.mhCallout).foregroundStyle(Palette.text)
                                Text(verbatim: "~/.local/bin/machelper").font(.mhCaption.monospaced()).foregroundStyle(Palette.textFaint)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    HStack(spacing: 10) {
                        if model.agentJustInstalled, model.agentError == nil {
                            Label(onboardingText("Skill installed"), systemImage: "checkmark.circle.fill")
                                .font(.mhCallout.weight(.medium)).foregroundStyle(Theme.mint)
                                .transition(.opacity)
                        }
                        if let error = model.agentError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.mhCaption).foregroundStyle(Theme.rose)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(onboardingText("Install Skill")) {
                            withAnimation(Motion.fade) { model.installSkills() }
                        }
                        .disabled(model.installableChosen.isEmpty)
                    }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 6) {
                commandLine("machelper report --json", comment: onboardingText("redacted diagnostics for your agent"))
                commandLine("machelper clean", comment: onboardingText("previews first; add --yes to apply"))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.inset, in: SurfaceShape(cornerRadius: Theme.cardRadius))
            .accessibilityElement(children: .combine)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(Theme.mint)
                Text(onboardingText("Local-first privacy: scans, history and reports stay on your Mac. Optional anonymous telemetry can be reviewed in Settings anytime."))
                    .font(.mhCaption).foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func agentRow(_ target: AgentSkill.Target) -> some View {
        let state = model.agentState(target)
        let installable = model.canInstall(target)
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { installable && model.chosenAgents.contains(target.id) },
                                 set: { model.toggleAgent(target, $0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.title).font(.mhCallout.weight(.medium))
                        .foregroundStyle(target.detected ? Palette.text : Palette.textMuted)
                    Text(Fmt.shortPath(target.file.path)).font(.mhCaption.monospaced()).foregroundStyle(Palette.textFaint)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!installable)
            Spacer()
            agentBadge(target, state)
        }
    }

    @ViewBuilder private func agentBadge(_ target: AgentSkill.Target, _ state: AgentSkill.State) -> some View {
        switch state {
        case .installed: OnboardingStatusBadge(state: .on(onboardingText("Installed")))
        case .outdated: OnboardingStatusBadge(state: .waiting(onboardingText("Update ready")))
        case .foreign:
            OnboardingStatusBadge(state: .waiting(onboardingText("Another skill is there; left alone")))
        case .notInstalled:
            OnboardingStatusBadge(state: .off(target.detected ? onboardingText("Not installed") : onboardingText("Not found")))
        }
    }

    private func commandLine(_ command: String, comment: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "$").foregroundStyle(Palette.textFaint)
            Text(verbatim: command).foregroundStyle(Palette.text).textSelection(.enabled)
            Text(verbatim: "# " + comment).foregroundStyle(Palette.textFaint).lineLimit(1)
        }
        .font(.mhCaption.monospaced())
    }
}

// MARK: - 6. Ready

struct OnboardingReadyStep: View {
    @Bindable var model: OnboardingFlowModel
    var finish: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            SlimeMascot(mood: .init(level: .good, reaction: .cleanupFinished), cell: 4)
                .accessibilityLabel(onboardingText("MacHelper’s slime celebrating"))
                .onboardingAppear(0)
            VStack(spacing: 4) {
                Text(onboardingText("You’re all set!")).font(.display(24, weight: .bold)).foregroundStyle(Palette.text)
                Text(onboardingText("Here’s how MacHelper is set up. Click any item to change it."))
                    .font(.mhCallout).foregroundStyle(Palette.textMuted)
            }
            .onboardingAppear(1)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                summary(icon: "px.overview", title: onboardingText("Mode"), step: .personalize,
                        state: .on(model.mode == .simple ? onboardingText("Simple") : onboardingText("Advanced")))
                summary(icon: "px.disk", title: onboardingText("Full Disk Access"), step: .permissions,
                        state: model.fullDiskAccess ? .on(onboardingText("On")) : .off(onboardingText("Off")))
                summary(icon: "px.fans", title: onboardingText("Helper"), step: .permissions,
                        state: model.helperResponding ? .on(onboardingText("Running"))
                            : model.helperInstalled ? .waiting(onboardingText("Waiting for approval")) : .off(onboardingText("Not set up")))
                summary(icon: "px.mascot", title: onboardingText("Agent Skill"), step: .agentCli, state: skillState)
            }
            .onboardingAppear(2)

            HStack(spacing: 10) {
                quickAction(onboardingText("Open Overview"), icon: "px.overview", to: .overview)
                quickAction(onboardingText("Run First Health Check"), icon: "px.health", to: .health)
                quickAction(onboardingText("Explore Disk Space"), icon: "px.disk", to: .disk)
            }
            .onboardingAppear(3)
        }
        .frame(maxWidth: .infinity)
        .onAppear { model.reloadAgents() }
    }

    private var skillState: OnboardingStatusBadge.Status {
        if model.skillInstalledAnywhere { return .on(onboardingText("Installed")) }
        return model.detectedAgents.isEmpty ? .off(onboardingText("No agents found")) : .off(onboardingText("Not installed"))
    }

    private func summary(icon: String, title: String, step: OnboardingStep, state: OnboardingStatusBadge.Status) -> some View {
        Button {
            model.move(to: step)
        } label: {
            HStack(spacing: 10) {
                PixelIcon(name: icon, size: 22)
                Text(title).font(.mhCallout.weight(.medium)).foregroundStyle(Palette.text)
                Spacer(minLength: 6)
                OnboardingStatusBadge(state: state)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .surface()
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(onboardingText(format: "Change %@", title))
    }

    private func quickAction(_ title: String, icon: String, to destination: OnboardingFlowModel.Destination) -> some View {
        Button {
            model.open(destination)
            finish()
        } label: {
            VStack(spacing: 6) {
                PixelIcon(name: icon, size: 26)
                Text(title).font(.mhCallout.weight(.semibold)).foregroundStyle(Palette.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .padding(.vertical, 6)
            .surface(Theme.accent.opacity(0.10))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Shared pieces

struct OnboardingHeadline: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.display(20, weight: .bold)).foregroundStyle(Palette.text)
            Text(subtitle).font(.mhCallout).foregroundStyle(Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A selectable card: an accent border and check mark when chosen.
struct OnboardingChoiceCard<Content: View>: View {
    let selected: Bool
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .surface(selected ? Theme.accent.opacity(0.10) : Palette.card)
                .overlay {
                    SurfaceShape(cornerRadius: Theme.cardRadius)
                        .strokeBorder(selected ? Theme.accent : (hovered ? Palette.stroke : Color.clear), lineWidth: selected ? 2 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.mhTitle3)
                        .foregroundStyle(selected ? Theme.accent : Palette.textFaint)
                        .padding(10)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(Motion.hover) { hovered = h } }
        .animation(Motion.snappy, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A colored dot and a word: on (mint), waiting (amber) or off (muted).
struct OnboardingStatusBadge: View {
    enum Status: Equatable {
        case on(String), waiting(String), off(String)
    }

    let state: Status

    private var text: String {
        switch state { case .on(let t), .waiting(let t), .off(let t): t }
    }

    private var color: Color {
        switch state {
        case .on: Theme.mint
        case .waiting: Theme.amber
        case .off: Palette.textMuted
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.mhCaption.weight(.semibold)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: SurfaceShape.capsule)
        .contentTransition(.opacity)
    }
}

struct OnboardingKeyCap: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.mh(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Palette.raised, in: SurfaceShape(cornerRadius: 4))
            .overlay(SurfaceShape(cornerRadius: 4).strokeBorder(Palette.stroke, lineWidth: 1))
    }
}

/// Lays out chips left to right, wrapping to new rows.
struct OnboardingFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Content of a page arrives in a short cascade; with Reduce Motion it is simply there.
private struct OnboardingAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        let still = reduceMotion || Motion.reduced
        content
            .opacity(shown || still ? 1 : 0)
            .offset(y: shown || still ? 0 : 8)
            .onAppear {
                guard !still else { return }
                withAnimation(Motion.entrance(delay: 0.05 + Double(index) * 0.06)) { shown = true }
            }
    }
}

extension View {
    fileprivate func onboardingAppear(_ index: Int) -> some View { modifier(OnboardingAppear(index: index)) }
}
