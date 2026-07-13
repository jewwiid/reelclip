import SwiftUI

/// First-launch orientation. It sits above the tab hierarchy so the project
/// workflow is clear before the user lands in a particular edit mode.
struct ReelClipOnboardingView: View {
    private struct Step: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let body: String
        let accentLabel: String
    }

    private let steps = [
        Step(
            id: 0,
            symbol: "photo.on.rectangle.angled",
            title: "Start with your footage",
            body: "Choose a video from Photos or Files. ReelClip keeps the original unchanged while you work.",
            accentLabel: "Import a video"
        ),
        Step(
            id: 1,
            symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
            title: "Choose what to work with",
            body: "Use the full source or set one in and out range before your project begins.",
            accentLabel: "Trim before planning"
        ),
        Step(
            id: 2,
            symbol: "square.stack.3d.up.fill",
            title: "Plan, refine, and save",
            body: "Build clips with a recipe, adjust their edges, then preview the project sequence before saving to Photos.",
            accentLabel: "Your edit stays on device"
        )
    ]

    let onFinish: (_ shouldStartProject: Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedStep = 0

    private var isLastStep: Bool { selectedStep == steps.count - 1 }

    var body: some View {
        ZStack {
            AppPalette.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                TabView(selection: $selectedStep) {
                    ForEach(steps) { step in
                        stepPage(step)
                            .tag(step.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageIndicator
                    .padding(.bottom, 24)

                primaryAction
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)

                if isLastStep {
                    Button("Explore first") {
                        finish(shouldStartProject: false)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .buttonStyle(.plain)
                    .padding(.bottom, 16)
                } else {
                    Color.clear.frame(height: 37)
                }
            }
        }
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
    }

    private var topBar: some View {
        HStack {
            AppBrandLockup(iconSize: 48)

            Spacer()

            if !isLastStep {
                Button("Skip") {
                    finish(shouldStartProject: false)
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.secondaryText)
                .frame(minWidth: 52, minHeight: 44)
                .buttonStyle(.plain)
                .accessibilityHint("Closes onboarding and opens Home")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private func stepPage(_ step: Step) -> some View {
        VStack(spacing: 26) {
            Spacer(minLength: 12)

            OnboardingVisual(symbol: step.symbol, step: step.id)
                .frame(height: 228)

            VStack(spacing: 12) {
                Text(step.accentLabel)
                    .font(.caption.weight(.black))
                    .foregroundStyle(AppPalette.accent)
                    .textCase(.uppercase)
                    .tracking(0.8)

                Text(step.title)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppPalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.body)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 34)

            Spacer(minLength: 20)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.id + 1) of \(steps.count). \(step.title). \(step.body)")
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(steps) { step in
                Capsule()
                    .fill(step.id == selectedStep ? AppPalette.accent : AppPalette.raisedSurface)
                    .frame(width: step.id == selectedStep ? 28 : 8, height: 8)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedStep)
            }
        }
        .accessibilityHidden(true)
    }

    private var primaryAction: some View {
        Button {
            if isLastStep {
                finish(shouldStartProject: true)
            } else {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    selectedStep += 1
                }
            }
        } label: {
            Label(
                isLastStep ? "Start a project" : "Continue",
                systemImage: isLastStep ? "plus.rectangle.on.rectangle" : "arrow.right"
            )
            .font(.headline.weight(.bold))
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(AppPalette.background)
            .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .polishPressFeedback()
    }

    private func finish(shouldStartProject: Bool) {
        PolishKit.Haptics.tap(.medium).play()
        onFinish(shouldStartProject)
    }
}

private struct OnboardingVisual: View {
    let symbol: String
    let step: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(AppPalette.surface)
                .frame(width: 228, height: 228)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }

            switch step {
            case 0:
                Image("LogoMark")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 118, height: 118)
            case 1:
                rangeGraphic
            default:
                sequenceGraphic
            }

            if step == 0 {
                Image(systemName: symbol)
                    .font(.caption.weight(.black))
                    .foregroundStyle(AppPalette.accent)
                    .padding(9)
                    .background(AppPalette.background, in: Circle())
                    .overlay { Circle().stroke(AppPalette.hairline, lineWidth: 1) }
                    .offset(x: 74, y: 74)
            }
        }
        .accessibilityHidden(true)
    }

    private var rangeGraphic: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(AppPalette.accent)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppPalette.raisedSurface)
                    .frame(width: 150, height: 6)

                Capsule()
                    .fill(AppPalette.accent)
                    .frame(width: 92, height: 6)
                    .padding(.leading, 28)

                HStack {
                    Capsule()
                        .fill(AppPalette.primaryText)
                        .frame(width: 24, height: 30)
                    Spacer()
                    Capsule()
                        .fill(AppPalette.primaryText)
                        .frame(width: 24, height: 30)
                }
                .frame(width: 150)
            }
            .frame(height: 40)
        }
    }

    private var sequenceGraphic: some View {
        VStack(spacing: 15) {
            Image(systemName: symbol)
                .font(.system(size: 45, weight: .medium))
                .foregroundStyle(AppPalette.accent)

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(index == 1 ? AppPalette.accent : AppPalette.controlSurface)
                        .frame(width: 42, height: 58)
                        .overlay(alignment: .bottomLeading) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.black))
                                .foregroundStyle(index == 1 ? AppPalette.background : AppPalette.primaryText)
                                .padding(6)
                        }
                }
            }
        }
    }
}

#Preview {
    ReelClipOnboardingView { _ in }
}
