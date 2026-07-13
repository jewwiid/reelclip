import SwiftUI

/// Continuous video film strip with marker overlays. Replaces the
/// previous thumbnail row + waveform combo so all interactive surface
/// (markers, planned ranges, draft highlight) lives on the same
/// canvas as the video frames.
///
/// Reuses `RangeInteractionView` and `DraftHighlightView` from
/// `WaveformStrip.swift` for the marker rendering and gesture logic
/// — the underlying math (`TimelineGeometry.xPosition(for:)`) is
/// width-agnostic, so it works against any horizontal surface.
///
/// Visual: a single horizontal strip that shows the entire video,
/// tiled continuously. Markers, draft, and edge handles are drawn
/// over it. The strip scrolls horizontally at 2x/4x zoom so the
/// user can drill into a region while keeping the same interaction
/// model.
struct VideoTimelineView: View {
    let thumbnails: [MediaThumbnail]
    let plannedRanges: [ClipRange]
    let waveformSamples: [WaveformSample]
    let duration: Double
    let scrubPosition: Double
    let draftHighlight: ClipRange?
    let frameDuration: Double
    /// 1.0 (Fit), 1.45 (2x), 2.0 (4x), 4.0 (8x) — used to scale the
    /// film strip. Driven by `TimelineZoom.thumbnailScale`.
    let thumbnailScale: Double
    let selectedRangeIndex: Int?
    /// The main player is advancing. Auto-follow is deliberately gated to
    /// playback so a paused user can inspect or manually scroll the timeline
    /// without it snapping back beneath their finger.
    let isPlaybackActive: Bool

    let onTap: (Double) -> Void
    let onSelectRange: (Int) -> Void
    let onUpdateRange: (Int, ClipRange) -> Void
    let onToggleRangeLock: (Int) -> Void
    /// Called when the user drags the body of a selected planned
    /// range. The argument is the new playhead position in
    /// seconds, clamped to the range. Drives preview scrubbing
    /// within the highlighted portion (replaces the old
    /// "body drag moves the range" gesture — edge handles do
    /// that now).
    let onScrub: (Double) -> Void
    let onMoveDraft: (Double) -> Void
    let onResizeDraftStart: (Double) -> Void
    let onResizeDraftEnd: (Double) -> Void
    /// Called continuously while the user drags an edge handle
    /// (start or end, on any planned range or the draft
    /// highlight). The argument is the seconds at the handle —
    /// the parent view wires this to the big video preview
    /// above so the user sees the exact frame they're about to
    /// commit in the larger view instead of a small tooltip
    /// pinned to the timeline (which we used to render here,
    /// and which consumed 58pt of vertical real-estate).
    let onEdgeDragPreview: (Double) -> Void
    /// Hold-to-play affordance. Fires with `true` when the user
    /// has held a finger on the timeline past the
    /// `LongPressGesture` threshold (currently 0.4s) and
    /// hasn't started dragging yet — the parent uses this to
    /// start preview playback without scrolling up to the
    /// play button. Fires with `false` on release, or as soon
/// as a drag starts (so the existing tap/scrub paths —
                    // which call `pause: true` — win the moment the user
                    // starts moving).

    /// Strip height — fits a 56pt thumbnail with a 4pt top inset.
    private let stripHeight: CGFloat = 64
    private let waveformHeight: CGFloat = 48
    private let trackSpacing: CGFloat = 8
    private var trackHeight: CGFloat { stripHeight + trackSpacing + waveformHeight }
    private var totalHeight: CGFloat { trackHeight }
    @State private var longPressSelectedRangeIndex: Int?
    @State private var lastAutoFollowSeconds: Double?

    private let playheadScrollAnchorID = "video-timeline-playhead"

    var body: some View {
        GeometryReader { outer in
            let contentWidth = timelineContentWidth(for: outer.size.width)
            let timelineSize = CGSize(width: contentWidth, height: stripHeight)
            let isHorizontallyScrollable = contentWidth > outer.size.width + 1

            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: trackSpacing) {
                        ZStack(alignment: .topLeading) {
                            Color.black

                            if let timeline = TimelineGeometry(
                                size: timelineSize,
                                duration: duration
                            ) {
                                filmStrip(timeline: timeline)
                                plannedRangeBands(timeline: timeline)

                                if let draft = draftHighlight {
                                    DraftHighlightView(
                                        range: draft,
                                        timeline: timeline,
                                        size: timelineSize,
                                        thumbnails: thumbnails,
                                        onMove: onMoveDraft,
                                        onResizeEnd: onResizeDraftEnd,
                                        onResizeStart: onResizeDraftStart,
                                        onEdgeDragPreview: onEdgeDragPreview
                                    )
                                }

                                ForEach(Array(plannedRanges.enumerated()), id: \.offset) { index, range in
                                    rangeInteractionView(
                                        index: index,
                                        range: range,
                                        timeline: timeline,
                                        timelineSize: timelineSize
                                    )
                                }

                                scrubIndicator(timeline: timeline, height: stripHeight)
                            }
                        }
                        .frame(width: contentWidth, height: stripHeight, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                        // A direct frame tap must win over the transparent
                        // planned-range overlays. Those overlays still own
                        // their drag gestures for editing in/out points, but
                        // a normal tap now seeks on the first attempt.
                        .highPriorityGesture(tapGesture(contentWidth: contentWidth))

                        WaveformStrip(
                            samples: waveformSamples,
                            plannedRanges: plannedRanges,
                            duration: duration,
                            scrubPosition: scrubPosition,
                            onScrub: onScrub,
                            selectedRangeIndex: selectedRangeIndex,
                            frameDuration: frameDuration,
                            onSelectRange: { _ in },
                            onUpdateRange: { _, _ in },
                            onTap: onTap,
                            draftHighlight: draftHighlight,
                            onMoveDraft: { _ in },
                            onResizeDraftStart: { _ in },
                            onResizeDraftEnd: { _ in },
                            thumbnails: thumbnails,
                            stripHeight: waveformHeight
                        )
                        .frame(width: contentWidth, height: waveformHeight)
                    }
                    .frame(width: contentWidth, height: trackHeight, alignment: .topLeading)
                    .background(alignment: .topLeading) {
                        playheadScrollAnchor(contentWidth: contentWidth)
                    }
                }
                // Constrain the ScrollView to the visible width — without this it
                // sizes to its content's intrinsic width (== contentWidth) and
                // there's nothing to scroll past at 2x/4x zoom. The inner ZStack
                // above still spans `contentWidth`, so the wider strip scrolls
                // inside the visible window.
                .frame(width: outer.size.width, height: totalHeight)
                // Fit mode must be a fixed canvas. Previously this ScrollView
                // remained active at Fit, producing an empty horizontal
                // rubber-band even though the timeline had no overflow.
                // Zoomed timelines retain deliberate horizontal navigation.
                .scrollDisabled(!isHorizontallyScrollable)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onChange(of: scrubPosition) { _, _ in
                    followPlayhead(
                        using: scrollProxy,
                        visibleWidth: outer.size.width,
                        contentWidth: contentWidth
                    )
                }
                .onChange(of: isPlaybackActive) { _, active in
                    lastAutoFollowSeconds = nil
                    guard active else { return }
                    followPlayhead(
                        using: scrollProxy,
                        visibleWidth: outer.size.width,
                        contentWidth: contentWidth,
                        force: true
                    )
                }
                .onChange(of: thumbnailScale) { _, _ in
                    lastAutoFollowSeconds = nil
                    followPlayhead(
                        using: scrollProxy,
                        visibleWidth: outer.size.width,
                        contentWidth: contentWidth,
                        force: true
                    )
                }
                .onAppear {
                    followPlayhead(
                        using: scrollProxy,
                        visibleWidth: outer.size.width,
                        contentWidth: contentWidth,
                        force: true
                    )
                }
                .background(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                        .frame(height: trackHeight)
                }
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                        .frame(height: trackHeight)
                }
            }
        }
        .frame(height: totalHeight)
    }

    @ViewBuilder
    private func rangeInteractionView(
        index: Int,
        range: ClipRange,
        timeline: TimelineGeometry,
        timelineSize: CGSize
    ) -> some View {
        RangeInteractionView(
            index: index,
            range: range,
            timeline: timeline,
            size: timelineSize,
            isSelected: index == selectedRangeIndex,
            frameDuration: frameDuration,
            thumbnails: thumbnails,
            onSelectRange: onSelectRange,
            onUpdateRange: onUpdateRange,
            onToggleLock: onToggleRangeLock,
            onEdgeDragPreview: onEdgeDragPreview,
            onScrub: onScrub,
            onTapPosition: onTap
        )
    }

    /// A layout-backed scroll target at the current playhead. Unlike an
    /// offset-only marker, this gives ScrollViewReader a real horizontal
    /// position to keep visible as playback advances.
    private func playheadScrollAnchor(contentWidth: CGFloat) -> some View {
        let safeWidth = max(contentWidth, 1)
        let ratio = duration > 0 && scrubPosition.isFinite
            ? min(max(scrubPosition / duration, 0), 1)
            : 0
        let leadingWidth = min(max(safeWidth * CGFloat(ratio), 0), safeWidth - 1)

        return HStack(spacing: 0) {
            Color.clear.frame(width: leadingWidth, height: 1)
            Color.clear
                .frame(width: 1, height: 1)
                .id(playheadScrollAnchorID)
            Color.clear.frame(width: max(safeWidth - leadingWidth - 1, 0), height: 1)
        }
        .frame(width: safeWidth, height: 1, alignment: .leading)
        .allowsHitTesting(false)
    }

    private func followPlayhead(
        using proxy: ScrollViewProxy,
        visibleWidth: CGFloat,
        contentWidth: CGFloat,
        force: Bool = false
    ) {
        guard isPlaybackActive,
              duration.isFinite,
              duration > 0,
              visibleWidth.isFinite,
              visibleWidth > 0,
              contentWidth.isFinite,
              contentWidth > visibleWidth + 1,
              scrubPosition.isFinite
        else {
            return
        }

        // Seeking or starting playback follows immediately. During steady
        // playback, move only once the playhead has travelled nearly half a
        // viewport. That keeps it visible without issuing 30 scroll requests
        // per second from the AVPlayer time observer.
        let visibleDuration = duration * Double(visibleWidth / contentWidth)
        let minimumAdvance = max(visibleDuration * 0.45, 0.5)
        if !force,
           let lastAutoFollowSeconds,
           abs(scrubPosition - lastAutoFollowSeconds) < minimumAdvance {
            return
        }

        lastAutoFollowSeconds = scrubPosition
        withAnimation(.linear(duration: 0.16)) {
            proxy.scrollTo(playheadScrollAnchorID, anchor: .center)
        }
    }

    @ViewBuilder
    private func plannedRangeBands(timeline: TimelineGeometry) -> some View {
        ForEach(Array(plannedRanges.enumerated()), id: \.offset) { index, range in
            let startX = timeline.xPosition(for: range.startSeconds)
            let endX = timeline.xPosition(for: range.endSeconds)
            let width = max(endX - startX, 1)
            let isSelected = index == selectedRangeIndex

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppPalette.accent.opacity(isSelected ? 0.30 : 0.18))
                    .frame(width: width, height: stripHeight)

                Rectangle()
                    .fill(AppPalette.accent.opacity(isSelected ? 0.95 : 0.72))
                    .frame(width: width, height: 3)

                Rectangle()
                    .fill(AppPalette.accent.opacity(isSelected ? 0.95 : 0.72))
                    .frame(width: width, height: 3)
                    .offset(y: stripHeight - 3)

                rangeEdgeMarker(color: AppPalette.success)
                    .offset(x: 0, y: (stripHeight - 22) / 2)
                rangeEdgeMarker(color: AppPalette.danger)
                    .offset(x: width - 2, y: (stripHeight - 22) / 2)
            }
            .offset(x: startX)
            .allowsHitTesting(false)
        }
    }

    private func rangeEdgeMarker(color: Color) -> some View {
        Capsule()
            .fill(color.opacity(0.9))
            .frame(width: 2, height: 22)
    }

    // MARK: - Film strip

    /// Render each thumbnail over its source-time segment. Each frame owns
    /// the time span halfway to its neighbouring thumbnail samples.
    /// That keeps the strip visually continuous and prevents the first/last
    /// frames from being clipped to half width.
    @ViewBuilder
    private func filmStrip(timeline: TimelineGeometry) -> some View {
        let orderedThumbnails = thumbnails.sorted { $0.timeSeconds < $1.timeSeconds }

        ZStack(alignment: .topLeading) {
            ForEach(Array(orderedThumbnails.enumerated()), id: \.element.id) { index, thumb in
                let previousBoundary = index == 0
                    ? 0
                    : (orderedThumbnails[index - 1].timeSeconds + thumb.timeSeconds) / 2
                let nextBoundary = index == orderedThumbnails.count - 1
                    ? timeline.duration
                    : (thumb.timeSeconds + orderedThumbnails[index + 1].timeSeconds) / 2
                let leftX = timeline.xPosition(for: previousBoundary)
                let rightX = timeline.xPosition(for: nextBoundary)
                let width = max(rightX - leftX, 1)

                Image(uiImage: thumb.image)
                    .resizable()
                    // Fill each time cell. Letterboxing a narrow source frame
                    // inside a wide cell creates black blocks that look like
                    // missing first frames in the preview timeline.
                    .scaledToFill()
                    .frame(width: width + 0.5, height: stripHeight)
                    .clipped()
                    .offset(x: leftX, y: 0)
            }
        }
        // `offset(x:)` changes drawing position, not the ZStack's measured
        // width. Without a leading frame alignment SwiftUI centres that
        // narrow measured stack inside the full timeline, leaving roughly
        // half the strip black before the first thumbnail appears.
        .frame(width: timeline.width, height: stripHeight, alignment: .topLeading)
    }

    private func scrubIndicator(timeline: TimelineGeometry, height: CGFloat) -> some View {
        // Vertical pill — same design family as the trim handles (white
        // pill + accent border) and the range boundary markers (small
        // colored pill). Width 3pt, full strip height, accent fill so
        // the playhead reads as "this is the current position" without
        // fighting the handle visual language.
        let x = timeline.xPosition(for: scrubPosition)
        return Capsule()
            .fill(AppPalette.accent)
            .frame(width: 3, height: height)
            .offset(x: x - 1.5, y: 0)
            .allowsHitTesting(false)
    }

    // MARK: - Coordinate mapping

    private func timelineContentWidth(for visibleWidth: CGFloat) -> CGFloat {
        guard visibleWidth.isFinite, visibleWidth > 0 else { return 1 }
        let safeScale = thumbnailScale.isFinite ? max(thumbnailScale, 1) : 1
        return visibleWidth * CGFloat(safeScale)
    }

    private func time(forXPosition xPosition: CGFloat, contentWidth: CGFloat) -> Double {
        guard duration.isFinite,
              duration > 0,
              xPosition.isFinite,
              contentWidth.isFinite,
              contentWidth > 0
        else {
            return 0
        }

        let clampedX = min(max(xPosition, 0), contentWidth)
        return duration * Double(clampedX / contentWidth)
    }

    // MARK: - Timeline gestures

    private func tapGesture(contentWidth: CGFloat) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                onTap(time(forXPosition: value.location.x, contentWidth: contentWidth))
            }
    }

    /// Hold a finger on the strip to select the planned range
    /// under the press point. The press is resolved to a time via
    /// the strip's coordinate system; if any planned range contains
    /// that time it becomes the selected range. Long press on empty
    /// timeline space is a no-op (so the user can still seek via
    /// the tap gesture without accidentally selecting a range).
    private func longPressGesture(contentWidth: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    let time = time(forXPosition: drag.location.x, contentWidth: contentWidth)
                    if let index = plannedRanges.firstIndex(where: {
                        time >= $0.startSeconds && time <= $0.endSeconds
                    }), longPressSelectedRangeIndex != index {
                        longPressSelectedRangeIndex = index
                        onSelectRange(index)
                    }
                }
            }
            .onEnded { _ in
                longPressSelectedRangeIndex = nil
            }
    }
}
