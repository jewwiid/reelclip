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
    let duration: Double
    let scrubPosition: Double
    let draftHighlight: ClipRange?
    let frameDuration: Double
    /// 1.0 (Fit), 1.45 (2x), 2.0 (4x) — used to scale the film strip.
    let thumbnailScale: Double
    let selectedRangeIndex: Int?

    let onTap: (Double) -> Void
    let onSelectRange: (Int) -> Void
    let onUpdateRange: (Int, ClipRange) -> Void
    let onMoveDraft: (Double) -> Void
    let onResizeDraftStart: (Double) -> Void
    let onResizeDraftEnd: (Double) -> Void

    /// Strip height — fits a 56pt thumbnail with a 4pt top inset.
    private let stripHeight: CGFloat = 64
    @State private var longPressSelectedRangeIndex: Int?

    var body: some View {
        GeometryReader { outer in
            let contentWidth = timelineContentWidth(for: outer.size.width)
            let timelineSize = CGSize(width: contentWidth, height: stripHeight)

            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    if let timeline = TimelineGeometry(
                        size: timelineSize,
                        duration: duration
                    ) {
                        filmStrip(timeline: timeline)

                        if let draft = draftHighlight {
                            DraftHighlightView(
                                range: draft,
                                timeline: timeline,
                                size: timelineSize,
                                thumbnails: thumbnails,
                                onMove: onMoveDraft,
                                onResizeEnd: onResizeDraftEnd,
                                onResizeStart: onResizeDraftStart
                            )
                        }

                        ForEach(Array(plannedRanges.enumerated()), id: \.offset) { index, range in
                            RangeInteractionView(
                                index: index,
                                range: range,
                                timeline: timeline,
                                size: timelineSize,
                                isSelected: index == selectedRangeIndex,
                                frameDuration: frameDuration,
                                thumbnails: thumbnails,
                                onSelectRange: onSelectRange,
                                onUpdateRange: onUpdateRange
                            )
                        }

                        scrubIndicator(timeline: timeline, height: stripHeight)
                    }
                }
                .frame(width: contentWidth, height: stripHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                .simultaneousGesture(tapGesture(contentWidth: contentWidth))
                .simultaneousGesture(longPressGesture(contentWidth: contentWidth))
            }
            .frame(height: stripHeight)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }
        }
        .frame(height: stripHeight)
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
                    .scaledToFill()
                    .frame(width: width + 0.5, height: stripHeight)
                    .clipShape(Rectangle())
                    .offset(x: leftX, y: 0)
            }
        }
        .frame(width: timeline.width, height: stripHeight)
    }

    private func scrubIndicator(timeline: TimelineGeometry, height: CGFloat) -> some View {
        let x = timeline.xPosition(for: scrubPosition)
        return Rectangle()
            .fill(AppPalette.accent)
            .frame(width: 2, height: height)
            .offset(x: x - 1, y: 0)
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
