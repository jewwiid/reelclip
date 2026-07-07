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
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var previewingClip: SegmentOutput?

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerCard
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
        .sheet(item: $previewingClip) { clip in
            ClipQuickLookPreview(url: clip.url)
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

            Text("Tap a clip to preview. Confirm below to add them all to your photo library — nothing has been saved yet.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .premiumSurface()
    }

    private var clipsList: some View {
        VStack(spacing: 12) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                previewRow(index: index, clip: clip)
            }
        }
    }

    private func previewRow(index: Int, clip: SegmentOutput) -> some View {
        let midpoint = (clip.startSeconds + clip.endSeconds) / 2

        return Button {
            previewingClip = clip
        } label: {
            HStack(spacing: 14) {
                ClipPreviewThumbnailView(url: clip.url, midpointSeconds: midpoint)
                    .frame(width: 78, height: 78)
                    .background(AppPalette.mediaWell)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppPalette.hairline, lineWidth: 1)
                    }

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
                }

                Spacer(minLength: 8)

                Image(systemName: "play.circle.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
            }
            .padding(12)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview clip \(index + 1): \(clip.title)")
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
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
                    Label("Save \(clips.count) to Photos", systemImage: "square.and.arrow.down.fill")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundStyle(AppPalette.background)
                        .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(AppPalette.background.opacity(0.97))
        }
    }
}

struct ClipQuickLookPreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
                .navigationTitle("Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(.white)
                    }
                }
        }
        .tint(.white)
    }
}