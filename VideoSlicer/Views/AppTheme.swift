import SwiftUI
import UIKit

enum AppPalette {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.066)
    static let surface = Color(red: 0.093, green: 0.098, blue: 0.109)
    static let raisedSurface = Color(red: 0.128, green: 0.134, blue: 0.148)
    static let controlSurface = Color(red: 0.155, green: 0.162, blue: 0.178)
    static let disabledSurface = Color(red: 0.19, green: 0.195, blue: 0.207).opacity(0.58)
    static let mediaWell = Color(red: 0.033, green: 0.036, blue: 0.043)
    static let primaryText = Color(red: 0.94, green: 0.945, blue: 0.93)
    static let secondaryText = Color(red: 0.65, green: 0.67, blue: 0.67)
    static let mutedText = Color(red: 0.43, green: 0.45, blue: 0.45)
    static let accent = Color(red: 0.77, green: 0.94, blue: 0.20)
    static let success = Color(red: 0.33, green: 0.78, blue: 0.47)
    static let danger = Color(red: 0.91, green: 0.31, blue: 0.31)
    static let hairline = Color.white.opacity(0.08)
    static let timelineBlock = Color.white.opacity(0.14)
}

struct AppBrandLockup: View {
    var subtitle: String? = nil
    var iconSize: CGFloat = 40
    var titleFont: Font = .system(.title3, design: .rounded).weight(.black)

    // The wordmark ships as a transparent PNG with the r/e mark leading
    // the type, so the whole brand is one image now. `iconSize` is reused
    // as the wordmark height (with a small bump for visual weight against
    // the old icon-in-square look) and `titleFont` now styles the subtitle
    // — same call sites, repurposed meaning. Multiplier tuned: 1.3 (too
    // tall) → 0.65 (too small) → 0.85 (current sweet spot per build 119
    // feedback).
    private var wordmarkHeight: CGFloat { iconSize * 0.85 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image("Wordmark")
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: wordmarkHeight)
                .accessibilityHidden(true)

            if let subtitle {
                Text(subtitle)
                    .font(titleFont)
                    .foregroundStyle(AppPalette.accent)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtitle.map { "ReelClips, \($0)" } ?? "ReelClips")
    }
}

struct AppBrandIcon: View {
    let size: CGFloat

    var body: some View {
        // Standalone brand mark for placements that need a header chip
        // without the full lockup (paywall, etc.). Uses the same
        // wordmark as `AppBrandLockup` — `size` is the height, the
        // width follows from the wordmark's natural ~3.5:1 aspect.
        Image("Wordmark")
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(height: size)
            .accessibilityHidden(true)
    }
}

extension CutMode {
    var symbolName: String {
        switch self {
        case .fixed:
            return "scissors"
        case .smartPause:
            return "waveform"
        case .highlight:
            // Splice = "join by cutting". `fork.knife` is the
            // closest knife-shaped SF Symbol — there's no standalone
            // `knife` glyph. `scissors` was considered but is already
            // taken by Cut (`.fixed`), so this keeps the two cutting
            // tools visually distinct in the mode picker.
            return "fork.knife"
        case .aiAssist:
            return "brain.head.profile"
        }
    }

    var shortTitle: String {
        switch self {
        case .fixed:
            return "Cut"
        case .smartPause:
            return "Silence"
        case .highlight:
            return "Splice"
        case .aiAssist:
            return "AI"
        }
    }
}

/// Sticky top header that shows the ReelClip wordmark, applied to each
/// of the three primary tab views via `.safeAreaInset(edge: .top)` so
/// the brand is always present even when the user scrolls deep into
/// the project list, the clip editor, or the settings stack.
struct StickyBrandHeader: View {
    var wordmarkHeight: CGFloat = 38

    var body: some View {
        HStack {
            Spacer()
            Image("Wordmark")
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: wordmarkHeight)
            Spacer()
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.hairline)
                .frame(height: 1 / UIScreen.main.scale)
        }
    }
}

extension View {
    func premiumSurface() -> AnyView {
        // `.clipped()` after the background + overlay so any
        // child view that grows wider than the surface (long
        // un-wrappable text, a TextField with very long input,
        // a Picker that exceeds the frame width, etc.) is cut
        // off at the rounded surface boundary instead of
        // overflowing past the hairline border. Without this,
        // toggling a collapsible section can "blow out" the
        // surface — the bg + border stay at the original width
        // but the children extend past the right edge, breaking
        // the visual contract of the rounded card. We use the
        // same corner radius for the clip shape so the cut
        // matches the surface silhouette.
        AnyView(
            self
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
    }
}
