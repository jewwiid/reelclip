import AVKit
import SwiftUI

/// Asynchronously loads a single thumbnail for a rendered clip URL. Used by
/// the preview list to show the first frame of each cut without spinning up a
/// full AVPlayer per row.
struct ClipPreviewThumbnailView: View {
    let url: URL
    let midpointSeconds: Double
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                AppPalette.mediaWell
            }
        }
        .clipped()
        .overlay {
            Image(systemName: "play.fill")
                .font(.headline.weight(.black))
                .foregroundStyle(AppPalette.accent)
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        // Cheap reuse: if the OS has already cached an image for this URL,
        // skip generating a new one.
        if image != nil { return }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let target = max(midpointSeconds, 0.05)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            await MainActor.run {
                image = UIImage(cgImage: cgImage)
            }
        } catch {
            // Falls back to the placeholder well; the row still works.
        }
    }
}

struct ExportPreviewSheet: View {
    let clips: [SegmentOutput]
    /// Maps each clip's id → the scene name it was rendered from.
    /// Empty for single-scene exports (the active scene's name is
    /// already implicit). When non-empty, the preview shows a
    /// scene-name chip above each clip so the user can see which
    /// scene the clip came from — useful for "all scenes" exports
    /// that mix multiple sources.
    let sceneLabels: [UUID: String]
    /// Scenes that were skipped during rendering, including the reason.
    /// Shown as a muted banner at the top of the sheet so the user knows
    /// why some scenes didn't contribute clips.
    let missingScenes: [SkippedSceneExport]
    let onSave: () -> Void
    let onDelete: (SegmentOutput) -> Void
    let onCancel: () -> Void

    @State private var loopingClipID: UUID?
    @State private var loopPlayer = AVPlayer()
    @State private var loopObserver: NSObjectProtocol?
    @State private var swipedClipID: UUID?
    @State private var swipeDragClipID: UUID?
    @State private var swipeDragOffset: CGFloat = 0

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerCard
                        if !missingScenes.isEmpty {
                            missingScenesBanner
                        }
                        clipsList
                    }
                    .padding(18)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Save to Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(AppPalette.primaryText)
                }
            }
            .safeAreaInset(edge: .bottom) {
                saveBar
            }
        }
        .tint(AppPalette.accent)
        .onDisappear {
            stopInlinePreview()
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 13, weight: .bold))
                Text("Photo library")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.1)
            }
            .foregroundStyle(AppPalette.accent)

            Text("\(clips.count) clip\(clips.count == 1 ? "" : "s") ready")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(AppPalette.primaryText)

            Text("Tap play to preview a clip here. Remove anything you do not want, then save the remaining queue to Photos.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .premiumSurface()
    }

    /// Banner shown when one or more scenes were skipped during render.
    /// Lists each scene with its reason so the user can fix the right issue
    /// and re-export. Muted styling keeps it from feeling like a total
    /// failure because the export itself succeeded for the included scenes.
    private var missingScenesBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(AppPalette.mutedText)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(missingScenes.count) scene\(missingScenes.count == 1 ? "" : "s") skipped")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                ForEach(missingScenes) { scene in
                    Text(scene.displayText)
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var clipsList: some View {
        VStack(spacing: 12) {
            if clips.isEmpty {
                emptyQueueState
            } else {
                ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                    previewRow(index: index, clip: clip)
                }
            }
        }
    }

    private func previewRow(index: Int, clip: SegmentOutput) -> some View {
        let midpoint = (clip.startSeconds + clip.endSeconds) / 2
        let isLooping = loopingClipID == clip.id
        let deleteRevealWidth: CGFloat = 92
        let baseOffset: CGFloat = swipedClipID == clip.id ? -deleteRevealWidth : 0
        let activeDragOffset: CGFloat = swipeDragClipID == clip.id ? swipeDragOffset : 0
        let rowOffset = min(0, max(-deleteRevealWidth, baseOffset + activeDragOffset))

        return ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                removeClip(clip)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                        .font(.headline.weight(.bold))
                    Text("Remove")
                        .font(.caption2.weight(.black))
                }
                .foregroundStyle(.white)
                .frame(width: deleteRevealWidth)
                .frame(maxHeight: .infinity)
                .background(AppPalette.danger, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 14) {
                Button {
                    if swipedClipID == clip.id {
                        closeDeleteSwipe()
                    } else {
                        toggleInlinePreview(for: clip)
                    }
                } label: {
                    ZStack {
                        if isLooping {
                            PreviewVideoView(player: loopPlayer)
                                .frame(width: 78, height: 78)
                        } else {
                            ClipPreviewThumbnailView(url: clip.url, midpointSeconds: midpoint)
                                .frame(width: 78, height: 78)
                        }
                    }
                    .background(AppPalette.mediaWell)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppPalette.hairline, lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: isLooping ? "pause.fill" : "play.fill")
                            .font(.headline.weight(.black))
                            .foregroundStyle(AppPalette.accent)
                            .padding(9)
                            .background(Color.black.opacity(0.42), in: Circle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isLooping ? "Pause clip \(index + 1)" : "Play clip \(index + 1)")

                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                        .lineLimit(1)
                    Text("Clip \(index + 1) · \(ClipRangeFormatter.durationLabel(for: ClipRange(startSeconds: clip.startSeconds, endSeconds: clip.endSeconds)))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                    Text("\(ClipRangeFormatter.formatTime(clip.startSeconds)) → \(ClipRangeFormatter.formatTime(clip.endSeconds))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppPalette.mutedText)
                    if let sceneName = sceneLabels[clip.id] {
                        // Per-scene tag for multi-scene exports —
                        // shown only when this clip came from a
                        // scene whose name isn't implicit from the
                        // export target. (For single-scene exports
                        // the title already starts with the scene
                        // name, so the chip would be redundant.)
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.stack.fill")
                                .font(.caption2.weight(.bold))
                            Text(sceneName)
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(AppPalette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppPalette.accent.opacity(0.18), in: Capsule())
                    }
                }

                Spacer(minLength: 8)

                Button {
                    if swipedClipID == clip.id {
                        closeDeleteSwipe()
                    } else {
                        toggleInlinePreview(for: clip)
                    }
                } label: {
                    Image(systemName: isLooping ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isLooping ? "Pause clip \(index + 1)" : "Play clip \(index + 1)")
            }
            .padding(12)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }
            .offset(x: rowOffset)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .simultaneousGesture(deleteRevealGesture(for: clip, revealWidth: deleteRevealWidth))
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: rowOffset)
        .contextMenu {
            Button(role: .destructive) {
                removeClip(clip)
            } label: {
                Label("Remove from queue", systemImage: "trash")
            }
        }
        .accessibilityLabel("Preview clip \(index + 1): \(clip.title)")
    }

    private var emptyQueueState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "tray")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppPalette.mutedText)
            Text("No clips selected")
                .font(.headline.weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
            Text("Everything was removed from this save queue. Cancel and export again when you are ready.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var saveBar: some View {
        let canSave = !clips.isEmpty
        return VStack(spacing: 0) {
            Rectangle()
                .fill(AppPalette.hairline)
                .frame(height: 1)
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("Discard")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundStyle(AppPalette.primaryText)
                        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onSave) {
                    Label(
                        canSave ? "Save \(clips.count) to Photos" : "No clips selected",
                        systemImage: canSave ? "square.and.arrow.down.fill" : "tray"
                    )
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundStyle(canSave ? AppPalette.background : AppPalette.mutedText)
                        .background(
                            canSave ? AppPalette.accent : AppPalette.disabledSurface,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(AppPalette.background.opacity(0.97))
        }
    }

    private func toggleInlinePreview(for clip: SegmentOutput) {
        if loopingClipID == clip.id {
            stopInlinePreview()
        } else {
            startInlinePreview(for: clip)
        }
    }

    private func startInlinePreview(for clip: SegmentOutput) {
        stopInlinePreview()

        let item = AVPlayerItem(url: clip.url)
        PolishKit.configureVideoPlaybackAudio()
        loopPlayer.isMuted = false
        loopPlayer.replaceCurrentItem(with: item)
        loopPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            loopPlayer.play()
        }
        loopingClipID = clip.id

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            loopPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                loopPlayer.play()
            }
        }
    }

    private func stopInlinePreview() {
        loopPlayer.pause()
        loopPlayer.replaceCurrentItem(with: nil)
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        loopingClipID = nil
    }

    private func removeClip(_ clip: SegmentOutput) {
        if loopingClipID == clip.id {
            stopInlinePreview()
        }
        if swipedClipID == clip.id {
            closeDeleteSwipe()
        }
        onDelete(clip)
    }

    private func closeDeleteSwipe() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            swipedClipID = nil
            swipeDragClipID = nil
            swipeDragOffset = 0
        }
    }

    private func deleteRevealGesture(for clip: SegmentOutput, revealWidth: CGFloat) -> some Gesture {
        // Stricter activation than the previous version: 22pt minimum
        // (so scroll inertia isn't disturbed on iOS 26.5), and a
        // 1.5x horizontal-vs-vertical ratio (so a diagonal scroll
        // with even slight horizontal jitter doesn't slip through
        // and start mutating swipeDragOffset mid-scroll).
        DragGesture(minimumDistance: 22)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                swipeDragClipID = clip.id
                swipeDragOffset = value.translation.width
            }
            .onEnded { value in
                defer {
                    swipeDragClipID = nil
                    swipeDragOffset = 0
                }
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                let baseOffset: CGFloat = swipedClipID == clip.id ? -revealWidth : 0
                let resolvedOffset = baseOffset + value.translation.width
                withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                    swipedClipID = resolvedOffset < -(revealWidth * 0.45) ? clip.id : nil
                }
            }
    }
}
