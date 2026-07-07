import SwiftUI
import UIKit

/// Tiny UI-polish primitives used across the app. Bundled in one file so the
/// API surface stays small and the styles stay consistent.
enum PolishKit {

    // MARK: - Press feedback

    /// Wraps a `Button`-shaped view so it physically responds to touch:
    /// scales down to ~96% on press, springs back on release, and snaps back
    /// if the touch is cancelled (e.g. drag-off). Tap-to-action affordance
    /// that runs beneath any visual style.
    struct PressFeedbackModifier: ViewModifier {
        var scale: CGFloat
        var pressedOpacity: Double
        @State private var isPressed = false

        func body(content: Content) -> some View {
            content
                .scaleEffect(isPressed ? scale : 1.0)
                .opacity(isPressed ? pressedOpacity : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.65), value: isPressed)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let active = value.translation.width == 0 && value.translation.height == 0
                            if isPressed != active { isPressed = active }
                        }
                        .onEnded { _ in
                            isPressed = false
                        }
                )
        }
    }

    // pressFeedback is implemented as a View extension below for proper
    // generic resolution at the use-site.


    // MARK: - Haptics

    /// Tiny wrapper around `UIImpactFeedbackGenerator` + `UINotificationFeedbackGenerator`.
    /// All calls are no-ops on devices that don't support haptics — they
    /// also pre-prepare the generator so the latency feels right.
    enum Haptics {
        case tap(_ style: Style = .light)
        case success
        case warning
        case error
        case selection

        enum Style {
            case light, medium, heavy, soft, rigid

            var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
                switch self {
                case .light:  return .light
                case .medium: return .medium
                case .heavy:  return .heavy
                case .soft:   return .soft
                case .rigid:  return .rigid
                }
            }
        }

        @MainActor
        func play() {
            switch self {
            case .tap(let style):
                let generator = UIImpactFeedbackGenerator(style: style.uiStyle)
                generator.prepare()
                generator.impactOccurred()
            case .success:
                let generator = UINotificationFeedbackGenerator()
                generator.prepare()
                generator.notificationOccurred(.success)
            case .warning:
                let generator = UINotificationFeedbackGenerator()
                generator.prepare()
                generator.notificationOccurred(.warning)
            case .error:
                let generator = UINotificationFeedbackGenerator()
                generator.prepare()
                generator.notificationOccurred(.error)
            case .selection:
                let generator = UISelectionFeedbackGenerator()
                generator.prepare()
                generator.selectionChanged()
            }
        }
    }

    // MARK: - Shimmer text

    /// A shimmering placeholder for "AI is thinking…" / "Reading the audio…" /
    /// "Rendering clips…" states. Sliding linear gradient over a dimmed text
    /// label — feels intentional without inventing copy.
    struct ShimmerText: View {
        let text: String
        var systemImage: String?
        var tint: Color = AppPalette.accent

        @State private var phase: CGFloat = -1

        var body: some View {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                }
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.mutedText)
                    .overlay {
                        // Only the text receives the gradient — the icon stays
                        // flat for legibility.
                        Text(text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.clear)
                            .overlay {
                                LinearGradient(
                                    colors: [tint.opacity(0.0), tint, tint.opacity(0.0)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .offset(x: phase * 120)
                                .mask {
                                    Text(text)
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                    }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
    }

    // MARK: - Empty state

    /// Reusable empty-state card — large soft icon, two-line copy, optional
    /// trailing action. The kind of placeholder that turns "no data" into
    /// "here's what to do next."
    struct EmptyStateView: View {
        let systemImage: String
        let title: String
        let message: String
        var accent: Color = AppPalette.accent
        var actionTitle: String?
        var action: (() -> Void)?

        var body: some View {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.12))
                        .frame(width: 64, height: 64)
                    Image(systemName: systemImage)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(accent)
                }

                Text(title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(AppPalette.primaryText)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let action {
                    Button {
                        action()
                        PolishKit.Haptics.tap(.light).play()
                    } label: {
                        Text(actionTitle)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppPalette.background)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .modifier(PolishKit.PressFeedbackModifier(scale: 0.96, pressedOpacity: 0.9))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }
        }
    }
}

// MARK: - View-extension sugar

extension View {
    /// Apply press-state feedback to anything that wraps a Button.
    func polishPressFeedback(scale: CGFloat = 0.96, pressedOpacity: Double = 0.85) -> some View {
        modifier(PolishKit.PressFeedbackModifier(scale: scale, pressedOpacity: pressedOpacity))
    }

    /// Trigger a haptic from inside a SwiftUI action closure.
    @MainActor
    func haptic(_ kind: PolishKit.Haptics) -> some View {
        // No-op modifier — exists so callers can write `.haptic(.success)` for
        // intent-revealing chains. Pair with `PolishKit.Haptics.X.play()`.
        self
    }
}
