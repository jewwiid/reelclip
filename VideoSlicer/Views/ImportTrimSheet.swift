import AVKit
import SwiftUI

struct ImportTrimRequest: Identifiable {
    let id = UUID()
    let url: URL
    let photoLibraryIdentifier: String?
    let sourceName: String
    let canDiscardSourceOnCancel: Bool
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
    @State private var isLoading = true
    @State private var errorMessage: String?

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
                        } else if isLoading {
                            ProgressView("Preparing clip…")
                                .tint(AppPalette.accent)
                                .frame(maxWidth: .infinity, minHeight: 180)
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
                step: sliderStep
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
        VStack(spacing: 10) {
            Button {
                onImport(nil)
            } label: {
                Label("Use full clip", systemImage: "rectangle.badge.play")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.primaryText)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                onImport(ClipRange(startSeconds: startSeconds, endSeconds: endSeconds))
            } label: {
                Label("Import selected section", systemImage: "scissors")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.background)
            .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
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
        isLoading = true
        errorMessage = nil
        do {
            let asset = AVURLAsset(url: request.url)
            let loadedDuration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(loadedDuration)
            guard seconds.isFinite, seconds > 0 else {
                throw NSError(domain: "ImportTrimSheet", code: 1, userInfo: [NSLocalizedDescriptionKey: "The video duration could not be read."])
            }
            duration = seconds
            startSeconds = 0
            endSeconds = seconds
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
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
    private enum Handle {
        case start
        case end
    }

    @Binding var start: Double
    @Binding var end: Double

    let duration: Double
    let minimumSelection: Double
    let step: Double

    @State private var activeHandle: Handle?
    @State private var dragStartValue: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 22
            let trackWidth = max(proxy.size.width - inset * 2, 1)
            let startX = inset + CGFloat(clamped(start / duration)) * trackWidth
            let endX = inset + CGFloat(clamped(end / duration)) * trackWidth

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppPalette.controlSurface)
                    .frame(height: 7)
                    .padding(.horizontal, inset)

                Capsule()
                    .fill(AppPalette.accent)
                    .frame(width: max(7, endX - startX), height: 7)
                    .offset(x: startX)

                handle(at: startX, isActive: activeHandle == .start)
                handle(at: endX, isActive: activeHandle == .end)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(trackWidth: trackWidth, startX: startX, endX: endX))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clip section")
        .accessibilityValue("From \(ImportTrimSheet.timeLabel(start)) to \(ImportTrimSheet.timeLabel(end))")
    }

    private func handle(at position: CGFloat, isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(AppPalette.primaryText)
            .frame(width: 5, height: isActive ? 34 : 28)
            .shadow(color: AppPalette.background.opacity(0.45), radius: 2, y: 1)
            .offset(x: position - 2.5)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private func dragGesture(trackWidth: CGFloat, startX: CGFloat, endX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard abs(value.translation.width) >= abs(value.translation.height) else { return }

                if activeHandle == nil {
                    activeHandle = nearestHandle(to: value.startLocation.x, startX: startX, endX: endX)
                    dragStartValue = activeHandle == .start ? start : end
                }

                let delta = Double(value.translation.width / trackWidth) * duration
                switch activeHandle {
                case .start:
                    let maximum = max(0, end - minimumSelection)
                    start = min(max(snapped(dragStartValue + delta), 0), maximum)
                case .end:
                    let minimum = min(duration, start + minimumSelection)
                    end = max(min(snapped(dragStartValue + delta), duration), minimum)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                activeHandle = nil
            }
    }

    private func nearestHandle(to position: CGFloat, startX: CGFloat, endX: CGFloat) -> Handle {
        // When the points are close, this still gives each half of the touch
        // target to a different endpoint instead of leaving one grip buried.
        abs(position - startX) <= abs(position - endX) ? .start : .end
    }

    private func snapped(_ value: Double) -> Double {
        guard step > 0 else { return value }
        let rounded = (value / step).rounded() * step
        return min(max(rounded, 0), duration)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
