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
    /// Fires when the user taps empty timeline space (no drag).
    /// The argument is the time (in seconds) under the tap point.
    /// Used to drive the parent's "tap outside deselects" logic
    /// — without this the waveform's `DragGesture(minimumDistance: 0)`
    /// eats every touch as a scrub and never tells the parent that
    /// the user wanted to deselect.
    var onTap: ((Double) -> Void)? = nil
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
    var stripHeight: CGFloat = 52

    @ViewBuilder
    private func draftHighlightLayer(timeline: TimelineGeometry, size: CGSize) -> some View {
        if let draft = draftHighlight {
            // Draft highlight — drawn first so planned ranges paint
            // on top (gives the visual hierarchy: working selection
            // is "above" the timeline, committed clips are solid).
            // The inner WaveformStrip is for audio-only context
            // (the slider row beneath the film strip) and does
            // not own a big video preview — its edge drag is a
            // no-op.
            DraftHighlightView(
                range: draft,
                timeline: timeline,
                size: size,
                thumbnails: thumbnails,
                onMove: onMoveDraft,
                onResizeEnd: onResizeDraftEnd,
                onResizeStart: onResizeDraftStart,
                onEdgeDragPreview: nil
            )
        }
    }

    @ViewBuilder
    private func plannedRangeLayer(timeline: TimelineGeometry, size: CGSize) -> some View {
        if !plannedRanges.isEmpty {
            ForEach(Array(plannedRanges.enumerated()), id: \.offset) { index, range in
                RangeInteractionView(
                    index: index,
                    range: range,
                    timeline: timeline,
                    size: size,
                    isSelected: index == selectedRangeIndex,
                    frameDuration: frameDuration,
                    thumbnails: thumbnails,
                    onSelectRange: onSelectRange,
                    onUpdateRange: onUpdateRange,
                    onToggleLock: nil,
                    onEdgeDragPreview: nil,
                    onScrub: onScrub,
                    onTapPosition: onTap
                )
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                waveformCanvas(size: proxy.size)
                if let timeline = TimelineGeometry(size: proxy.size, duration: duration) {
                    draftHighlightLayer(timeline: timeline, size: proxy.size)
                    plannedRangeLayer(timeline: timeline, size: proxy.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrub(at: value.location.x, width: proxy.size.width)
                    }
                    .onEnded { value in
                        // The waveform's drag eats every touch, so
                        // we have to detect "tap" ourselves by
                        // checking the total drag distance on end.
                        // Below the threshold, treat it as a tap
                        // and forward to the parent's onTap so the
                        // deselect logic fires. Threshold matches
                        // the iOS system tap tolerance (~10pt) so
                        // intentional drags still scrub freely.
                        let dragDistance = hypot(value.translation.width, value.translation.height)
                        guard dragDistance < 10 else { return }
                        guard duration.isFinite,
                              duration > 0,
                              proxy.size.width.isFinite,
                              proxy.size.width > 0
                        else { return }
                        let ratio = min(max(Double(value.location.x / proxy.size.width), 0), 1)
                        onTap?(duration * ratio)
                    }
            )
        }
        .frame(height: stripHeight)
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

                drawRangeBoundaryMarker(
                    context: context,
                    size: size,
                    xPosition: startX,
                    color: AppPalette.success,
                    isSelected: isSelected
                )
                drawRangeBoundaryMarker(
                    context: context,
                    size: size,
                    xPosition: endX,
                    color: AppPalette.danger,
                    isSelected: isSelected
                )

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

                    // AI-selected badge: a small sparkles icon to the right of
                    // the clip number, marking this range as AI-suggested (vs a
                    // purely user-selected range which has no reason attached).
                    if range.reason != nil {
                        let sparklesOrigin = CGPoint(x: startX + 22, y: 6)
                        context.draw(
                            Text(Image(systemName: "sparkles"))
                                .font(.caption2)
                                .foregroundStyle(AppPalette.background),
                            at: sparklesOrigin,
                            anchor: .topLeading
                        )
                    }
                }
            }

            // 4. Scrub indicator — vertical pill, same design family as the
            // trim handles and range boundary markers. Slim accent pill,
            // full strip height, drawn on top of the waveform so the
            // current playhead is always visible.
            let scrubX = timeline.xPosition(for: scrubPosition)
            let scrubPillWidth: CGFloat = 3
            let scrubPillRect = CGRect(
                x: scrubX - scrubPillWidth / 2,
                y: 0,
                width: scrubPillWidth,
                height: size.height
            )
            let scrubPillPath = Path(
                roundedRect: scrubPillRect,
                cornerRadius: scrubPillWidth / 2,
                style: .continuous
            )
            context.fill(scrubPillPath, with: .color(AppPalette.accent))
        }
    }

    private func drawRangeBoundaryMarker(
        context: GraphicsContext,
        size: CGSize,
        xPosition: CGFloat,
        color: Color,
        isSelected: Bool
    ) {
        // Small vertical pill — same design family as the trim handles
        // (white pill + accent border) and the scrub indicator (accent
        // pill). Width + height grow slightly when the range is selected
        // so the marker has a subtle "this one is active" affordance
        // without changing the visual language.
        guard size.width > 0, size.height > 0, xPosition.isFinite else { return }

        let pillWidth: CGFloat = isSelected ? 2.4 : 1.8
        let pillHeight: CGFloat = isSelected ? 22 : 16
        let pillOpacity: Double = isSelected ? 0.95 : 0.72
        let halfWidth = pillWidth / 2
        let clampedX = min(
            max(xPosition, halfWidth),
            max(halfWidth, size.width - halfWidth)
        )
        let yOffset = (size.height - pillHeight) / 2
        let pillRect = CGRect(
            x: clampedX - halfWidth,
            y: yOffset,
            width: pillWidth,
            height: pillHeight
        )
        let pillPath = Path(
            roundedRect: pillRect,
            cornerRadius: halfWidth,
            style: .continuous
        )
        context.fill(pillPath, with: .color(color.opacity(pillOpacity)))
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
    /// Called when the user long-presses the body. Toggles the lock state
    /// of the planned clip — the parent view model handles the actual
    /// mutation; this view just fires the callback.
    let onToggleLock: ((Int) -> Void)?
    /// Called continuously while the user drags an edge handle. The
    /// argument is the current seconds at the handle (start edge →
    /// new `range.startSeconds`; end edge → new `range.endSeconds`).
    /// The parent wires this to the big video preview above so the
    /// user sees the exact frame they're about to commit in the
    /// larger view instead of a small tooltip pinned to the
    /// timeline. Previously this fired `(position, seconds)` to
    /// drive a frame-thumbnail tooltip overlay; that overlay is
    /// gone (collapses the timeline's vertical footprint by the
    /// tooltip-clearance) and the bigger preview is the new
    /// feedback surface.
    let onEdgeDragPreview: ((Double) -> Void)?
    /// Called continuously while the user drags the body of a
    /// selected range. The argument is the new playhead position
    /// in source seconds, clamped to `[range.startSeconds,
    /// range.endSeconds]`. The parent view model routes this
    /// through `updateScrubPosition` so the preview seeks live.
    /// Replaces the old "body drag moves the range" gesture — the
    /// edge handles above still control in/out, so the body
    /// gesture is free to do something more useful.
    let onScrub: ((Double) -> Void)?
    /// The selected range covers the main film strip, so its own tap gesture
    /// must forward the exact point to the parent instead of only selecting
    /// the range and swallowing the timeline's seek gesture.
    let onTapPosition: ((Double) -> Void)?

    @State private var startDragBase: ClipRange?
    @State private var endDragBase: ClipRange?
    /// Playhead position at the start of a body scrub drag. We
    /// stash it on `.onChanged` (first call) so subsequent updates
    /// compute the new position relative to where the drag began,
    /// not where the previous frame was. Without this, fast drags
    /// accumulate sub-frame drift.
    @State private var scrubDragBase: Double? = nil

    // Visual handles are intentionally tiny; the transparent hit zones below
    // are larger and split at the range midpoint when the edges get close.
    // That keeps both edges draggable even on very short clips.
    //
    // Hit zones are sized so the user can ALWAYS recover from an
    // over-eager trim — even when the body is collapsed to near-zero
    // width, each edge has a guaranteed 8pt of grab room outside the
    // body and 4pt inside. Earlier sizing (4pt visible / 6pt outside
    // / 3pt inside) collapsed to sub-pixel hit zones when the body
    // shrank past a frame, and the user had to delete + replan the
    // range to recover. This sizing keeps the handles grabbable no
    // matter how narrow the body.
    private let handleVisibleWidth: CGFloat = 6
    private let handleHeight: CGFloat = 22
    private let handleOutsidePadding: CGFloat = 8
    private let handleInsidePadding: CGFloat = 4
    /// Minimum body width in seconds. The edge drag handlers clamp
    /// to this so the user can never collapse a range below a
    /// usable size — even if the underlying ClipRangeEditor minimum
    /// is 0.05s, we don't let the user get to a state where the
    // handle hit zones are visually overlapping.
    private let minHandleRangeDuration: Double = 0.5

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
            //
            // Long-press anywhere on the body toggles the lock state for
            // this clip. Locked clips can't be moved or trimmed — useful
            // when you're adjusting neighboring clips and don't want to
            // accidentally bump this one. The long-press is a separate
            // gesture from the drag, so quick taps + drags still work
            // exactly as before; only a held press (≥ 0.5s without
            // movement) triggers the lock.
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: width, height: size.height)
                .offset(x: startX, y: 0)
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    onSelectRange?(index)
                    let relativeX = min(max(value.location.x / max(width, 1), 0), 1)
                    let seconds = range.startSeconds + (range.endSeconds - range.startSeconds) * Double(relativeX)
                    onTapPosition?(seconds)
                })
                .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 30) {
                    guard let toggle = onToggleLock else { return }
                    PolishKit.Haptics.success.play()
                    toggle(index)
                }
                .simultaneousGesture(bodyDrag(width: timeline.width))

            // Lock icon — appears in the centre of the body when the
            // clip is locked. Hidden when unlocked. Sized to match the
            // handle grip affordance and gated on `width >= 28` so a
            // locked micro-clip doesn't get a lock icon overlapping
            // its handle. `.allowsHitTesting(false)` so the icon never
            // intercepts a body tap.
            if range.isLocked && width >= 28 {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 14, height: 14)
                    .offset(
                        x: startX + width / 2 - 7,
                        y: (size.height - 14) / 2
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if isSelected {
                let hitZones = edgeHandleHitZones(
                    startX: startX,
                    endX: endX,
                    trackWidth: timeline.width,
                    outsideReach: handleOutsidePadding,
                    insideReach: handleInsidePadding + handleVisibleWidth
                )
                let hitHeight = min(size.height, max(handleHeight, 34))
                let hitY = (size.height - hitHeight) / 2
                let visualY = (size.height - handleHeight) / 2

                trimHandle(isStart: true)
                    .frame(width: handleVisibleWidth, height: handleHeight)
                    .offset(
                        x: min(max(startX - handleVisibleWidth / 2, 0), max(0, timeline.width - handleVisibleWidth)),
                        y: visualY
                    )
                    .allowsHitTesting(false)
                    .zIndex(2)

                trimHandle(isStart: false)
                    .frame(width: handleVisibleWidth, height: handleHeight)
                    .offset(
                        x: min(max(endX - handleVisibleWidth / 2, 0), max(0, timeline.width - handleVisibleWidth)),
                        y: visualY
                    )
                    .allowsHitTesting(false)
                    .zIndex(2)

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: hitZones.startWidth, height: hitHeight)
                    .contentShape(Rectangle())
                    .offset(x: hitZones.startX, y: hitY)
                    .zIndex(3)
                    .gesture(startHandleDrag(width: timeline.width))

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: hitZones.endWidth, height: hitHeight)
                    .contentShape(Rectangle())
                    .offset(x: hitZones.endX, y: hitY)
                    .zIndex(3)
                    .gesture(endHandleDrag(width: timeline.width))
            }

            // Frame tooltip is rendered OUTSIDE this view by
            // VideoTimelineView, in an overlay above the clip
            // shape. Rendering it here would put it inside the
            // timeline's rounded-rect clip and clip the frame
            // preview behind the container border. The drag
            // callbacks above push the active position via
            // `onEdgeDragChange`, and the parent reads it.
        }
        .frame(width: timeline.width, height: size.height, alignment: .topLeading)
        // Keep hit testing alive even for sub-pixel ranges. The split
        // transparent edge zones below are the recovery path when a
        // user trims a clip very narrow; disabling the whole view here
        // made those handles impossible to grab again.
        .allowsHitTesting(true)
    }

    /// Body-drag — slide the whole range without resizing. Snaps so the
    /// resulting range stays on frame boundaries.
    /// `minimumDistance: 4` so taps (down + up, <4pt) register as taps for
    /// `onSelectRange`; anything ≥4pt is a scrub drag.
    /// Body drag now scrubs the playhead within the selected
    /// range — translating the body moves the preview's playhead
    /// from `range.startSeconds` toward `range.endSeconds` (or
    /// back). The edge handles above still control the range's
    /// in/out points, so the body gesture is free to do
    /// something more useful. We deliberately do NOT block on
    /// `range.isLocked` — a locked clip should still be
    /// previewable at any of its positions, and the lock only
    /// means "don't move / resize me".
    private func bodyDrag(width: CGFloat) -> some Gesture {
        let totalDuration = timeline.duration
        return DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let scrub = onScrub,
                      isSelected,
                      totalDuration.isFinite,
                      totalDuration > 0,
                      width.isFinite,
                      width > 0
                else { return }
                if scrubDragBase == nil { scrubDragBase = range.startSeconds }
                guard let baseSeconds = scrubDragBase else { return }
                // Map drag distance to source seconds. The body
                // spans `range.endSeconds - range.startSeconds`
                // horizontally; translating the full width of the
                // body moves the playhead across the whole range.
                let bodyWidth = width * CGFloat((range.endSeconds - range.startSeconds) / totalDuration)
                guard bodyWidth > 0 else { return }
                let delta = Double(value.translation.width / bodyWidth) * (range.endSeconds - range.startSeconds)
                let proposed = baseSeconds + delta
                let clamped = min(max(proposed, range.startSeconds), range.endSeconds)
                scrub(clamped)
            }
            .onEnded { _ in
                scrubDragBase = nil
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
                // Locked clips ignore the handle drag — the user has
                // to long-press to unlock first.
                guard !range.isLocked,
                      totalDuration.isFinite, totalDuration > 0,
                      width.isFinite, width > 0
                else { return }
                if startDragBase == nil { startDragBase = range }
                let base = startDragBase ?? range
                let delta = Double(value.translation.width / width) * totalDuration
                // Clamp the proposed start so the body stays at
                // least `minHandleRangeDuration` seconds wide. The
                // underlying ClipRangeEditor minimum is much
                // smaller (~0.05s) which is below the visual
                // handle hit zone threshold — without this clamp
                // the user can collapse the body past the point
                // where either handle is grabbable and there's no
                // way to recover short of deleting + replanning the
                // range. 0.5s matches the smallest body width that
                // keeps both hit zones ≥ 8pt on a typical 30s video
                // at 1x zoom.
                let proposedStart = base.startSeconds + delta
                let maxStart = max(0, base.endSeconds - minHandleRangeDuration)
                let minStart = min(maxStart, base.endSeconds - minHandleRangeDuration)
                let clampedStart = min(max(proposedStart, minStart), maxStart)
                let edited = ClipRangeEditor.updatedRange(
                    base,
                    totalDuration: totalDuration,
                    frameDuration: frameDuration,
                    startSeconds: clampedStart
                )
                onUpdateRange?(index, edited)
                // Fire the edge-preview callback with the current
                // handle position (seconds at the new edge). The
                // parent routes this to the big video preview
                // above so the user sees the exact frame they're
                // about to commit in the larger view, instead of
                // a small tooltip pinned to the timeline.
                onEdgeDragPreview?(edited.startSeconds)
            }
            .onEnded { _ in
                startDragBase = nil
            }
    }

    private func endHandleDrag(width: CGFloat) -> some Gesture {
        let totalDuration = timeline.duration
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Locked clips ignore the handle drag — the user has
                // to long-press to unlock first.
                guard !range.isLocked,
                      totalDuration.isFinite, totalDuration > 0,
                      width.isFinite, width > 0
                else { return }
                if endDragBase == nil { endDragBase = range }
                let base = endDragBase ?? range
                let delta = Double(value.translation.width / width) * totalDuration
                // Symmetric clamp to the start-handle drag: keep the
                // body ≥ `minHandleRangeDuration` seconds wide so
                // the user can't collapse past the threshold where
                // the hit zones overlap into a sub-pixel sliver.
                let proposedEnd = base.endSeconds + delta
                let minEnd = max(minHandleRangeDuration, base.startSeconds + minHandleRangeDuration)
                let maxEnd = totalDuration
                let clampedEnd = min(max(proposedEnd, minEnd), maxEnd)
                let edited = ClipRangeEditor.updatedRange(
                    base,
                    totalDuration: totalDuration,
                    frameDuration: frameDuration,
                    endSeconds: clampedEnd
                )
                onUpdateRange?(index, edited)
                onEdgeDragPreview?(edited.endSeconds)
            }
            .onEnded { _ in
                endDragBase = nil
            }
    }
}

/// Visual shape for a trim handle on the waveform: a white pill with an accent
/// border and three short horizontal grab lines. When `mirrored` is true the
/// grab lines face left (start handle), otherwise they face right (end handle).
private struct TrimHandleShape: View {
    var mirrored: Bool = false

    var body: some View {
        ReelClipRangeHandle(
            width: 6,
            height: 22,
            mirrored: mirrored,
            gripLineCount: 3,
            isInteractive: false
        )
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

private struct EdgeHandleHitZones {
    let startX: CGFloat
    let startWidth: CGFloat
    let endX: CGFloat
    let endWidth: CGFloat
}

private func edgeHandleHitZones(
    startX: CGFloat,
    endX: CGFloat,
    trackWidth: CGFloat,
    outsideReach: CGFloat,
    insideReach: CGFloat
) -> EdgeHandleHitZones {
    guard trackWidth.isFinite, trackWidth > 0 else {
        return EdgeHandleHitZones(startX: 0, startWidth: 1, endX: 0, endWidth: 1)
    }

    let safeStart = min(max(min(startX, endX), 0), trackWidth)
    let safeEnd = min(max(max(startX, endX), 0), trackWidth)
    let clipWidth = max(safeEnd - safeStart, 0)
    let halfClipWidth = clipWidth / 2
    let safeOutsideReach = max(outsideReach, 0)
    let safeInsideReach = max(insideReach, 0)
    let insideOverlapLimit = min(safeInsideReach, halfClipWidth)

    let startLeft = min(max(safeStart - safeOutsideReach, 0), trackWidth)
    let startRight = min(max(safeStart + insideOverlapLimit, startLeft), trackWidth)
    let endLeft = min(max(safeEnd - insideOverlapLimit, 0), trackWidth)
    let endRight = min(max(safeEnd + safeOutsideReach, endLeft), trackWidth)

    return EdgeHandleHitZones(
        startX: startLeft,
        startWidth: max(startRight - startLeft, 1),
        endX: endLeft,
        endWidth: max(endRight - endLeft, 1)
    )
}

enum ClipRangeFormatter {
    static func title(for range: ClipRange) -> String {
        "\(formatTime(range.startSeconds)) - \(formatTime(range.endSeconds))"
    }

    static func durationLabel(for range: ClipRange) -> String {
        guard range.duration.isFinite, range.duration >= 0 else { return "--" }
        return formatDuration(range.duration)
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

    /// Long-form duration: "5s", "5.5s" under a minute; "1m05s",
    /// "1m05.5s", "59m59s" once a minute boundary is crossed. Replaces
    /// the old "X sec" / "X.X sec" output that ran "65s" instead of
    /// "1m05s" for clips over a minute. Used in chip labels and the
    /// export preview duration column.
    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let totalTenths = Int((seconds * 10).rounded())
        let minutes = totalTenths / 600
        let secsTenths = totalTenths % 600
        let wholeSecs = secsTenths / 10
        let tenths = secsTenths % 10

        if minutes == 0 {
            // Under a minute: "5s" or "5.5s" — no leading zero on
            // the seconds, no minute prefix, no padded width.
            return tenths == 0
                ? "\(wholeSecs)s"
                : String(format: "%d.%ds", wholeSecs, tenths)
        }
        // 1+ minutes: "1m05s" / "1m05.5s". Two-digit seconds
        // with leading zero so the column reads cleanly when the
        // user scans a list.
        let secsPart = tenths == 0
            ? String(format: "%02d", wholeSecs)
            : String(format: "%02d.%d", wholeSecs, tenths)
        return "\(minutes)m\(secsPart)s"
    }
}

struct EditableClipRangeBar: View {
    let range: ClipRange
    let duration: Double
    let frameDuration: Double
    let thumbnails: [MediaThumbnail]
    let onChange: (ClipRange) -> Void
    /// Called continuously while the user drags the body of the
    /// range (the middle area between the two edge handles). The
    /// argument is the new playhead position in source seconds,
    /// clamped to `[range.startSeconds, range.endSeconds]`. The
    /// parent view model routes this through `updateScrubPosition`
    /// so the preview seeks live. Matches the body-drag behaviour
    /// of `RangeInteractionView` on the main timeline preview, so
    /// the two surfaces feel identical.
    let onScrub: ((Double) -> Void)?

    @State private var startDragBase: ClipRange?
    @State private var endDragBase: ClipRange?
    /// Playhead position at the start of a body scrub drag. We
    /// stash it on `.onChanged` (first call) so subsequent updates
    /// compute the new position relative to where the drag began,
    /// not where the previous frame was. Without this, fast drags
    /// accumulate sub-frame drift. Matches the same state on
    /// `RangeInteractionView`.
    @State private var scrubDragBase: Double? = nil

    // Match `RangeInteractionView` exactly so the two surfaces feel
    // identical: small visual handles with larger, split-at-midpoint
    // hit zones. Keeps the body grab area always present, even on
    // very short clips.
    private let handleVisibleWidth: CGFloat = 6
    private let handleHeight: CGFloat = 22
    private let handleOutsidePadding: CGFloat = 8
    private let handleInsidePadding: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let totalDuration = duration.isFinite && duration > 0 ? duration : 0.05
            let width = proxy.size.width.isFinite && proxy.size.width > 0 ? proxy.size.width : 1
            let startRatio = min(max(range.startSeconds / totalDuration, 0), 1)
            let endRatio = min(max(range.endSeconds / totalDuration, 0), 1)
            let startX = width * startRatio
            let endX = width * endRatio
            let selectedStartX = min(max(min(startX, endX), 0), width)
            let selectedEndX = min(max(max(startX, endX), 0), width)
            let selectedWidth = max(selectedEndX - selectedStartX, 0)
            let hitZones = edgeHandleHitZones(
                startX: startX,
                endX: endX,
                trackWidth: width,
                outsideReach: handleOutsidePadding,
                insideReach: handleInsidePadding
            )

            ZStack(alignment: .leading) {
                // Body — fills the space between the two edge handles
                // and serves as the middle-grab / scrub surface. Uses
                // the same accent fill as the timeline preview's
                // selected-range. Z-ordered below the handles.
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppPalette.timelineBlock)

                    if selectedWidth > 0 {
                        Rectangle()
                            .fill(AppPalette.accent.opacity(0.78))
                            .frame(width: selectedWidth)
                            .offset(x: selectedStartX)
                    }
                }
                .frame(width: width, height: handleHeight)
                .clipShape(Capsule())

                // Middle grab area — sits between the two edge handle
                // hit zones. Dragging it scrubs the playhead within
                // the range (1:1 with body width, clamped to
                // [startSeconds, endSeconds]). Mirrors the body-drag
                // behaviour of `RangeInteractionView`. `minimumDistance:
                // 4` so a tap still counts as a tap, not a drag.
                if selectedWidth > 0, onScrub != nil {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: max(selectedWidth - hitZones.startWidth - hitZones.endWidth, 0), height: handleHeight)
                        .offset(x: selectedStartX + hitZones.startWidth)
                        .zIndex(3)
                        .gesture(bodyScrubDrag(width: width, totalDuration: totalDuration, selectedStartX: selectedStartX, selectedEndX: selectedEndX))
                }

                rowTrimHandle(isStart: true)
                    .frame(width: handleVisibleWidth, height: handleHeight)
                    .offset(x: min(max(startX - handleVisibleWidth / 2, 0), width - handleVisibleWidth))
                    .allowsHitTesting(false)
                    .zIndex(2)

                rowTrimHandle(isStart: false)
                    .frame(width: handleVisibleWidth, height: handleHeight)
                    .offset(x: min(max(endX - handleVisibleWidth / 2, 0), width - handleVisibleWidth))
                    .allowsHitTesting(false)
                    .zIndex(2)

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: hitZones.startWidth, height: handleHeight)
                    .contentShape(Rectangle())
                    .offset(x: hitZones.startX)
                    .zIndex(4)
                    .gesture(startHandleDrag(totalDuration: totalDuration, width: width))

                Rectangle()
                    .fill(Color.clear)
                    .frame(width: hitZones.endWidth, height: handleHeight)
                    .contentShape(Rectangle())
                    .offset(x: hitZones.endX)
                    .zIndex(4)
                    .gesture(endHandleDrag(totalDuration: totalDuration, width: width))
                // No inline frame tooltip here — the big video
                // preview above reflects the edge being dragged
                // via the `onEdgeDragPreview` callback. The old
                // tooltip rendered a small frame thumb inside the
                // timeline strip; collapsing it removes ~58pt of
                // vertical real-estate under the timeline row
                // and gives the user a much larger view of the
                // exact frame they're about to commit.
            }
        }
        .frame(height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trim range \(ClipRangeFormatter.title(for: range))")
    }

    private func rowTrimHandle(isStart: Bool) -> some View {
        ReelClipRangeHandle(
            width: 6,
            height: 22,
            mirrored: isStart,
            gripLineCount: 2,
            isInteractive: false
        )
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

    /// Body-drag gesture for the centre of the range. Scrubs the
    /// playhead within `[range.startSeconds, range.endSeconds]` and
    /// reports the new position via `onScrub`. The translation is
    /// relative to the body width (selectedStartX…selectedEndX), not
    /// the full track — so a fast 200pt swipe moves the playhead by
    /// exactly that fraction of the clip's own duration, regardless
    /// of how short the clip is relative to the full source. Matches
    /// `RangeInteractionView.bodyDrag` semantics. `minimumDistance: 0`
    /// is required so the gesture is detected immediately on
    /// touch-down (the small body width means anything > 2pt would
    /// already feel sluggish).
    private func bodyScrubDrag(width: CGFloat, totalDuration: Double, selectedStartX: CGFloat, selectedEndX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let onScrub, totalDuration.isFinite, totalDuration > 0, width.isFinite, width > 0 else { return }
                let bodyWidth = max(selectedEndX - selectedStartX, 1)
                // Anchor the playhead at the centre of the range on
                // touch-down, then add the user's drag translation.
                // This way the playhead "follows the finger" 1:1
                // regardless of where on the body the user pressed.
                let base: Double
                if let stashed = scrubDragBase {
                    base = stashed
                } else {
                    base = (range.startSeconds + range.endSeconds) / 2
                    scrubDragBase = base
                }
                let delta = Double(value.translation.width / bodyWidth) * (range.endSeconds - range.startSeconds)
                let proposed = base + delta
                let clamped = min(max(proposed, range.startSeconds), range.endSeconds)
                onScrub(clamped)
            }
            .onEnded { _ in
                scrubDragBase = nil
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
    /// Called continuously while the user drags a draft edge
    /// handle. The argument is the current seconds at the
    /// handle. The parent routes this to the big video preview
    /// above so the user sees the exact frame they're about to
    /// commit in the larger view instead of a small tooltip
    /// pinned to the timeline. Previously this was
    /// `onEdgeDragChange` with `(position, seconds)` driving an
    /// inline frame-thumbnail tooltip; that overlay is gone.
    var onEdgeDragPreview: ((Double) -> Void)? = nil

    @State private var bodyDragBaseStart: Double? = nil
    @State private var startEdgeBase: Double? = nil
    @State private var endEdgeBase: Double? = nil
    /// True while the user is touching the body — drives the brighter
    /// fill and the centre grip affordance that tells the user
    /// "this region is draggable, not just decorative".
    @State private var isBodyPressed: Bool = false

    // Matches `RangeInteractionView`: small visual handles with larger,
    // non-overlapping hit zones so short drafts keep both edges draggable.
    private let handleVisibleWidth: CGFloat = 4
    private let handleHeight: CGFloat = 22
    private let handleOutsidePadding: CGFloat = 6
    private let handleInsidePadding: CGFloat = 3

    var body: some View {
        let startX = timeline.xPosition(for: range.startSeconds)
        let endX = timeline.xPosition(for: range.endSeconds)
        let width = max(endX - startX, 1)

        return ZStack(alignment: .topLeading) {
            // Body — drag to slide the whole draft. This uses a high-priority
            // gesture because the draft often lives inside a horizontal
            // ScrollView; without priority, grabbing the centre can pan the
            // timeline instead of moving the highlight.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AppPalette.accent.opacity(isBodyPressed ? 0.32 : 0.18))
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
                .highPriorityGesture(bodyDrag(width: timeline.width))

            // Grip affordance — appears in the centre of the body while
            // the highlight exists. It stays visible after release so the user
            // has a persistent centre target to grab again.
            if width >= 36 {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(AppPalette.accent.opacity(isBodyPressed ? 1 : 0.72))
                    .frame(width: 44, height: 34)
                    .contentShape(Rectangle())
                    .offset(
                        x: startX + width / 2 - 22,
                        y: (size.height - 34) / 2
                    )
                    .highPriorityGesture(bodyDrag(width: timeline.width))
                    .accessibilityHidden(true)
                    .zIndex(2)
            }

            // Edge handles remain active even when the draft becomes
            // visually tiny. The hit zones split at the midpoint so
            // both edges can still be recovered instead of forcing a
            // delete-and-recreate flow.
            let hitZones = edgeHandleHitZones(
                startX: startX,
                endX: endX,
                trackWidth: timeline.width,
                outsideReach: handleOutsidePadding,
                insideReach: handleInsidePadding + handleVisibleWidth
            )
            let hitHeight = min(size.height, max(handleHeight, 34))
            let hitY = (size.height - hitHeight) / 2
            let visualY = (size.height - handleHeight) / 2

            draftTrimHandle(isStart: true)
                .frame(width: handleVisibleWidth, height: handleHeight)
                .offset(
                    x: min(max(startX - handleVisibleWidth / 2, 0), max(0, timeline.width - handleVisibleWidth)),
                    y: visualY
                )
                .allowsHitTesting(false)
                .zIndex(2)

            draftTrimHandle(isStart: false)
                .frame(width: handleVisibleWidth, height: handleHeight)
                .offset(
                    x: min(max(endX - handleVisibleWidth / 2, 0), max(0, timeline.width - handleVisibleWidth)),
                    y: visualY
                )
                .allowsHitTesting(false)
                .zIndex(2)

            Rectangle()
                .fill(Color.clear)
                .frame(width: hitZones.startWidth, height: hitHeight)
                .contentShape(Rectangle())
                .offset(x: hitZones.startX, y: hitY)
                .zIndex(3)
                .highPriorityGesture(startEdgeDrag(width: timeline.width))

            Rectangle()
                .fill(Color.clear)
                .frame(width: hitZones.endWidth, height: hitHeight)
                .contentShape(Rectangle())
                .offset(x: hitZones.endX, y: hitY)
                .zIndex(3)
                .highPriorityGesture(endEdgeDrag(width: timeline.width))
        }
        .frame(width: timeline.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(true)
    }

    private func bodyDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Light up the body on the very first touch so the user
                // knows the body is interactive. This is the only place
                // isBodyPressed becomes true; the reset lives in onEnded.
                if !isBodyPressed {
                    isBodyPressed = true
                    PolishKit.Haptics.selection.play()
                }
                guard width > 0 else { return }
                let base = bodyDragBaseStart ?? range.startSeconds
                if bodyDragBaseStart == nil { bodyDragBaseStart = base }
                let delta = Double(value.translation.width / width) * timeline.duration
                onMove?(base + delta)
            }
            .onEnded { _ in
                isBodyPressed = false
                bodyDragBaseStart = nil
            }
    }

    /// Left edge — drag to change the draft's start. Calls `onResizeStart`
    /// with the proposed new start time; the parent clamps.
    private func startEdgeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                if startEdgeBase == nil { startEdgeBase = range.startSeconds }
                let base = startEdgeBase ?? range.startSeconds
                let delta = Double(value.translation.width / width) * timeline.duration
                let proposed = base + delta
                onResizeStart?(proposed)
                let seconds = min(max(proposed, 0), range.endSeconds)
                onEdgeDragPreview?(seconds)
            }
            .onEnded { _ in
                startEdgeBase = nil
            }
    }

    /// Right edge — drag to change the draft's end. Calls `onResizeEnd`.
    private func endEdgeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                if endEdgeBase == nil { endEdgeBase = range.endSeconds }
                let base = endEdgeBase ?? range.endSeconds
                let delta = Double(value.translation.width / width) * timeline.duration
                let proposed = base + delta
                onResizeEnd?(proposed)
                let seconds = min(max(proposed, range.startSeconds), timeline.duration)
                onEdgeDragPreview?(seconds)
            }
            .onEnded { _ in
                endEdgeBase = nil
            }
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

// `HandleFrameTooltip` (the small frame-thumbnail bubble that
// used to pop above a handle while the user dragged it along the
// timeline) is gone, along with the `DraggingEdge` enum that
// only existed to drive it. The bigger video preview above the
// timeline now reflects the edge being dragged via the
// `onEdgeDragPreview` callback on `RangeInteractionView` /
// `DraftHighlightView`, so the tooltip's frame thumbnail
// became redundant — the user already sees the exact frame
// they're about to commit in the larger view. Removing the
// tooltip also drops the 58pt `tooltipClearance` that
// `VideoTimelineView` previously reserved above the strip.
