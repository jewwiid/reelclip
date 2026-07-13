import AVKit
import PhotosUI
import SwiftUI

struct ImportTrimRequest: Identifiable {
    let id = UUID()
    let url: URL
    let photoLibraryIdentifier: String?
    let sourceName: String
    let canDiscardSourceOnCancel: Bool
    let durationSeconds: Double
}

/// Stages shared by every video source import. A scene source follows the
/// same materialise -> copy -> inspect -> trim flow as a new project, so
/// users never have to guess whether a second scene is ready to edit.
enum ImportPreparationStage: Int {
    case loadingFromPhotos
    case copyingToWorkspace
    case checkingVideo
    case ready

    var title: String {
        switch self {
        case .loadingFromPhotos:
            return "Loading from Photos"
        case .copyingToWorkspace:
            return "Copying into ReelClips"
        case .checkingVideo:
            return "Checking video"
        case .ready:
            return "Ready to trim"
        }
    }

    var detail: String {
        switch self {
        case .loadingFromPhotos:
            return "Downloading the selected video to this device."
        case .copyingToWorkspace:
            return "Saving a private working copy. Your original stays unchanged."
        case .checkingVideo:
            return "Reading the clip duration and preparing playback."
        case .ready:
            return "Opening the trim controls."
        }
    }
}

/// Full-screen progress state for the source materialisation step. This is
/// intentionally independent of recipe processing progress: it reflects the
/// actual Photos transfer, iCloud download, workspace copy, and AVAsset read.
struct ImportPreparationOverlay: View {
    let progress: Double
    let stage: ImportPreparationStage

    private var percentage: Int {
        Int((min(max(progress, 0), 1) * 100).rounded(.down))
    }

    var body: some View {
        ZStack {
            AppPalette.background.opacity(0.98)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: stage == .ready ? "checkmark" : "film.stack")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(AppPalette.background)
                    .frame(width: 64, height: 64)
                    .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text("Preparing clip")
                    .font(.title2.weight(.black))
                    .foregroundStyle(AppPalette.primaryText)

                VStack(spacing: 8) {
                    Text("\(percentage)%")
                        .font(.system(size: 52, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(AppPalette.primaryText)
                        .contentTransition(.numericText(value: Double(percentage)))

                    Text(stage.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                }

                ProgressView(value: progress, total: 1)
                    .tint(AppPalette.accent)
                    .frame(maxWidth: 360)
                    .scaleEffect(x: 1, y: 2, anchor: .center)
                    .animation(.easeOut(duration: 0.16), value: progress)

                Text(stage.detail)
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            .padding(.horizontal, 28)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing clip. \(percentage) percent. \(stage.title)")
        .transition(.opacity)
    }
}

private enum SourceImportPreparationError: LocalizedError {
    case alreadyPreparing

    var errorDescription: String? {
        switch self {
        case .alreadyPreparing:
            return "Finish the current import before choosing another video."
        }
    }
}

/// Owns the non-destructive first stage of every source import. It gives Home
/// and ClipView the exact same progress semantics while leaving each caller
/// responsible for where the confirmed source is installed.
@MainActor
final class SourceImportPreparation: ObservableObject {
    typealias WorkspaceCopy = (URL, @escaping MediaImportProgressHandler) async throws -> ImportedSourceCopy

    @Published private(set) var isPreparing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var stage: ImportPreparationStage = .loadingFromPhotos

    func preparePhoto(
        from item: PhotosPickerItem,
        workspaceRoot: URL
    ) async throws -> ImportTrimRequest {
        try begin(at: .loadingFromPhotos)
        var preparedCopy: ImportedSourceCopy?

        do {
            let prepared = try await preparePhotoCopy(from: item, workspaceRoot: workspaceRoot)
            preparedCopy = prepared.copy
            updateProgress(0.96, stage: .checkingVideo)
            let duration = try await preparedVideoDuration(for: prepared.copy.url)
            let request = ImportTrimRequest(
                url: prepared.copy.url,
                photoLibraryIdentifier: item.photoLibraryLocalIdentifier,
                sourceName: prepared.sourceName,
                canDiscardSourceOnCancel: prepared.copy.wasCreated,
                durationSeconds: duration
            )
            await finishSuccessfully()
            return request
        } catch {
            if let preparedCopy, preparedCopy.wasCreated {
                MediaWorkspace(rootDirectory: workspaceRoot).removeImportedSource(at: preparedCopy.url)
            }
            finish()
            throw error
        }
    }

    func prepareFile(
        from url: URL,
        workspaceRoot: URL,
        copyToWorkspace: @escaping WorkspaceCopy
    ) async throws -> ImportTrimRequest {
        try begin(at: .copyingToWorkspace)
        var preparedCopy: ImportedSourceCopy?
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try await MediaImportPreparation.ensureFileIsLocal(url) { [weak self] fraction in
                Task { @MainActor in
                    self?.updateProgress(fraction * 0.5, stage: .copyingToWorkspace)
                }
            }

            let copied = try await copyToWorkspace(url) { [weak self] fraction in
                Task { @MainActor in
                    self?.updateProgress(0.5 + fraction * 0.45, stage: .copyingToWorkspace)
                }
            }
            preparedCopy = copied
            updateProgress(0.96, stage: .checkingVideo)
            let duration = try await preparedVideoDuration(for: copied.url)
            let request = ImportTrimRequest(
                url: copied.url,
                photoLibraryIdentifier: nil,
                sourceName: url.lastPathComponent,
                canDiscardSourceOnCancel: copied.wasCreated,
                durationSeconds: duration
            )
            await finishSuccessfully()
            return request
        } catch {
            if let preparedCopy, preparedCopy.wasCreated {
                MediaWorkspace(rootDirectory: workspaceRoot).removeImportedSource(at: preparedCopy.url)
            }
            finish()
            throw error
        }
    }

    private func begin(at initialStage: ImportPreparationStage) throws {
        guard !isPreparing else {
            throw SourceImportPreparationError.alreadyPreparing
        }
        progress = 0
        stage = initialStage
        withAnimation(.easeOut(duration: 0.18)) {
            isPreparing = true
        }
    }

    private func finishSuccessfully() async {
        updateProgress(1, stage: .ready)
        try? await Task.sleep(nanoseconds: 180_000_000)
        finish()
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.18)) {
            isPreparing = false
        }
    }

    private func updateProgress(_ value: Double, stage nextStage: ImportPreparationStage) {
        guard nextStage.rawValue >= stage.rawValue else { return }
        stage = nextStage
        progress = max(progress, min(max(value, 0), 1))
    }

    private func preparePhotoCopy(
        from item: PhotosPickerItem,
        workspaceRoot: URL
    ) async throws -> (copy: ImportedSourceCopy, sourceName: String) {
        try await withCheckedThrowingContinuation { continuation in
            let transferProgress = item.loadTransferable(type: PickedVideo.self) { [weak self] result in
                switch result {
                case .success(.some(let video)):
                    do {
                        Task { @MainActor in
                            self?.updateProgress(0.92, stage: .copyingToWorkspace)
                        }

                        let workspace = MediaWorkspace(rootDirectory: workspaceRoot)
                        let copy: ImportedSourceCopy
                        if video.url.deletingLastPathComponent().standardizedFileURL
                            == workspace.importsDirectory.standardizedFileURL {
                            copy = ImportedSourceCopy(
                                url: video.url,
                                wasCreated: video.isWorkspaceCopyNew
                            )
                        } else {
                            copy = try workspace.importSourceCopyResult(from: video.url)
                        }
                        continuation.resume(returning: (copy, video.sourceName))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .success(.none):
                    continuation.resume(throwing: NSError(
                        domain: "SourceImportPreparation",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Choose a valid video file."]
                    ))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            Task { @MainActor [weak self] in
                await self?.observePhotoTransferProgress(transferProgress)
            }
        }
    }

    private func observePhotoTransferProgress(_ transferProgress: Progress) async {
        while isPreparing, stage == .loadingFromPhotos {
            let fraction = transferProgress.fractionCompleted
            if fraction.isFinite {
                updateProgress(min(max(fraction, 0), 1) * 0.90, stage: .loadingFromPhotos)
            }
            if transferProgress.isFinished || transferProgress.isCancelled {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func preparedVideoDuration(for url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        async let loadedDuration = asset.load(.duration)
        async let videoTracks = asset.loadTracks(withMediaType: .video)
        let (duration, tracks) = try await (loadedDuration, videoTracks)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0, !tracks.isEmpty else {
            throw NSError(
                domain: "SourceImportPreparation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The selected video could not be read."]
            )
        }
        return seconds
    }
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
        VStack(spacing: 10) {
            nativeSliderRow(label: "In", value: startBinding)
            nativeSliderRow(label: "Out", value: endBinding)
        }
        .accessibilityElement(children: .contain)
    }

    private var maximumDuration: Double {
        max(duration, minimumSelection, 0.001)
    }

    private var effectiveMinimumSelection: Double {
        min(max(minimumSelection, 0), maximumDuration)
    }

    private var startBinding: Binding<Double> {
        Binding(
            get: { min(max(start, 0), maximumDuration) },
            set: { newValue in
                let upperLimit = max(0, min(end, maximumDuration) - effectiveMinimumSelection)
                start = min(max(newValue, 0), upperLimit)
                onPreviewFrame(start)
            }
        )
    }

    private var endBinding: Binding<Double> {
        Binding(
            get: { min(max(end, 0), maximumDuration) },
            set: { newValue in
                let lowerLimit = min(maximumDuration, max(start, 0) + effectiveMinimumSelection)
                end = max(min(newValue, maximumDuration), lowerLimit)
                onPreviewFrame(end)
            }
        )
    }

    private func nativeSliderRow(label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.secondaryText)
                .frame(width: 30, alignment: .leading)

            Slider(
                value: value,
                in: 0...maximumDuration,
                step: max(step, 0.001)
            )
            .tint(AppPalette.accent)
            .controlSize(.regular)
            .accessibilityLabel("\(label) point")
            .accessibilityValue(ImportTrimSheet.timeLabel(value.wrappedValue))

            Text(ImportTrimSheet.timeLabel(value.wrappedValue))
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
                .frame(width: 48, alignment: .trailing)
        }
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
