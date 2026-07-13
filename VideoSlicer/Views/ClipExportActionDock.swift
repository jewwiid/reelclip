import SwiftUI

/// Project-level save/export controls for the editor.
///
/// Recipe Add/Reset controls stay with the cut recipe. This dock owns only the
/// project commit and render actions, plus the single processing state shown
/// while either operation is running.
struct ClipExportActionDock: View {
    @EnvironmentObject private var viewModel: VideoSplitterViewModel

    let dismissKeyboard: () -> Void
    let chooseExportTarget: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if viewModel.isImportingMedia {
                    importStatusBar
                    cancelProcessingButton
                } else if viewModel.isProcessing {
                    processingStatusBar
                    cancelProcessingButton
                } else {
                    saveButton
                    exportButton
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(AppPalette.background.opacity(0.97))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppPalette.hairline)
                .frame(height: 1)
        }
    }

    private var saveButton: some View {
        let visibleCount = viewModel.plannedRangesForCurrentMode.count
        let canSave = visibleCount > 0

        return Button {
            dismissKeyboard()
            PolishKit.Haptics.tap(.medium).play()
            viewModel.commitPlannedToSaved()
        } label: {
            Label("Save recipe", systemImage: "bookmark.fill")
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
        }
        .buttonStyle(.plain)
        .foregroundStyle(canSave ? AppPalette.background : AppPalette.mutedText)
        .background(
            canSave ? AppPalette.accent : AppPalette.disabledSurface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .disabled(!canSave)
        .polishPressFeedback(scale: 0.97, pressedOpacity: 0.85)
        .accessibilityLabel("Save this recipe's planned clips to the project")
        .accessibilityHint("Creates a saved plan snapshot. It does not render or save video to Photos.")
    }

    private var exportButton: some View {
        let canExport = viewModel.canExportPreparedClips
        let count = viewModel.plannedRanges.count

        return Button {
            dismissKeyboard()
            PolishKit.Haptics.tap(.medium).play()
            if viewModel.scenes.count > 1 {
                chooseExportTarget()
            } else {
                viewModel.exportPreparedClips()
            }
        } label: {
            Label(count == 1 ? "Render clip" : "Render clips", systemImage: "film.stack.fill")
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
        }
        .buttonStyle(.plain)
        .foregroundStyle(canExport ? AppPalette.primaryText : AppPalette.mutedText)
        .background(
            canExport ? AppPalette.controlSurface : AppPalette.disabledSurface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .disabled(!canExport)
        .polishPressFeedback()
        .accessibilityLabel("Render planned clips for review")
        .accessibilityHint("Rendered clips are reviewed before they are saved to Photos.")
    }

    private var importStatusBar: some View {
        let progress = clampedProgress
        let hasDeterminateProgress = progress > 0

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppPalette.controlSurface)

            if hasDeterminateProgress {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppPalette.accent.opacity(0.24))
                        .frame(width: max(8, proxy.size.width * CGFloat(progress)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            HStack(spacing: 12) {
                if hasDeterminateProgress {
                    Text("\(progressPercent)%")
                        .font(.subheadline.monospacedDigit().weight(.black))
                        .foregroundStyle(AppPalette.accent)
                } else {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(AppPalette.accent)
                }

                Text(viewModel.statusMessage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasDeterminateProgress
            ? "Importing clip, \(progressPercent)% complete"
            : "Importing clip")
    }

    private var processingStatusBar: some View {
        let progress = clampedProgress

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppPalette.controlSurface)

            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppPalette.accent.opacity(0.24))
                    .frame(width: max(8, proxy.size.width * CGFloat(progress)))
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(spacing: 10) {
                PolishKit.ShimmerText(
                    text: "\(progressPercent)% complete",
                    systemImage: "wand.and.stars",
                    tint: AppPalette.accent
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Processing \(progressPercent)% complete")
    }

    private var cancelProcessingButton: some View {
        Button {
            viewModel.cancelProcessing()
            PolishKit.Haptics.warning.play()
        } label: {
            Image(systemName: "xmark")
                .font(.headline.weight(.black))
                .frame(width: 54, height: 54)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppPalette.primaryText)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("Cancel processing")
        .polishPressFeedback()
    }

    private var progressPercent: Int {
        guard viewModel.progress.isFinite else { return 0 }
        return Int((clampedProgress * 100).rounded())
    }

    private var clampedProgress: Double {
        guard viewModel.progress.isFinite else { return 0 }
        return min(max(viewModel.progress, 0), 1)
    }
}
