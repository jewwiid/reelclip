import AVKit
import SwiftUI

/// Preview sheet for the transcript-pane "Process" action — shows the
/// single concatenated MP4 with a summary of how much silence was
/// stripped. Save → Photos via the existing ReelClip album; Cancel →
/// delete the intermediate file and dismiss.
struct TightenedPreviewSheet: View {
    let output: SegmentOutput
    /// The non-silent ranges that were concatenated to produce the
    /// output. Used purely for the "before / after" summary — no
    /// re-editing happens here.
    let keptRanges: [ClipRange]
    /// Original source duration in seconds, for the "kept N of M"
    /// summary line.
    let sourceDuration: Double
    let tier: SubscriptionStore.Tier
    let frameDuration: Double?

    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var player = AVPlayer()
    @State private var isPlaying = false

    private var keptDuration: Double {
        output.endSeconds - output.startSeconds
    }

    private var removedDuration: Double {
        max(0, sourceDuration - keptDuration)
    }

    private var removedPercent: Int {
        guard sourceDuration > 0 else { return 0 }
        return Int((removedDuration / sourceDuration * 100).rounded())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerCard
                        previewCard
                        summaryCard
                    }
                    .padding(18)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Tightened clip")
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
        .onAppear {
            // Use seek-to-zero after replaceCurrentItem so the
            // player always starts the preview from t=0. Without
            // this the player can present the previous item's
            // position momentarily when the sheet re-opens, or
            // show a black frame until the user taps play.
            let item = AVPlayerItem(url: output.url)
            player.replaceCurrentItem(with: item)
            player.seek(to: .zero)
        }
        .onDisappear {
            player.pause()
            isPlaying = false
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.badge.minus")
                    .font(.system(size: 13, weight: .bold))
                Text("Silences removed")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.1)
            }
            .foregroundStyle(AppPalette.accent)

            Text("1 tightened clip ready")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(AppPalette.primaryText)

            Text("Preview the joined clip, then save it to Photos. The original source is unchanged.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .premiumSurface()
    }

    private var previewCard: some View {
        // No fixed aspect ratio — let the source video drive the
        // frame. Previously hardcoded to 9:16, which forced a 16:9
        // landscape source into a vertical letterbox that hid the
        // actual content. The `resizeAspect` gravity on
        // `PreviewVideoView`'s underlying AVPlayerLayer keeps the
        // video centered inside whatever frame we give it, so
        // capping height at 360pt while going full-width lets
        // every source aspect render cleanly.
        ZStack {
            PreviewVideoView(player: player)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 200, maxHeight: 360)
                .background(AppPalette.mediaWell)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if !isPlaying {
                Button {
                    PolishKit.configureVideoPlaybackAudio()
                    player.play()
                    isPlaying = true
                    PolishKit.Haptics.tap(.medium).play()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 36, weight: .black))
                        .foregroundStyle(.white)
                        .padding(22)
                        .background(Color.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play tightened clip")
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap toggles play/pause so the user can stop the preview
            // without hunting for a control.
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                PolishKit.configureVideoPlaybackAudio()
                player.play()
                isPlaying = true
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                Text("Summary")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .foregroundStyle(AppPalette.accent)
            }

            HStack(spacing: 16) {
                summaryStat(
                    label: "Kept",
                    value: ClipRangeFormatter.formatTime(keptDuration),
                    color: AppPalette.accent
                )
                summaryStat(
                    label: "Removed",
                    value: ClipRangeFormatter.formatTime(removedDuration),
                    color: AppPalette.mutedText
                )
                summaryStat(
                    label: "Ranges",
                    value: "\(keptRanges.count)",
                    color: AppPalette.primaryText
                )
            }

            if removedPercent > 0 {
                Text("Removed \(removedPercent)% of the source audio as silent gaps.")
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No measurable silence gaps — output matches source length.")
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private func summaryStat(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(AppPalette.mutedText)
            Text(value)
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(AppPalette.hairline)
            HStack(spacing: 12) {
                Button {
                    onSave()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down.fill")
                        Text("Save to Photos")
                    }
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save tightened clip to Photos")
            }
            .padding(18)
            .background(AppPalette.background.opacity(0.97))
        }
    }
}
