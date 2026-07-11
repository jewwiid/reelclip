import AVFoundation
import SwiftUI

/// Inline sequence preview for the committed clip list.
///
/// The player advances through each saved range in display order. The slider
/// represents the combined sequence duration, while seeking still lands on
/// the correct source-video time inside the selected range.
struct SavedClipsPlaybackStrip: View {
    let ranges: [ClipRange]
    let sourceURL: URL?

    @State private var player = AVPlayer()
    @State private var currentIndex = 0
    @State private var currentClipElapsed = 0.0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    private var totalDuration: Double {
        ranges.reduce(0) { $0 + max($1.duration, 0) }
    }

    private var currentRange: ClipRange? {
        ranges.indices.contains(currentIndex) ? ranges[currentIndex] : nil
    }

    private var sequencePosition: Double {
        guard ranges.indices.contains(currentIndex) else { return 0 }
        let preceding = ranges.prefix(currentIndex).reduce(0) { $0 + max($1.duration, 0) }
        return min(totalDuration, max(0, preceding + currentClipElapsed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.caption.weight(.black))
                        .foregroundStyle(AppPalette.background)
                        .frame(width: 34, height: 34)
                        .background(AppPalette.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .opacity(canPlay ? 1 : 0.45)
                .accessibilityLabel(isPlaying ? "Pause saved clips preview" : "Play saved clips preview")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Preview saved sequence")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text(currentClipLabel)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                }

                Spacer(minLength: 8)

                Text(ClipRangeFormatter.formatTime(sequencePosition))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                Text("/")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.mutedText)
                Text(ClipRangeFormatter.formatTime(totalDuration))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)
            }

            Slider(
                value: Binding(
                    get: { sequencePosition },
                    set: { seekSequence(to: $0) }
                ),
                in: 0...max(totalDuration, 0.01),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        player.pause()
                    } else if canPlay && isPlaying {
                        player.play()
                    }
                }
            )
            .tint(AppPalette.accent)
            .disabled(!canPlay)
            .accessibilityLabel("Saved clips preview timeline")
            .accessibilityValue("Clip \(min(currentIndex + 1, max(ranges.count, 1))) of \(ranges.count)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        .onAppear(perform: resetPlayback)
        .onChange(of: ranges.map(\.savedRowID)) { _, _ in
            resetPlayback()
        }
        .onDisappear(perform: tearDown)
    }

    private var canPlay: Bool {
        sourceURL != nil && !ranges.isEmpty && totalDuration > 0
    }

    private var currentClipLabel: String {
        guard let currentRange else { return "No saved clips" }
        return "Clip \(min(currentIndex + 1, ranges.count)) · \(ClipRangeFormatter.title(for: currentRange))"
    }

    private func togglePlayback() {
        guard canPlay else { return }
        if isPlaying {
            isPlaying = false
            player.pause()
            return
        }

        PolishKit.configureVideoPlaybackAudio()
        player.isMuted = false
        isPlaying = true
        if player.currentItem == nil {
            installCurrentItem()
        } else {
            player.play()
        }
        PolishKit.Haptics.tap(.medium).play()
    }

    private func seekSequence(to position: Double) {
        guard canPlay, position.isFinite else { return }

        let clamped = min(max(position, 0), totalDuration)
        var offset = 0.0
        var targetIndex = ranges.count - 1

        for (index, range) in ranges.enumerated() {
            let duration = max(range.duration, 0)
            if clamped <= offset + duration || index == ranges.count - 1 {
                targetIndex = index
                break
            }
            offset += duration
        }

        let targetRange = ranges[targetIndex]
        let local = min(max(clamped - offset, 0), max(targetRange.duration, 0))
        let wasPlaying = isPlaying && !isScrubbing

        if targetIndex != currentIndex || player.currentItem == nil {
            currentIndex = targetIndex
            currentClipElapsed = local
            installCurrentItem(localElapsed: local, resume: wasPlaying)
        } else {
            currentClipElapsed = local
            player.seek(
                to: CMTime(seconds: targetRange.startSeconds + local, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            if wasPlaying {
                player.play()
            }
        }
    }

    private func installCurrentItem(localElapsed: Double = 0, resume: Bool? = nil) {
        guard let sourceURL, ranges.indices.contains(currentIndex) else { return }

        PolishKit.configureVideoPlaybackAudio()
        player.isMuted = false
        removeEndObserver()
        let range = ranges[currentIndex]
        let item = AVPlayerItem(url: sourceURL)
        item.forwardPlaybackEndTime = CMTime(seconds: range.endSeconds, preferredTimescale: 600)
        player.replaceCurrentItem(with: item)
        currentClipElapsed = min(max(localElapsed, 0), max(range.duration, 0))

        let start = CMTime(seconds: range.startSeconds + currentClipElapsed, preferredTimescale: 600)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            if resume ?? isPlaying {
                player.play()
            }
        }

        let itemIndex = currentIndex
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            advance(after: itemIndex)
        }

        installTimeObserver(for: itemIndex)
    }

    private func installTimeObserver(for itemIndex: Int) {
        removeTimeObserver()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard ranges.indices.contains(itemIndex) else { return }
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            currentClipElapsed = min(
                max(seconds - ranges[itemIndex].startSeconds, 0),
                max(ranges[itemIndex].duration, 0)
            )
        }
    }

    private func advance(after finishedIndex: Int) {
        guard isPlaying, finishedIndex == currentIndex else { return }

        if ranges.indices.contains(finishedIndex + 1) {
            currentIndex = finishedIndex + 1
            currentClipElapsed = 0
            installCurrentItem(resume: true)
        } else {
            isPlaying = false
            currentClipElapsed = max(ranges[finishedIndex].duration, 0)
            player.pause()
        }
    }

    private func resetPlayback() {
        isPlaying = false
        currentIndex = 0
        currentClipElapsed = 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeEndObserver()
        removeTimeObserver()
    }

    private func tearDown() {
        resetPlayback()
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }
}
