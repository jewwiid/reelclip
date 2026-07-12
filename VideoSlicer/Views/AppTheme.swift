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

/// Shared geometry and material for every continuous ReelClip control. Native
/// `Slider`s retain the system Liquid Glass thumb; custom two-ended controls
/// use `ReelClipRangeHandle` so range editing has the same white-glass/accent
/// language without sacrificing the narrow edge marker needed on timelines.
enum ReelClipSliderAppearance {
    static let trackHeight: CGFloat = 6
    static let standardHandleHitSize: CGFloat = 44
    static let rangeHandleCornerRadius: CGFloat = 7
}

struct ReelClipRangeHandle: View {
    let width: CGFloat
    let height: CGFloat
    var isActive = false
    var mirrored = false
    var gripLineCount = 2
    var isInteractive = true

    var body: some View {
        handleSurface
            .overlay {
                RoundedRectangle(
                    cornerRadius: min(ReelClipSliderAppearance.rangeHandleCornerRadius, width / 2),
                    style: .continuous
                )
                .stroke(AppPalette.accent, lineWidth: isActive ? 2 : 1.25)
            }
            .overlay { gripMarks }
            .shadow(color: .black.opacity(isActive ? 0.34 : 0.24), radius: isActive ? 7 : 4, y: 2)
            .scaleEffect(isActive ? 1.06 : 1)
            .animation(.snappy(duration: 0.16), value: isActive)
    }

    @ViewBuilder
    private var handleSurface: some View {
        let cornerRadius = min(ReelClipSliderAppearance.rangeHandleCornerRadius, width / 2)
        if #available(iOS 26.0, *) {
            if isInteractive {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.clear)
                    .frame(width: width, height: height)
                    .glassEffect(
                        .regular
                            .tint(AppPalette.accent.opacity(isActive ? 0.24 : 0.12))
                            .interactive(),
                        in: .rect(cornerRadius: cornerRadius)
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.clear)
                    .frame(width: width, height: height)
                    .glassEffect(
                        .regular.tint(AppPalette.accent.opacity(isActive ? 0.24 : 0.12)),
                        in: .rect(cornerRadius: cornerRadius)
                    )
            }
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppPalette.primaryText)
                .frame(width: width, height: height)
        }
    }

    @ViewBuilder
    private var gripMarks: some View {
        if width <= 10 {
            VStack(spacing: 3) {
                ForEach(0..<max(gripLineCount, 0), id: \.self) { _ in
                    Capsule()
                        .fill(AppPalette.accent)
                        .frame(width: min(6, max(2, width - 1)), height: 1.5)
                }
            }
            .environment(\.layoutDirection, mirrored ? .rightToLeft : .leftToRight)
        } else {
            HStack(spacing: 2) {
                ForEach(0..<max(gripLineCount, 0), id: \.self) { _ in
                    Capsule()
                        .fill(AppPalette.accent)
                        .frame(
                            width: min(2, max(1, width / 3)),
                            height: min(14, max(5, height * 0.58))
                        )
                }
            }
            .environment(\.layoutDirection, mirrored ? .rightToLeft : .leftToRight)
        }
    }
}

/// Identifies which endpoint changed in a shared two-ended slider. Kept
/// distinct from screen-specific concepts such as trim "in" / "out" so the
/// same control can power import selection and random recipe ranges.
enum ReelClipRangeSliderHandle {
    case lower
    case upper
}

/// The canonical interactive two-ended ReelClip slider. Import selection and
/// random Cut ranges use this exact track, Liquid Glass thumb, hit target,
/// spacing, and crossing protection. Timelines retain their narrower edge
/// grips because they must coexist with video-frame overlays.
struct ReelClipRangeSlider: View {
    @Binding var lowerValue: Double
    @Binding var upperValue: Double

    let bounds: ClosedRange<Double>
    var minimumGap: Double = 0
    var step: Double = 1
    var onValueChanged: ((ReelClipRangeSliderHandle, Double) -> Void)? = nil

    @State private var activeHandle: ReelClipRangeSliderHandle?

    private let handleHitSize = ReelClipSliderAppearance.standardHandleHitSize
    private let thumbDiameter: CGFloat = 30
    private let trackHeight = ReelClipSliderAppearance.trackHeight

    private var lowerDisplay: Double {
        min(max(min(lowerValue, upperValue), bounds.lowerBound), bounds.upperBound)
    }

    private var upperDisplay: Double {
        min(max(max(lowerValue, upperValue), bounds.lowerBound), bounds.upperBound)
    }

    private var effectiveGap: Double {
        max(0, min(minimumGap, bounds.upperBound - bounds.lowerBound))
    }

    var body: some View {
        GeometryReader { proxy in
            let usableWidth = max(proxy.size.width - handleHitSize, 1)
            let lowerX = xPosition(for: lowerDisplay, usableWidth: usableWidth) + handleHitSize / 2
            let upperX = xPosition(for: upperDisplay, usableWidth: usableWidth) + handleHitSize / 2
            let centerY = proxy.size.height / 2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppPalette.raisedSurface)
                    .frame(height: trackHeight)
                    .position(x: proxy.size.width / 2, y: centerY)

                Capsule()
                    .fill(AppPalette.accent)
                    .frame(width: max(upperX - lowerX, trackHeight), height: trackHeight)
                    .position(x: lowerX + max(upperX - lowerX, trackHeight) / 2, y: centerY)

                handleLayer(lowerX: lowerX, upperX: upperX, centerY: centerY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let rawValue = valueForLocation(
                            value.location.x - handleHitSize / 2,
                            usableWidth: usableWidth
                        )
                        if activeHandle == nil {
                            activeHandle = closestHandle(to: rawValue)
                        }
                        update(activeHandle, to: rawValue)
                    }
                    .onEnded { _ in
                        activeHandle = nil
                    }
            )
        }
        .frame(height: handleHitSize)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(ClipRangeFormatter.formatTime(lowerDisplay)) to \(ClipRangeFormatter.formatTime(upperDisplay))")
    }

    private func rangeHandle(isActive: Bool) -> some View {
        ReelClipRangeHandle(
            width: thumbDiameter,
            height: thumbDiameter,
            isActive: isActive,
            gripLineCount: 2
        )
        .frame(width: handleHitSize, height: handleHitSize)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func handleLayer(lowerX: CGFloat, upperX: CGFloat, centerY: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                rangeHandle(isActive: activeHandle == .lower)
                    .position(x: lowerX, y: centerY)
                    .zIndex(activeHandle == .lower ? 2 : 1)

                rangeHandle(isActive: activeHandle == .upper)
                    .position(x: upperX, y: centerY)
                    .zIndex(activeHandle == .upper ? 2 : 1)
            }
        } else {
            rangeHandle(isActive: activeHandle == .lower)
                .position(x: lowerX, y: centerY)
                .zIndex(activeHandle == .lower ? 2 : 1)

            rangeHandle(isActive: activeHandle == .upper)
                .position(x: upperX, y: centerY)
                .zIndex(activeHandle == .upper ? 2 : 1)
        }
    }

    private func xPosition(for value: Double, usableWidth: CGFloat) -> CGFloat {
        guard bounds.upperBound > bounds.lowerBound else { return 0 }
        let clamped = min(max(value, bounds.lowerBound), bounds.upperBound)
        let ratio = (clamped - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)
        return CGFloat(ratio) * usableWidth
    }

    private func valueForLocation(_ x: CGFloat, usableWidth: CGFloat) -> Double {
        guard bounds.upperBound > bounds.lowerBound else { return bounds.lowerBound }
        let clampedX = min(max(x, 0), usableWidth)
        let ratio = Double(clampedX / max(usableWidth, 1))
        let value = bounds.lowerBound + ratio * (bounds.upperBound - bounds.lowerBound)
        guard step.isFinite, step > 0 else { return value }
        return (value / step).rounded() * step
    }

    private func closestHandle(to value: Double) -> ReelClipRangeSliderHandle {
        abs(value - lowerDisplay) <= abs(value - upperDisplay) ? .lower : .upper
    }

    private func update(_ handle: ReelClipRangeSliderHandle?, to rawValue: Double) {
        guard let handle else { return }
        switch handle {
        case .lower:
            let upperLimit = max(bounds.lowerBound, upperDisplay - effectiveGap)
            let value = min(max(rawValue, bounds.lowerBound), upperLimit)
            lowerValue = value
            onValueChanged?(.lower, value)
        case .upper:
            let lowerLimit = min(bounds.upperBound, lowerDisplay + effectiveGap)
            let value = max(min(rawValue, bounds.upperBound), lowerLimit)
            upperValue = value
            onValueChanged?(.upper, value)
        }
    }
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
