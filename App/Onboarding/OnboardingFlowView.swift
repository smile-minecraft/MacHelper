import SwiftUI

/// The welcome guide: six short, skippable pages in one sheet. It replaces the three separate
/// first-launch sheets (Full Disk Access, Helper, agent skill) and opens again from Help → Welcome
/// Guide. Every choice it offers is applied at once, so the main window behind it is the preview.
struct OnboardingFlowView: View {
    /// Closes the sheet; the presenter marks the guide as seen.
    var finish: () -> Void
    @State private var model: OnboardingFlowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 680, height: 520)

    init(start: OnboardingStep = .welcome, finish: @escaping () -> Void) {
        self.finish = finish
        _model = State(initialValue: OnboardingFlowModel(start: start))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 10)
            ZStack {
                page(model.step)
                    .id(model.step)
                    .transition(pageTransition)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Palette.base)
        .onExitCommand(perform: finish)
        // Permissions change in System Settings, outside the app: follow them while they are shown.
        .task(id: model.step) {
            if model.step == .permissions || model.step == .ready {
                await model.watchPermissions()
            } else if model.step == .agentCli {
                model.reloadAgents()
            }
        }
    }

    // MARK: Pages

    @ViewBuilder private func page(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome: OnboardingWelcomeStep()
        case .personalize: OnboardingPersonalizeStep(model: model)
        case .tour: OnboardingTourStep(model: model)
        case .permissions: OnboardingPermissionsStep(model: model)
        case .agentCli: OnboardingAgentStep(model: model)
        case .ready: OnboardingReadyStep(model: model, finish: finish)
        }
    }

    /// Pages slide a little in the reading direction; with Reduce Motion they only fade.
    private var pageTransition: AnyTransition {
        if reduceMotion || Motion.reduced { return .opacity }
        let shift: CGFloat = 36
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: model.forward ? shift : -shift)),
            removal: .opacity.combined(with: .offset(x: model.forward ? -shift : shift)))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(onboardingText(format: "Step %lld of %lld", model.step.rawValue + 1, OnboardingStep.allCases.count))
                    .font(.mhCaption.weight(.semibold))
                    .foregroundStyle(Palette.textMuted)
                    .contentTransition(.numericText())
                Text(verbatim: "·").font(.mhCaption).foregroundStyle(Palette.textFaint)
                Text(model.step.title)
                    .font(.mhCaption.weight(.semibold))
                    .foregroundStyle(Palette.text)
                Spacer()
                if !model.isLast {
                    Button(onboardingText("Skip Guide"), action: finish)
                        .buttonStyle(.borderless)
                        .font(.mhCaption)
                        .foregroundStyle(Palette.textMuted)
                        .keyboardShortcut(.cancelAction)
                        .help(onboardingText("Close the guide. You can open it again from Help → Welcome Guide."))
                }
            }
            OnboardingProgressBar(current: model.step) { model.move(to: $0) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if !model.isFirst {
                Button {
                    model.goBack()
                } label: {
                    Label(onboardingText("Back"), systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help(onboardingText("Previous step (⌘←)"))
            }
            Spacer()
            if model.isLast {
                Button(onboardingText("Done"), action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    model.goNext()
                } label: {
                    HStack(spacing: 6) {
                        Text(model.isFirst ? onboardingText("Get Started") : onboardingText("Next"))
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help(onboardingText("Next step (Return)"))
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

/// Six segments, filled up to the current step. Each one jumps to its step.
private struct OnboardingProgressBar: View {
    let current: OnboardingStep
    var select: (OnboardingStep) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                Button {
                    select(step)
                } label: {
                    ZStack(alignment: .leading) {
                        SurfaceShape.capsule.fill(Palette.text.opacity(0.10))
                        SurfaceShape.capsule
                            .fill(step <= current ? Theme.accent : Color.clear)
                            .scaleEffect(x: step <= current ? 1 : 0.001, anchor: .leading)
                    }
                    .frame(height: 5)
                    .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(.plain)
                .help(step.title)
                .accessibilityLabel(onboardingText(format: "Go to %@", step.title))
                .accessibilityAddTraits(step == current ? .isSelected : [])
            }
        }
        .animation(Motion.standard, value: current)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(onboardingText("Guide progress"))
    }
}
