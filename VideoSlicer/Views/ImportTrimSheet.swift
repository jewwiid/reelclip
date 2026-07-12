import AVKit
import SwiftUI

struct ImportTrimRequest: Identifiable {
    let id = UUID()
    let url: URL
    let photoLibraryIdentifier: String?
    let sourceName: String
    let canDiscardSourceOnCancel: Bool
    let durationSeconds: Double
}

/// First-step source preparation for a new project. The full source is never
/// modified; a selected range is rendered into ReelClip's private workspace
/// only after the user confirms the import.
struct ImportTrimSheet: View {
    let request: ImportTrimRequest
    let onImport: (ClipRange?) -> Void
    let onCancel: () -> Void

    @State private var player = AVPlayer()
    @State private var duration: Double = 0
    @State private var startSeconds: Double = 0
    @State private var endSeconds: Double = 0
    @State private var errorMessage: String?

    init(
        request: ImportTrimRequest,
        onImport: @escaping (ClipRange?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onImport = onImport
        self.onCancel = onCancel
        _duration = State(initialValue: request.durationSeconds)
        _endSeconds = State(initialValue: request.durationSeconds)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header

                        if duration > 0 {
                            preview
                            rangeSummary
                            rangeControls
                            actionButtons
                        } else {
                            errorState
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Prepare clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(AppPalette.primaryText)
                }
            }
        }
        .tint(AppPalette.accent)
        .task(id: request.url) {
            await loadSource()
        }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "scissors")
                    .font(.subheadline.weight(.bold))
                Text("Optional first step")
                    .font(.caption.weight(.black))
                    .textCase(.uppercase)
                    .tracking(0.8)
            }
            .foregroundStyle(AppPalette.accent)

            Text("Choose the section to work with")
                .font(.title3.weight(.black))
                .foregroundStyle(AppPalette.primaryText)

            Text("Trim the source before creating the project, or use the full clip. Your original video in Photos or Files is never changed.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .premiumSurface()
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.sourceName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
                .lineLimit(1)

            VideoPlayer(player: player)
                .frame(height: 214)
                .background(AppPalette.mediaWell)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }
        }
        .premiumSurface()
    }

    private var rangeSummary: some View {
        HStack(spacing: 10) {
            timeCard(title: "In", value: startSeconds)
            Image(systemName: "arrow.right")
                .font(.caption.weight(.black))
                .foregroundStyle(AppPalette.mutedText)
            timeCard(title: "Out", value: endSeconds)
            Spacer(minLength: 0)
            timeCard(title: "Selected", value: endSeconds - startSeconds)
        }
    }

    private func timeCard(title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.black))
                .foregroundStyle(AppPalette.mutedText)
                .textCase(.uppercase)
            Text(Self.timeLabel(value))
                .font(.subheadline.monospacedDigit().weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clip section")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.secondaryText)

            ImportRangeSelector(
                start: $startSeconds,
                end: $endSeconds,
                duration: duration,
                minimumSelection: minimumSelection,
                step: sliderStep,
                onPreviewFrame: showPreviewFrame
            )
            .frame(height: 48)
        }
        .padding(16)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var actionButtons: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    importActionButtonRow
                }
            } else {
                importActionButtonRow
            }
        }
    }

    private var importActionButtonRow: some View {
        HStack(spacing: 10) {
            Button {
                onImport(nil)
            } label: {
                importActionLabel("Use full clip", systemImage: "play.rectangle.fill")
            }
            .modifier(ImportActionButtonStyle(prominent: false))
            .accessibilityHint("Creates the project using the entire source video.")

            Button {
                onImport(ClipRange(startSeconds: startSeconds, endSeconds: endSeconds))
            } label: {
                importActionLabel("Import selection", systemImage: "scissors")
            }
            .modifier(ImportActionButtonStyle(prominent: true))
            .accessibilityLabel("Import selected section")
            .accessibilityHint("Creates the project using only the selected in and out points.")
        }
        .frame(maxWidth: .infinity)
    }

    private func importActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.76)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(Rectangle())
    }

    private var errorState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppPalette.danger)
            Text("This clip could not be prepared")
                .font(.headline.weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
            Text(errorMessage ?? "Try choosing the video again.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var minimumSelection: Double { min(0.1, max(duration / 100, 0.01)) }
    private var sliderStep: Double { duration > 120 ? 0.1 : 0.01 }

    private func loadSource() async {
        errorMessage = nil
        let asset = AVURLAsset(url: request.url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
    }

    private func showPreviewFrame(at seconds: Double) {
        guard seconds.isFinite, seconds >= 0, player.currentItem != nil else { return }
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.seek(
            to: CMTime(seconds: min(seconds, duration), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    fileprivate static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.0" }
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let remainder = clamped - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, remainder)
    }
}

private struct ImportRangeSelector: View {
    @Binding var start: Double
    @Binding var end: Double

    let duration: Double
    let minimumSelection: Double
    let step: Double
    let onPreviewFrame: (Double) -> Void

    var body: some View {
        ReelClipRangeSlider(
            lowerValue: $start,
            upperValue: $end,
            bounds: 0...max(duration, minimumSelection),
            minimumGap: minimumSelection,
            step: step,
            onValueChanged: { _, value in
                onPreviewFrame(value)
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clip section")
        .accessibilityValue("From \(ImportTrimSheet.timeLabel(start)) to \(ImportTrimSheet.timeLabel(end))")
    }
}

private struct ImportActionButtonStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                content
                    .buttonStyle(.glassProminent)
                    .tint(AppPalette.accent)
                    .foregroundStyle(AppPalette.background)
            } else {
                content
                    .buttonStyle(.glass)
                    .foregroundStyle(AppPalette.background)
            }
        } else {
            content
                .buttonStyle(.plain)
                .foregroundStyle(prominent ? AppPalette.background : AppPalette.primaryText)
                .background(
                    prominent ? AppPalette.accent : AppPalette.controlSurface,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
    }
}
