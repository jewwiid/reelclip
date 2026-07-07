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
        .premiumSurface()
        .animation(.snappy(duration: 0.22), value: isExpanded)
        .onChange(of: state) { _, newState in
            // Light tap confirmation when STT finishes — the longest "did
            // anything happen" gap in the app, deserves feedback.
            if case .ready = newState {
                PolishKit.Haptics.success.play()
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

    // MARK: - Transcript exports (Studio feature)

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

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "text.bubble")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 32, height: 32)
                .background(AppPalette.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Transcript")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                Text(headerSubtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
            }

            Spacer(minLength: 0)

            statePill

            exportButtons

            Button {
                onRetranscribe()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                    .frame(width: 30, height: 30)
                    .background(AppPalette.raisedSurface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retranscribe")
            .polishPressFeedback()

            // Collapse/expand toggle. Chevron rotates 180° between
            // states so the affordance reads as "press to flip".
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
            .accessibilityLabel(isExpanded ? "Collapse transcript" : "Expand transcript")
            .polishPressFeedback()
        }
    }

    @ViewBuilder
    private var exportButtons: some View {
        if canExport, let transcript, !transcript.isEmpty {
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
        } else if let transcript, !transcript.isEmpty {
            Button { onRequestUpgrade?() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.bold))
                    Text("Studio · SRT/VTT")
                        .font(.caption2.weight(.black))
                }
                .foregroundStyle(AppPalette.mutedText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AppPalette.controlSurface, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unlock Studio to export SRT and VTT subtitle files")
        }
    }

    private var headerSubtitle: String {
        guard let transcript else { return "Speech-to-text runs on-device" }
        let count = transcript.wordCount
        return "\(count) word\(count == 1 ? "" : "s") · \(transcript.segments.count) segment\(transcript.segments.count == 1 ? "" : "s")"
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

    private func segmentList(transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(transcript.segments) { segment in
                segmentBlock(segment)
            }
        }
    }

    private func segmentBlock(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: segment.fullyKept(plannedRanges: plannedRanges) ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(segment.fullyKept(plannedRanges: plannedRanges) ? AppPalette.accent : AppPalette.mutedText)
                Text(Self.timeFormatter.string(from: segment.startSeconds) ?? "0:00")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)
                Spacer(minLength: 0)
                if segment.fullyCut(plannedRanges: plannedRanges) {
                    Text("Cut")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(AppPalette.mutedText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppPalette.mutedText.opacity(0.18), in: Capsule())
                } else if segment.fullyKept(plannedRanges: plannedRanges) {
                    Text("Kept")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(AppPalette.background)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppPalette.accent, in: Capsule())
                }
            }

            // Horizontal-scrollable row of word chips. Words used to wrap across
            // multiple lines via `FlowLayout`; now they sit on a single
            // line the user can scrub horizontally — closer to a real
            // teleprompter feel, and keeps every word at the same vertical
            // position so it's easy to scan "kept vs cut" at a glance.
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .center, spacing: 4) {
                    ForEach(segment.words) { word in
                        wordChip(word)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)
        }
    }

    private func wordChip(_ word: TranscriptWord) -> some View {
        let isKept = word.isKept(plannedRanges)
        let isCut = word.isCut(plannedRanges)

        return Button {
            onTapWord(word)
        } label: {
            Text(word.text)
                .font(.title3.monospacedDigit().weight(.medium))
                .foregroundStyle(
                    isCut
                        ? AppPalette.mutedText
                        : (isKept ? AppPalette.primaryText : AppPalette.secondaryText)
                )
                .strikethrough(isCut, color: AppPalette.mutedText)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    isKept ? AppPalette.accent.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(word.text) at \(Self.timeFormatter.string(from: word.startSeconds) ?? "")")
    }

    // MARK: - Empty / error states

    private var idlePlaceholder: some View {
        PolishKit.EmptyStateView(
            systemImage: "waveform.and.mic",
            title: transcript == nil ? "Transcript not generated yet" : "Transcript is empty",
            message: "Tap the refresh icon to transcribe this source on-device. The transcript helps the teleprompter show what to keep and what to cut.",
            accent: AppPalette.accent,
            actionTitle: nil,
            action: nil
        )
    }

    @ViewBuilder
    private var loadingPlaceholder: some View {
        PolishKit.ShimmerText(
            text: "Reading the audio on-device…",
            systemImage: "waveform",
            tint: AppPalette.accent
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private func errorPlaceholder(message: String) -> some View {
        PolishKit.EmptyStateView(
            systemImage: "exclamationmark.triangle.fill",
            title: "Transcription failed",
            message: message,
            accent: AppPalette.danger
        )
    }

// MARK: - Word classification helpers

    enum TranscriptExportFormat { case srt, vtt }
}

private struct ExportShareContext: Identifiable {
    let id = UUID()
    let url: URL
}


// MARK: - Word classification helpers

private extension TranscriptWord {
    func isKept(_ ranges: [ClipRange]) -> Bool {
        ranges.contains { range in
            let mid = (startSeconds + endSeconds) / 2
            return mid >= range.startSeconds && mid <= range.endSeconds
        }
    }

    func isCut(_ ranges: [ClipRange]) -> Bool {
        !isKept(ranges)
    }
}

private extension TranscriptSegment {
    func fullyKept(plannedRanges: [ClipRange]) -> Bool {
        plannedRanges.contains { range in
            range.startSeconds <= startSeconds && range.endSeconds >= endSeconds
        }
    }

    func fullyCut(plannedRanges: [ClipRange]) -> Bool {
        guard !plannedRanges.isEmpty else { return false }
        let mid = (startSeconds + endSeconds) / 2
        return !plannedRanges.contains { range in
            mid >= range.startSeconds && mid <= range.endSeconds
        }
    }
}

// MARK: - Simple flow layout for words (SwiftUI Layout API)

private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = layoutLines(in: maxWidth, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.height } + CGFloat(max(0, lines.count - 1)) * lineSpacing
        let widest = lines.map(\.width).max() ?? 0
        return CGSize(width: min(widest, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = layoutLines(in: bounds.width, subviews: subviews)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for sub in line.items {
                let size = sub.sizeThatFits(.unspecified)
                sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var items: [LayoutSubview] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layoutLines(in maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = [Line()]
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            var current = lines[lines.count - 1]
            let projected = current.width + (current.items.isEmpty ? 0 : spacing) + size.width
            if projected > maxWidth, !current.items.isEmpty {
                lines.append(Line())
                current = lines[lines.count - 1]
            }
            current.items.append(sub)
            current.width += (current.items.count == 1 ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            lines[lines.count - 1] = current
        }
        return lines
    }
}