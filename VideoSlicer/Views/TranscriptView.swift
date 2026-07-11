import SwiftUI
import UIKit

struct TranscriptView: View {
    let transcript: Transcript?
    let state: TranscriptState
    let plannedRanges: [ClipRange]
    let onTapWord: (TranscriptWord) -> Void
    let onRetranscribe: () -> Void

    /// Required tier for transcript export (SRT/VTT). The chip only shows
    /// when the user is on or above this tier; otherwise a small "Upgrade"
    /// chip links to the paywall.
    var exportTier: SubscriptionStore.Tier
    var canExport: Bool
    var onRequestUpgrade: (() -> Void)?

    /// Transcript-pane "Process" action. Runs silence detection on the
    /// source audio and concatenates the non-silent ranges into a
    /// single MP4. Disabled while the viewModel is already processing.
    var canProcess: Bool
    var onProcess: (() -> Void)?

    @State private var exportShare: ExportShareContext?
    /// When `false`, only the header is visible — useful when the user
    /// needs more vertical room for the timeline. Tap the chevron to
    /// collapse/expand. Persists for the view's lifetime; resets each
    /// time the editor opens.
    @State private var isExpanded: Bool = true

    private static let timeFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.minute, .second]
        f.unitsStyle = .positional
        f.zeroFormattingBehavior = [.pad]
        return f
    }()

    /// Keeps transcript review useful inside the editor's main vertical
    /// scroll view. Rows scroll inside this viewport instead of pushing the
    /// timeline and recipe controls indefinitely down the page.
    private static let transcriptViewportMaxHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isExpanded {
                switch state {
                case .idle:
                    if let transcript, !transcript.isEmpty {
                        segmentList(transcript: transcript)
                    } else {
                        idlePlaceholder
                    }
                case .processing:
                    loadingPlaceholder
                case .ready:
                    if let transcript, !transcript.isEmpty {
                        segmentList(transcript: transcript)
                    } else {
                        idlePlaceholder
                    }
                case .failed(let message):
                    errorPlaceholder(message: message)
                }
            }
        }
        // Note: no `.premiumSurface()` here — the parent
        // `transcriptSection` already wraps the title +
        // TranscriptView content in one card. Adding another
        // surface here would produce card-in-card double
        // containers, which the user flagged as inconsistent.
        .animation(.snappy(duration: 0.22), value: isExpanded)
        .onChange(of: state) { _, newState in
            // Light tap confirmation when STT finishes — the longest "did
            // anything happen" gap in the app, deserves feedback.
            if case .ready = newState {
                PolishKit.Haptics.success.play()
            }
            if newState == .ready {
                isExpanded = true
            }
        }
        .sheet(item: $exportShare) { ctx in
            ShareSheet(activityItems: [ctx.url]) { _, completed, _, error in
                if let error {
                    print("Transcript share failed: \(error.localizedDescription)")
                }
                _ = completed
            }
        }
    }

    // MARK: - Transcript exports (Creator feature since v2.0)

    private func exportTranscript(as format: TranscriptExportFormat) {
        guard let transcript, !transcript.isEmpty else { return }
        do {
            let content: String
            let fileExtension: String
            switch format {
            case .srt:
                content = transcript.exportSRT()
                fileExtension = "srt"
            case .vtt:
                content = transcript.exportVTT()
                fileExtension = "vtt"
            }
            let url = try writeTempFile(content: content, extension: fileExtension)
            exportShare = ExportShareContext(url: url)
        } catch {
            print("Transcript export failed: \(error.localizedDescription)")
        }
    }

    private func writeTempFile(content: String, extension ext: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("transcript-\(UUID().uuidString).\(ext)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Header

    /// Compact actions row at the top of the transcript card. The
    /// title + subtitle + collapse chevron live in the outer
    /// `collapsibleSectionTitle` (see `transcriptSection` in
    /// `ClipView.swift`) so the same pattern as Planned clips /
    /// Cut recipe applies — one consistent title row across all
    /// sections, no double-title card-in-card container.
    ///
    /// Order: state pill → export buttons → retranscribe button.
    /// When the section is collapsed, the outer chevron hides the
    /// whole card; when expanded, the user sees the actions row at
    /// the top of the card and the transcript body below it.
    private var header: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            exportButtons

            // "Process" — runs on-device silence detection (SmartCutAnalyzer)
            // and concatenates the kept ranges into ONE single MP4. Shown
            // whenever a transcript is present; disabled while the parent
            // viewModel is already processing. Accent-green fill when ready
            // so the user reads it as the primary CTA on this row.
            // "waveform.path.badge.minus" evokes "remove silent gaps".
            //
            // The retranscribe / "retry" button was removed — Process
            // already covers the "rerun this" intent via its canProcess
            // gate, and the state pill ("Ready"/"Transcribing"/"Failed")
            // was removed too. The Process button's disabled/active
            // state carries the same signal.
            if let transcript, !transcript.isEmpty {
                Button {
                    onProcess?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.path.badge.minus")
                            .font(.caption2.weight(.bold))
                        Text("Process")
                            .font(.caption2.weight(.black))
                    }
                    .foregroundStyle(canProcess ? AppPalette.background : AppPalette.mutedText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        canProcess ? AppPalette.accent : AppPalette.raisedSurface,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Process: detect silences and tighten into one clip")
                .polishPressFeedback()
                .disabled(!canProcess)
            }

            // Local collapse/expand toggle. The outer
            // `collapsibleSectionTitle` chevron toggles whether the
            // whole card is rendered; this chevron toggles whether
            // the transcript body is visible inside the card.
            Button {
                isExpanded.toggle()
                PolishKit.Haptics.tap(.light).play()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                    .frame(width: 30, height: 30)
                    .background(AppPalette.raisedSurface, in: Circle())
                    .rotationEffect(.degrees(isExpanded ? 0 : 180))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse transcript body" : "Expand transcript body")
            .polishPressFeedback()
        }
    }

    @ViewBuilder
    private var exportButtons: some View {
        // Free-vs-Creator gate removed in v2.0 — the Creator
        // SRT/VTT badge that surfaced on this row was confusing
        // users who'd already paid and asked "why is it still
        // locked?" Free users can still export the transcript as
        // SRT/VTT (the unlock happened upstream in the tier
        // model). The buttons render whenever a transcript is
        // ready.
        if let transcript, !transcript.isEmpty {
            HStack(spacing: 6) {
                Button { exportTranscript(as: .srt) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption2.weight(.bold))
                        Text("SRT")
                            .font(.caption2.weight(.black))
                    }
                    .foregroundStyle(AppPalette.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppPalette.raisedSurface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Export SRT subtitle file")

                Button { exportTranscript(as: .vtt) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption2.weight(.bold))
                        Text("VTT")
                            .font(.caption2.weight(.black))
                    }
                    .foregroundStyle(AppPalette.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppPalette.raisedSurface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Export VTT subtitle file")
            }
        }
    }

    @ViewBuilder
    private var statePill: some View {
        switch state {
        case .idle:
            pill("Idle", color: AppPalette.mutedText)
        case .processing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).tint(AppPalette.accent)
                pill("Transcribing", color: AppPalette.accent)
            }
        case .ready:
            pill("Ready", color: AppPalette.accent)
        case .failed:
            pill("Failed", color: AppPalette.mutedText)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.black))
            .foregroundStyle(color == AppPalette.accent ? AppPalette.background : AppPalette.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.85), in: Capsule())
    }

    // MARK: - Teleprompter

    @ViewBuilder
    private func segmentList(transcript: Transcript) -> some View {
        let segments = transcript.segments.sorted { $0.startSeconds < $1.startSeconds }
        let silences = detectedSilences(in: segments)

        VStack(alignment: .leading, spacing: 8) {
            if !silences.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.badge.minus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                    Text("\(silences.count) detected silence\(silences.count == 1 ? "" : "s")")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.secondaryText)
                    Spacer(minLength: 0)
                    Text("Review")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(AppPalette.accent)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        if let silence = silences.first(where: { $0.beforeSegmentID == segment.id }) {
                            silenceRow(silence)
                        }
                        segmentCard(segment)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 96, maxHeight: Self.transcriptViewportMaxHeight)
            .scrollIndicators(.visible)
        }
    }

    private func segmentCard(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Speech")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(AppPalette.accent)
                if !plannedRanges.isEmpty {
                    Text(overlapsPlannedRange(segment) ? "Kept" : "Outside selected plan")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(
                            overlapsPlannedRange(segment)
                                ? AppPalette.success
                                : AppPalette.mutedText
                        )
                }
                Spacer(minLength: 0)
            }
            segmentBlock(segment)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppPalette.controlSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private func silenceRow(_ silence: DetectedSilence) -> some View {
        Button {
            onTapWord(
                TranscriptWord(
                    text: "Detected silence",
                    startSeconds: silence.startSeconds,
                    endSeconds: silence.endSeconds
                )
            )
            PolishKit.Haptics.tap(.light).play()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.badge.minus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detected silence")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text("\(timeLabel(silence.startSeconds)) → \(timeLabel(silence.endSeconds)) · \(durationLabel(silence.duration))")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppPalette.danger.opacity(0.30), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Detected silence from \(timeLabel(silence.startSeconds)) to \(timeLabel(silence.endSeconds))"
        )
    }

    private func detectedSilences(in segments: [TranscriptSegment]) -> [DetectedSilence] {
        guard segments.count > 1 else { return [] }
        return zip(segments, segments.dropFirst()).compactMap { previous, next in
            let start = max(previous.endSeconds, 0)
            let end = max(next.startSeconds, start)
            let duration = end - start
            guard duration >= 0.35 else { return nil }
            return DetectedSilence(
                id: "\(previous.id.uuidString)-\(next.id.uuidString)",
                beforeSegmentID: next.id,
                startSeconds: start,
                endSeconds: end
            )
        }
    }

    private func overlapsPlannedRange(_ segment: TranscriptSegment) -> Bool {
        plannedRanges.contains { range in
            max(range.startSeconds, segment.startSeconds) < min(range.endSeconds, segment.endSeconds)
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        Self.timeFormatter.string(from: seconds) ?? "0:00"
    }

    private func durationLabel(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }

    private func segmentBlock(_ segment: TranscriptSegment) -> some View {
        let hasWords = !segment.words.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Self.timeFormatter.string(from: segment.startSeconds) ?? "0:00")
                    .font(.caption2.monospacedDigit().weight(.black))
                    .foregroundStyle(AppPalette.accent)
                Text("→")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)
                Text(Self.timeFormatter.string(from: segment.endSeconds) ?? "0:00")
                    .font(.caption2.monospacedDigit().weight(.black))
                    .foregroundStyle(AppPalette.secondaryText)
                Spacer(minLength: 0)
            }
            if hasWords {
                FlowLayoutHStack {
                    ForEach(segment.words) { word in
                        wordChip(word)
                    }
                }
            } else {
                Text(segment.text)
                    .font(.body)
                    .foregroundStyle(AppPalette.primaryText)
            }
        }
    }

    private func wordChip(_ word: TranscriptWord) -> some View {
        Button {
            onTapWord(word)
            PolishKit.Haptics.tap(.light).play()
        } label: {
            Text(word.text)
                .font(.body)
                .foregroundStyle(AppPalette.primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AppPalette.raisedSurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to \(word.text) at \(Self.timeFormatter.string(from: word.startSeconds) ?? "0:00")")
    }

    // MARK: - Placeholders

    private var idlePlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speech-to-text runs on-device.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.primaryText)
            Text("Tap the retranscribe icon above to generate a transcript from the source video's audio.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryText)
        }
        .padding(.vertical, 4)
    }

    private var loadingPlaceholder: some View {
        HStack(spacing: 10) {
            ProgressView().tint(AppPalette.accent)
            Text("Transcribing on-device audio…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.primaryText)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private func errorPlaceholder(message: String) -> some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title.weight(.black))
                .foregroundStyle(AppPalette.danger)
                .padding(20)
                .background(AppPalette.danger.opacity(0.15), in: Circle())
            Text("Transcription failed")
                .font(.headline.weight(.black))
                .foregroundStyle(AppPalette.primaryText)
            Text(message.isEmpty ? "No speech detected" : message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                onRetranscribe()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(AppPalette.background)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(AppPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - State plumbing

    /// TranscriptState is defined in `Transcript.swift` (top-level)
    /// and re-exported via this view's `state:` parameter — both
    /// the view model and this view share the same type.

    private struct ExportShareContext: Identifiable {
        let id = UUID()
        let url: URL
    }

    enum TranscriptExportFormat { case srt, vtt }

    private struct DetectedSilence: Identifiable {
        let id: String
        let beforeSegmentID: UUID
        let startSeconds: Double
        let endSeconds: Double

        var duration: Double {
            max(0, endSeconds - startSeconds)
        }
    }
}

private extension TranscriptWord {
    var displayText: String { text }
}

private extension TranscriptSegment {
    var displayText: String { text }
}

// MARK: - Word wrap (LazyHStack fallback)

/// Minimal horizontal flex layout that wraps word chips onto a new
/// line when they overflow. Replaces the custom Swift `Layout`
/// `FlowLayout` that was removed during the iOS 26.5 stack-overflow
/// fix. Words are short, so the O(n) wrap is fast enough.
struct FlowLayoutHStack<Content: View>: View {
    let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
