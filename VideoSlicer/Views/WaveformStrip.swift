import SwiftUI

struct WaveformStrip: View {
    let samples: [WaveformSample]
    let plannedRanges: [ClipRange]
    let duration: Double
    let scrubPosition: Double
    let onScrub: (Double) -> Void
    var selectedRangeIndex: Int?
    var frameDuration: Double = 1.0 / 30.0
    var onSelectRange: ((Int) -> Void)? = nil
    var onUpdateRange: ((Int, ClipRange) -> Void)? = nil
    /// In-progress clip selection the user is positioning on the timeline
    /// before committing via "Add to plan".
    var draftHighlight: ClipRange? = nil
    var onMoveDraft: ((Double) -> Void)? = nil
    var onResizeDraftStart: ((Double) -> Void)? = nil
    var onResizeDraftEnd: ((Double) -> Void)? = nil
    /// Source video thumbnails for the frame tooltip shown while dragging
    /// handles. When non-empty, dragging either edge of a planned range or
    /// the draft highlight shows a small frame preview above the handle.
    var thumbnails: [MediaThumbnail] = []

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                waveformCanvas(size: proxy.size)

                if let timeline = TimelineGeometry(size: proxy.size, duration: duration) {
                    // Draft highlight — drawn first so planned ranges paint
                    // on top (gives the visual hierarchy: working selection
                    // is "above" the timeline, committed clips are solid).
                    if let draft = draftHighlight {
                        DraftHighlightView(
                            range: draft,
                            timeline: timeline,
                            size: proxy.size,
                            thumbnails: thumbnails,
                            onMove: onMoveDraft,
                            onResizeEnd: onResizeDraftEnd,
                            onResizeStart: onResizeDraftStart
                        )
                    }
                }

                if let timeline = TimelineGeometry(size: proxy.size, duration: duration),
                   !plannedRanges.isEmpty {
                    ForEach(Array(plannedRanges.enumerated()), id: \.offset) { index, range in
                        RangeInteractionView(
                            index: index,
                            range: range,
                            timeline: timeline,
                            size: proxy.size,
                            isSelected: index == selectedRangeIndex,
                            frameDuration: frameDuration,
                            thumbnails: thumbnails,
                            onSelectRange: onSelectRange,
                            onUpdateRange: onUpdateRange
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrub(at: value.location.x, width: proxy.size.width)
                    }
            )
        }
        .frame(height: 52)
        .background(AppPalette.mediaWell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(samples.isEmpty ? "Timeline scrubber" : "Audio waveform scrubber")
        .accessibilityValue("\(ClipRangeFormatter.formatTime(scrubPosition)) of \(ClipRangeFormatter.formatTime(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onScrub(min(scrubPosition + 1, duration))
            case .decrement:
                onScrub(max(scrubPosition - 1, 0))
            @unknown default:
                break
            }
        }
        .animation(.snappy(duration: 0.22), value: selectedRangeIndex)
    }

    private func waveformCanvas(size: CGSize) -> some View {
        Canvas { context, size in
            guard let timeline = TimelineGeometry(size: size, duration: duration) else {
                return
            }

            let baseline = size.height / 2
            let displaySampleCount = samples.isEmpty ? 42 : samples.count
            let barWidth = max(timeline.width / CGFloat(max(displaySampleCount, 1)) * 0.58, 1.2)

            // 1. Waveform at full intensity — drawn first so the dim overlay
            //    below can mute the cut regions and the accent overlays can
            //    brighten the kept regions.
            if samples.isEmpty {
                for index in 0..<displaySampleCount {
                    let x = CGFloat(index) * timeline.width / CGFloat(displaySampleCount)
                    let height = CGFloat((index % 5) + 2) / 7.0 * size.height * 0.42
                    let rect = CGRect(x: x, y: baseline - height / 2, width: barWidth, height: max(height, 2))
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 2),
                        with: .color(AppPalette.timelineBlock)
                    )
                }
            } else {
                for (index, sample) in samples.enumerated() {
                    let x = CGFloat(index) * timeline.width / CGFloat(max(samples.count, 1))
                    let level = sample.level.isFinite ? min(max(sample.level, 0), 1) : 0
                    let height = max(CGFloat(level) * size.height * 0.92, 2)
                    let rect = CGRect(x: x, y: baseline - height / 2, width: barWidth, height: height)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 2),
                        with: .color(AppPalette.primaryText.opacity(0.42))
                    )
                }
            }

            // 2. Dim overlay on the cut regions (inverse of plannedRanges) so the
            //    user can see at a glance which seconds of the source will be skipped.
            if !plannedRanges.isEmpty {
                drawCutRegionOverlay(
                    context: context,
                    size: size,
                    timeline: timeline
                )
            }

            // 3. Accent overlays for the kept ranges.
            for (index, range) in plannedRanges.enumerated() {
                let startX = timeline.xPosition(for: range.startSeconds)
                let endX = timeline.xPosition(for: range.endSeconds)
                let width = max(endX - startX, 1)
                let isSelected = index == selectedRangeIndex

                // Solid accent tint — slightly brighter for the selected range so
                // it reads as "this is the one I'd edit".
                let fillOpacity: Double = isSelected ? 0.48 : 0.32
                let rect = CGRect(x: startX, y: 0, width: width, height: size.height)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 6),
                    with: .color(AppPalette.accent.opacity(fillOpacity))
                )

                // Top + bottom accent stripes so the range reads as a band, not a wash.
                let stripeHeight: CGFloat = 3
                context.fill(
                    Path(CGRect(x: startX, y: 0, width: width, height: stripeHeight)),
                    with: .color(AppPalette.accent)
                )
                context.fill(
                    Path(CGRect(x: startX, y: size.height - stripeHeight, width: width, height: stripeHeight)),
                    with: .color(AppPalette.accent)
                )

                // Cut-point divider lines at every range boundary (except the very first start).
                if index > 0 {
                    var line = Path()
                    line.move(to: CGPoint(x: startX, y: 0))
                    line.addLine(to: CGPoint(x: startX, y: size.height))
                    context.stroke(line, with: .color(AppPalette.accent), lineWidth: 1.5)
                }

                // Clip number badge near the top-left of each range.
                if width > 28 {
                    let label = "\(index + 1)"
                    let labelOrigin = CGPoint(x: startX + 6, y: 6)
                    context.draw(
                        Text(label)
                            .font(.caption2.weight(.black))
                            .foregroundStyle(AppPalette.background),
                        at: labelOrigin,
                        anchor: .topLeading
                    )
                }
            }

            // 4. Scrub line + dot.
            let scrubX = timeline.xPosition(for: scrubPosition)
            var path = Path()
            path.move(to: CGPoint(x: scrubX, y: 0))
            path.addLine(to: CGPoint(x: scrubX, y: size.height))
            context.stroke(path, with: .color(AppPalette.accent), lineWidth: 2)

            context.fill(
                Path(ellipseIn: CGRect(x: scrubX - 4, y: size.height / 2 - 4, width: 8, height: 8)),
                with: .color(AppPalette.accent)
            )
        }
    }

    private func scrub(at xPosition: CGFloat, width: CGFloat) {
        guard duration.isFinite, duration > 0, width.isFinite, width > 0 else { return }
        let ratio = min(max(Double(xPosition / width), 0), 1)
        onScrub(duration * ratio)
    }

    /// Dim the inverse of the planned ranges — the seconds the user is cutting away.
    /// Iterates gaps between ranges + a leading/trailing gap, since computing
    /// the inverse region directly is more error-prone than enumerating
    /// the cuts themselves.
    private func drawCutRegionOverlay(
        context: GraphicsContext,
        size: CGSize,
        timeline: TimelineGeometry
    ) {
        // Build the cut regions in time-space, then draw their x-space rects.
        let total = duration
        guard total > 0, total.isFinite else { return }

        // Normalise + sort the planned ranges.
        let sorted = plannedRanges
            .map { (start: max(0, $0.startSeconds), end: min(total, $0.endSeconds)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }

        // Collapse overlapping ranges so the gap walk doesn't double-paint.
        var merged: [(start: Double, end: Double)] = []
        for r in sorted {
            if let last = merged.last, r.start <= last.end {
                merged[merged.count - 1].end = max(last.end, r.end)
            } else {
                merged.append(r)
            }
        }

        // Collect gap intervals (the actual cut regions).
        var gaps: [(start: Double, end: Double)] = []
        var cursor: Double = 0
        for r in merged {
            if r.start > cursor {
                gaps.append((start: cursor, end: r.start))
            }
            cursor = max(cursor, r.end)
        }
        if cursor < total {
            gaps.append((start: cursor, end: total))
        }

        // Paint each gap with a dark overlay — same colour as the background
        // tinted with hairline so the waveform still peeks through, but the
        // user can clearly see "this section is gone".
        for gap in gaps {
            let startX = timeline.xPosition(for: gap.start)
            let endX = timeline.xPosition(for: gap.end)
            let width = max(endX - startX, 1)
            context.fill(
                Path(CGRect(x: startX, y: 0, width: width, height: size.height)),
                with: .color(AppPalette.background.opacity(0.62))
            )
        }
    }
}

/// Per-range interaction overlay for `WaveformStrip`.
///
/// Renders an invisible tap target spanning the planned range (so tapping a
/// clip on the waveform selects it) plus, for the selected range, a visible
/// accent border and two edge handles that drag to trim the range's start or
/// end. Lives in its own struct so each range owns its own drag-base state.
struct RangeInteractionView: View {
    let index: Int
    let range: ClipRange
    let timeline: TimelineGeometry
    let size: CGSize
    let isSelected: Bool
    let frameDuration: Double
    let thumbnails: [MediaThumbnail]
    let onSelectRange: ((Int) -> Void)?
    let onUpdateRange: ((Int, ClipRange) -> Void)?

    @State private var startDragBase: ClipRange?
    @State private var endDragBase: ClipRange?
    @State private var bodyDragBase: ClipRange?
    /// Which handle is currently being dragged — drives the frame tooltip.
    @State private var draggingEdge: DraggingEdge? = nil

    // Trim handles — Doc: smaller, edge-only geometry.
    //
    // Earlier values (18 visible + 18 padding + 38 tall on a 52 strip)
    // left the handles eating 73% of the strip's height AND overlapping
    // the range body by 27pt on each side. Users trying to drag the
    // body to slide the range would grab a handle instead.
    //
    // New geometry:
    //   • visible pill: 8 × 24 (less than half the strip height, leaves
    //     room above + below for the waveform to read)
    //   • hit padding: 12pt on the OUTSIDE of the range, 6pt on the
    //     INSIDE — so finger drags near the inner edge still
    //     unambiguously hit the body, not the handle
    //   • minWidthForHandles raised to 50 so we don't show handles on
    //     sub-second ranges where they're useless
    //   • body gets its own drag gesture (slide whole range) — was tap-only
    private let handleVisibleWidth: CGFloat = 8
    private let handleHeight: CGFloat = 24
    private let handleOutsidePadding: CGFloat = 12
    private let handleInsidePadding: CGFloat = 6
    private let minWidthForHandles: CGFloat = 50

    var body: some View {
        let startX = timeline.xPosition(for: range.startSeconds)
        let endX = timeline.xPosition(for: range.endSeconds)
        let width = max(endX - startX, 1)

        return ZStack(alignment: .topLeading) {
            // Body — tap-to-select AND drag-to-slide. Previously tap-only;
            // users had no way to reposition a range without grabbing an
            // edge handle, which then resized instead of moving.
            //
            // `simultaneousGesture` (not `.gesture`) so the tap still fires
            // alongside the drag — `.gesture` would let the DragGesture
            // swallow the tap when `minimumDistance` is 0.
            // `minimumDistance: 4` so a tap (finger down + up with <4pt
            // movement) still counts as a tap, not a drag.
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: width, height: size.height)
                .offset(x: startX, y: 0)
                .onTapGesture {
                    onSelectRange?(index)
                }
                .simultaneousGesture(bodyDrag(width: timeline.width))

            if isSelected, width >= minWidthForHandles {
                // Left edge handle. Hit target extends 12pt OUTSIDE the range
                // (where there are no other gestures) and 6pt INSIDE (small
                // enough that finger drags near the middle of the body still
                // hit the body's slide gesture).
                ZStack {
                    Color.clear
                    trimHandle(isStart: true)
                }
                .frame(width: handleVisibleWidth + handleOutsidePadding + handleInsidePadding, height: handleHeight)
                .contentShape(Rectangle())
                .offset(
                    x: startX - (handleVisibleWidth + handleOutsidePadding + handleInsidePadding) / 2 + handleInsidePadding,
                    y: (size.height - handleHeight) / 2
                )
                .gesture(startHandleDrag(width: timeline.width))

                // Right edge handle.
                ZStack {
                    Color.clear
                    trimHandle(isStart: false)
                }
                .frame(width: handleVisibleWidth + handleOutsidePadding + handleInsidePadding, height: handleHeight)
                .contentShape(Rectangle())
                .offset(
                    x: endX - (handleVisibleWidth + handleOutsidePadding + handleInsidePadding) / 2 - handleInsidePadding,
                    y: (size.height - handleHeight) / 2
                )
                .gesture(endHandleDrag(width: timeline.width))
            }

            // Frame tooltip — appears above the handle while dragging.
            if let edge = draggingEdge {
                let seconds = edge == .start ? range.startSeconds : range.endSeconds
                let x = timeline.xPosition(for: seconds)
                HandleFrameTooltip(
                    seconds: seconds,
                    xPosition: x,
                    thumbnails: thumbnails
                )
            }
        }
        .frame(width: width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(width >= 8) // skip hit testing for sub-pixel slivers
    }

    /// Body-drag — slide the whole range without resizing. Snaps so the
    /// resulting range stays on frame boundaries.
    /// `minimumDistance: 4` so taps (down + up, <4pt) register as taps for
    /// `onSelectRange`; anything ≥4pt is a drag.
    private func bodyDrag(width: CGFloat) -> some Gesture {
        let totalDuration = timeline.duration
        return DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard totalDuration.isFinite, totalDuration > 0, width.isFinite, width > 0 else { return }
                if bodyDragBase == nil { bodyDragBase = range }
                guard let base = bodyDragBase else { return }
                let delta = Double(value.translation.width / width) * totalDuration
                let proposedStart = base.startSeconds + delta
                let length = base.endSeconds - base.startSeconds
                // Clamp so the range stays inside the source.
                let clampedStart = min(max(proposedStart, 0), max(0, totalDuration - length))
                let clampedEnd = clampedStart + length
                let edited = ClipRangeEditor.updatedRange(
                    base,
                    totalDuration: totalDuration,
                    frameDuration: frameDuration,
                    startSeconds: clampedStart,
                    endSeconds: clampedEnd
                )
                onUpdateRange?(index, edited)
            }
            .onEnded { _ in
                bodyDragBase = nil
            }
    }

    // Per-side handle so the start handle mirrors its grab lines to face the
    // range interior (drag-left to trim earlier, drag-right to trim later).
    private func trimHandle(isStart: Bool) -> some View {
        TrimHandleShape(mirrored: isStart)
    }

    private func startHandleDrag(width: CGFloat) -> some Gesture {
        let totalDuration = timeline.duration
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard totalDuration.isFinite, totalDuration > 0, width.isFinite, width > 0 else { return }
                if startDragBase == nil { startDragBase = range; draggingEdge = .start }
                let base = startDragBase ?? range
                let delta = Double(value.translation.width / width) * totalDuration
                let edited = ClipRangeEditor.updatedRange(
                    base,
                    totalDuration: totalDuration,
                    frameDuration: frameDuration,
                    startSeconds: base.startSeconds + delta
                )
                onUpdateRange?(index, edited)
            }
            .onEnded { _ in
                startDragBase = nil
                draggingEdge = nil
            }
    }

    private func endHandleDrag(width: CGFloat) -> some Gesture {
        let totalDuration = timeline.duration
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard totalDuration.isFinite, totalDuration > 0, width.isFinite, width > 0 else { return }
                if endDragBase == nil { endDragBase = range; draggingEdge = .end }
                let base = endDragBase ?? range
                let delta = Double(value.translation.width / width) * totalDuration
                let edited = ClipRangeEditor.updatedRange(
                    base,
                    totalDuration: totalDuration,
                    frameDuration: frameDuration,
                    endSeconds: base.endSeconds + delta
                )
                onUpdateRange?(index, edited)
            }
            .onEnded { _ in
                endDragBase = nil
                draggingEdge = nil
            }
    }
}

/// Visual shape for a trim handle on the waveform: a white pill with an accent
/// border and three short horizontal grab lines. When `mirrored` is true the
/// grab lines face left (start handle), otherwise they face right (end handle).
private struct TrimHandleShape: View {
    var mirrored: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(AppPalette.primaryText)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(AppPalette.accent, lineWidth: 1.5)
            }
            .overlay {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(AppPalette.accent)
                            .frame(width: 6, height: 1.5)
                    }
                }
                .environment(\.layoutDirection, mirrored ? .rightToLeft : .leftToRight)
            }
            .shadow(color: Color.black.opacity(0.32), radius: 5, y: 2)
    }
}

struct TimelineGeometry {
    let width: CGFloat
    let duration: Double

    init?(size: CGSize, duration: Double) {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              duration.isFinite,
              duration > 0
        else {
            return nil
        }

        self.width = size.width
        self.duration = duration
    }

    func xPosition(for seconds: Double) -> CGFloat {
        guard seconds.isFinite else { return 0 }
        let ratio = min(max(seconds / duration, 0), 1)
        return width * CGFloat(ratio)
    }
}

enum ClipRangeFormatter {
    static func title(for range: ClipRange) -> String {
        "\(formatTime(range.startSeconds)) - \(formatTime(range.endSeconds))"
    }

    static func durationLabel(for range: ClipRange) -> String {
        guard range.duration.isFinite, range.duration >= 0 else { return "-- sec" }
        return "\(String(format: "%.1f", range.duration)) sec"
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let totalTenths = Int((seconds * 10).rounded())
        let minutes = totalTenths / 600
        let tenthsWithinMinute = totalTenths % 600
        let wholeSeconds = tenthsWithinMinute / 10
        let tenths = tenthsWithinMinute % 10

        if tenths == 0 {
            return "\(minutes):\(String(format: "%02d", wholeSeconds))"
        }

        return "\(minutes):\(String(format: "%02d.%d", wholeSeconds, tenths))"
    }
}

struct EditableClipRangeBar: View {
    let range: ClipRange
    let duration: Double
    let frameDuration: Double
    let onChange: (ClipRange) -> Void

    @State private var startDragBase: ClipRange?
    @State private var endDragBase: ClipRange?

    var body: some View {
        GeometryReader { proxy in
            let totalDuration = duration.isFinite && duration > 0 ? duration : 0.05
            let width = proxy.size.width.isFinite && proxy.size.width > 0 ? proxy.size.width : 1
            let startRatio = min(max(range.startSeconds / totalDuration, 0), 1)
            let endRatio = min(max(range.endSeconds / totalDuration, 0), 1)
            let startX = width * startRatio
            let endX = width * endRatio
            let selectedWidth = max(endX - startX, 10)
            let handleSize: CGFloat = 24

            ZStack(alignment: .leading) {
                Capsule().fill(AppPalette.timelineBlock)

                Capsule()
                    .fill(AppPalette.accent)
                    .frame(width: selectedWidth)
                    .offset(x: startX)

                handle
                    .offset(x: min(max(startX - handleSize / 2, 0), width - handleSize))
                    .gesture(startHandleDrag(totalDuration: totalDuration, width: width))

                handle
                    .offset(x: min(max(endX - handleSize / 2, 0), width - handleSize))
                    .gesture(endHandleDrag(totalDuration: totalDuration, width: width))
            }
        }
        .frame(height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trim range \(ClipRangeFormatter.title(for: range))")
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(AppPalette.primaryText)
            .frame(width: 24, height: 24)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppPalette.background.opacity(0.45), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.24), radius: 6, y: 3)
    }

    private func startHandleDrag(totalDuration: Double, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard totalDuration.isFinite, totalDuration > 0, width.isFinite, width > 0 else { return }
                let base = startDragBase ?? range
                startDragBase = base
                let delta = Double(value.translation.width / width) * totalDuration
                let edited = ClipRangeEditor.updatedRange(
                    base,
                    totalDuration: totalDuration,
                    frameDuration: frameDuration,
                    startSeconds: base.startSeconds + delta
                )
                onChange(edited)
            }
            .onEnded { _ in
                startDragBase = nil
            }
    }

    private func endHandleDrag(totalDuration: Double, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard totalDuration.isFinite, totalDuration > 0, width.isFinite, width > 0 else { return }
                let base = endDragBase ?? range
                endDragBase = base
                let delta = Double(value.translation.width / width) * totalDuration
                let edited = ClipRangeEditor.updatedRange(
                    base,
                    totalDuration: totalDuration,
                    frameDuration: frameDuration,
                    endSeconds: base.endSeconds + delta
                )
                onChange(edited)
            }
            .onEnded { _ in
                endDragBase = nil
            }
    }
}
/// Highlight-mode draft selection overlay. Renders the user's in-progress
/// clip as a translucent band over the waveform. Three draggable surfaces:
///   • body — slide the whole band left/right (`onMove`)
///   • left edge — drag inward to shorten from the start
///   • right edge — drag inward to shorten from the end
///
/// Distinct from `RangeInteractionView` (which edits already-committed
/// planned ranges). This view represents work-in-progress that the user
/// commits with a separate "Add to plan" action.
struct DraftHighlightView: View {
    let range: ClipRange
    let timeline: TimelineGeometry
    let size: CGSize
    let thumbnails: [MediaThumbnail]
    let onMove: ((Double) -> Void)?
    let onResizeEnd: ((Double) -> Void)?
    let onResizeStart: ((Double) -> Void)?

    @State private var bodyDragBaseStart: Double? = nil
    @State private var startEdgeBase: Double? = nil
    @State private var endEdgeBase: Double? = nil
    /// Which edge is currently being dragged — drives the frame tooltip.
    @State private var draggingEdge: DraggingEdge? = nil

    // Handle geometry — matches `RangeInteractionView` so dragging the
    // draft's edges feels identical to dragging a committed clip's edges.
    private let handleVisibleWidth: CGFloat = 8
    private let handleHeight: CGFloat = 24
    private let handleOutsidePadding: CGFloat = 12
    private let handleInsidePadding: CGFloat = 6
    private let minWidthForHandles: CGFloat = 50

    var body: some View {
        let startX = timeline.xPosition(for: range.startSeconds)
        let endX = timeline.xPosition(for: range.endSeconds)
        let width = max(endX - startX, 1)

        return ZStack(alignment: .topLeading) {
            // Body — drag to slide the whole draft. Dashed accent border
            // distinguishes the working draft from committed clips.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AppPalette.accent.opacity(0.18))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            AppPalette.accent,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4])
                        )
                }
                .frame(width: width, height: size.height)
                .offset(x: startX, y: 0)
                .contentShape(Rectangle())
                .gesture(bodyDrag(width: timeline.width))

            // Edge handles — only when the draft is wide enough.
            if width >= minWidthForHandles {
                // Left edge.
                ZStack {
                    Color.clear
                    draftTrimHandle(isStart: true)
                }
                .frame(width: handleVisibleWidth + handleOutsidePadding + handleInsidePadding, height: handleHeight)
                .contentShape(Rectangle())
                .offset(
                    x: startX - (handleVisibleWidth + handleOutsidePadding + handleInsidePadding) / 2 + handleInsidePadding,
                    y: (size.height - handleHeight) / 2
                )
                .gesture(startEdgeDrag(width: timeline.width))

                // Right edge.
                ZStack {
                    Color.clear
                    draftTrimHandle(isStart: false)
                }
                .frame(width: handleVisibleWidth + handleOutsidePadding + handleInsidePadding, height: handleHeight)
                .contentShape(Rectangle())
                .offset(
                    x: endX - (handleVisibleWidth + handleOutsidePadding + handleInsidePadding) / 2 - handleInsidePadding,
                    y: (size.height - handleHeight) / 2
                )
                .gesture(endEdgeDrag(width: timeline.width))
            }

            // Frame tooltip — appears above the handle while dragging.
            if let edge = draggingEdge {
                let seconds = edge == .start ? range.startSeconds : range.endSeconds
                let x = timeline.xPosition(for: seconds)
                HandleFrameTooltip(
                    seconds: seconds,
                    xPosition: x,
                    thumbnails: thumbnails
                )
            }
        }
        .frame(width: width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(width >= 8)
    }

    private func bodyDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                let base = bodyDragBaseStart ?? range.startSeconds
                if bodyDragBaseStart == nil { bodyDragBaseStart = base }
                let delta = Double(value.translation.width / width) * timeline.duration
                onMove?(base + delta)
            }
            .onEnded { _ in bodyDragBaseStart = nil }
    }

    /// Left edge — drag to change the draft's start. Calls `onResizeStart`
    /// with the proposed new start time; the parent clamps.
    private func startEdgeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                if startEdgeBase == nil { startEdgeBase = range.startSeconds; draggingEdge = .start }
                let base = startEdgeBase ?? range.startSeconds
                let delta = Double(value.translation.width / width) * timeline.duration
                onResizeStart?(base + delta)
            }
            .onEnded { _ in startEdgeBase = nil; draggingEdge = nil }
    }

    /// Right edge — drag to change the draft's end. Calls `onResizeEnd`.
    private func endEdgeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                if endEdgeBase == nil { endEdgeBase = range.endSeconds; draggingEdge = .end }
                let base = endEdgeBase ?? range.endSeconds
                let delta = Double(value.translation.width / width) * timeline.duration
                onResizeEnd?(base + delta)
            }
            .onEnded { _ in endEdgeBase = nil; draggingEdge = nil }
    }

    /// Visual handle for the draft edges — same pill shape as the committed
    /// clip handles, but with a dashed accent border to match the draft body.
    private func draftTrimHandle(isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(AppPalette.background)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(AppPalette.accent, lineWidth: 1.5)
            }
            .overlay {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(AppPalette.accent)
                            .frame(width: 6, height: 1.5)
                    }
                }
                .environment(\.layoutDirection, isStart ? .rightToLeft : .leftToRight)
            }
            .shadow(color: Color.black.opacity(0.32), radius: 5, y: 2)
    }
}

/// Which timeline edge is being dragged — used by the frame tooltip.
enum DraggingEdge {
    case start
    case end
}

/// Frame thumbnail tooltip shown above a handle while the user drags it
/// along the timeline. Displays the nearest source video frame + timecode.
/// Appears above the strip (negative y offset), centered on the handle's
/// x-position. Auto-disappears when the drag ends.
struct HandleFrameTooltip: View {
    let seconds: Double
    let xPosition: CGFloat
    let thumbnails: [MediaThumbnail]

    private var closestThumbnail: MediaThumbnail? {
        guard !thumbnails.isEmpty else { return nil }
        return thumbnails.min {
            abs($0.timeSeconds - seconds) < abs($1.timeSeconds - seconds)
        }
    }

    var body: some View {
        if let thumb = closestThumbnail {
            VStack(spacing: 0) {
                Image(uiImage: thumb.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(AppPalette.accent, lineWidth: 2)
                    }
                    .shadow(color: Color.black.opacity(0.4), radius: 6, y: 3)

                Text(ClipRangeFormatter.formatTime(seconds))
                    .font(.system(size: 10, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(AppPalette.accent, in: Capsule())
                    .offset(y: -2)
            }
            .offset(
                x: xPosition - 24, // center the 48pt-wide tooltip on the handle
                y: -50              // raise above the strip
            )
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
