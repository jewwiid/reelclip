import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum CollapsibleSection: Hashable {
    case cutRecipe
    case plannedClips
    case savedClips
}

struct ClipView: View {
    @EnvironmentObject private var viewModel: VideoSplitterViewModel
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Binding var selectedTab: RootView.AppTab

    @State private var previewPlayer = AVPlayer()
    @State private var isPreviewPlaying = false
    @State private var isScrubbing = false
    @State private var isFileImporterPresented = false
    @State private var collapsedSections: Set<CollapsibleSection> = []
    @State private var clipToShare: SegmentOutput?
    @State private var showPaywall = false
    @State private var pendingAction: (() -> Void)?
    @State private var userSelectedRangeIndex: Int? = nil
    @State private var isProjectTitleComposing: Bool = false
    @FocusState private var isSegmentFieldFocused: Bool
    @FocusState private var isProjectTitleFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()
                editorWorkspace
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isSegmentFieldFocused = false
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if shouldShowActionDock {
                    actionDock
                }
            }
            .alert("Processing stopped", isPresented: errorBinding) {
                Button("OK") {
                    viewModel.clearError()
                }
            } message: {
                Text(viewModel.errorMessage ?? "Try another video or segment length.")
            }
        }
        .tint(AppPalette.accent)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    viewModel.importVideoFile(from: url)
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: viewModel.sourceURL) { _, newURL in
            isPreviewPlaying = false
            if let newURL {
                previewPlayer.replaceCurrentItem(with: AVPlayerItem(url: newURL))
            } else {
                previewPlayer.replaceCurrentItem(with: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            isPreviewPlaying = false
            previewPlayer.seek(to: .zero)
            viewModel.updateScrubPosition(0)
        }
        .sheet(item: $clipToShare) { clip in
            let items = [viewModel.shareableURL(for: clip)].compactMap { $0 }
            let subject = clip.displayTitle
            ShareSheet(activityItems: items, subject: subject) { _, completed, _, error in
                DispatchQueue.main.async {
                    if let error {
                        viewModel.errorMessage = error.localizedDescription
                    } else if completed {
                        viewModel.statusMessage = "Shared \(clip.displayTitle)."
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.isShowingExportPreview) {
            if let pending = viewModel.pendingExportClips {
                ExportPreviewSheet(
                    clips: pending,
                    onSave: { viewModel.confirmPendingExport() },
                    onCancel: { viewModel.cancelPendingExport() }
                )
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(subscriptionStore)
                .onChange(of: subscriptionStore.tier) { _, newTier in
                    // After the user subscribes (or restores), replay the
                    // action that surfaced the paywall.
                    if newTier != .free, let pending = pendingAction {
                        pendingAction = nil
                        // Haptic confirmation when the upgrade goes through —
                        // makes the "you're a subscriber now" moment feel
                        // earned.
                        PolishKit.Haptics.success.play()
                        // Defer one runloop so the sheet has a chance to dismiss.
                        DispatchQueue.main.async { pending() }
                    }
                }
        }
        .onChange(of: subscriptionStore.tier, initial: true) { _, newTier in
            // Mirror subscription tier into the view model so all downstream
            // limit checks (duration, export preset, AI quota, TikTok share)
            // pick up the user's current plan. The `initial: true` makes sure
            // a restored purchase on cold launch syncs once.
            viewModel.updateTier(newTier)
        }
    }

    private var shouldShowActionDock: Bool {
        viewModel.sourceURL != nil || viewModel.isProcessing || !viewModel.plannedRanges.isEmpty
    }

    /// Ranges currently shown on the timeline preview. In Fixed mode we use the
    /// live `effectiveFixedQuery` so the user sees the planned cut pattern update
    /// the moment they type or change a button. In every other mode the
    /// `plannedRanges` from the last "Plan …" tap is the only thing we have,
    /// so we fall back to that.
    private var liveTimelineRanges: [ClipRange] {
        let duration = viewModel.durationSeconds ?? 0
        guard duration > 0, duration.isFinite else { return viewModel.plannedRanges }

        switch viewModel.cutMode {
        case .fixed:
            if let query = viewModel.effectiveFixedQuery,
               query.isValid,
               let sourceDuration = viewModel.durationSeconds {
                return query.ranges(forSourceDuration: sourceDuration)
            }
            return viewModel.plannedRanges
        case .smartPause, .highlight, .aiAssist:
            return viewModel.plannedRanges
        }
    }

    /// Which clip the timeline should highlight as "selected" — drives the
    /// edge-handle affordance. Explicit user tap wins; otherwise we follow the
    /// scrubber so the user always has a clip selected while previewing, and
    /// fall back to the first clip if the scrubber is in a gap.
    private var effectiveSelectedRangeIndex: Int? {
        let ranges = liveTimelineRanges
        if let userSelectedRangeIndex, ranges.indices.contains(userSelectedRangeIndex) {
            return userSelectedRangeIndex
        }
        if let index = ranges.firstIndex(where: {
            viewModel.scrubPositionSeconds >= $0.startSeconds &&
            viewModel.scrubPositionSeconds <= $0.endSeconds
        }) {
            return index
        }
        return ranges.isEmpty ? nil : 0
    }

    private var editorWorkspace: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerSection
                mediaStage
                cutComposer
                transcriptSection
                plannedClipsSection
                savedClipsSection
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, shouldShowActionDock ? 156 : 28)
            .frame(maxWidth: .infinity)
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .font(.system(size: 13, weight: .bold))
                    Text("Creator cut studio")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.1)
                }
                .foregroundStyle(AppPalette.accent)

                TextField(
                    "Untitled project",
                    text: $viewModel.projectTitleDraft
                )
                .font(.system(size: 38, weight: .black, design: .rounded))
                .foregroundStyle(AppPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .focused($isProjectTitleFocused)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .accessibilityLabel("Project title")
                .accessibilityHint("Tap to rename this project.")
                .onSubmit {
                    viewModel.updateProjectTitle(viewModel.projectTitleDraft)
                    isProjectTitleFocused = false
                }
                .onChange(of: isProjectTitleFocused) { _, isFocused in
                    // Save when the field loses focus (tap outside, dismiss
                    // keyboard, switch tabs) so the user never has to remember
                    // to hit Done.
                    guard !isFocused, isProjectTitleComposing else { return }
                    isProjectTitleComposing = false
                    viewModel.updateProjectTitle(viewModel.projectTitleDraft)
                }
                .onChange(of: isProjectTitleFocused) { _, isFocused in
                    isProjectTitleComposing = isFocused
                }

                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        viewModel.showProjectBrowser()
                        selectedTab = .home
                    } label: {
                        Label("Projects", systemImage: "folder")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.primaryText)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(AppPalette.raisedSurface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                statusCapsule
            }
        }
    }

    private var statusCapsule: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(viewModel.durationLabel)
                .font(.system(.title3, design: .rounded).monospacedDigit().weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
            let label = viewModel.expectedClipCountLabel
            Text(label == "Auto" ? "auto clips" : "\(label) clips")
                .font(.caption.weight(.semibold))
                .foregroundStyle(clipLabelColor(for: label))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(AppPalette.raisedSurface, in: Capsule())
        .overlay {
            Capsule().stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    /// Render the clip-count line in red when it's a truncated "X of Y" so
    /// the discrepancy reads at a glance.
    private func clipLabelColor(for label: String) -> Color {
        if label.contains(" of ") { return AppPalette.danger }
        return AppPalette.secondaryText
    }

    private var mediaStage: some View {
        let pickerTitle = viewModel.sourceURL == nil ? "Import" : "Replace"

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Source", systemImage: "film")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label("Files", systemImage: "externaldrive")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppPalette.primaryText)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .background(AppPalette.controlSurface, in: Capsule())
                            .overlay {
                                Capsule().stroke(AppPalette.hairline, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Import video from Files or connected drive")

                    PhotosPicker(
                        selection: $viewModel.selectedItem,
                        matching: .videos,
                        photoLibrary: .shared()
                    ) {
                        Label(pickerTitle, systemImage: "photo.on.rectangle")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppPalette.primaryText)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .background(AppPalette.controlSurface, in: Capsule())
                            .overlay {
                                Capsule().stroke(AppPalette.hairline, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pickerTitle)
                    .onChange(of: viewModel.selectedItem) { _, newItem in
                        guard newItem != nil else { return }
                        viewModel.importSelectedVideo()
                    }
                }
            }

            if let _ = viewModel.sourceURL {
                videoPreview
            } else {
                emptyVideoState
            }

            if let duration = viewModel.durationSeconds, duration > 0 {
                sourceTimelineScrubber
            }
        }
        .premiumSurface()
    }

    private var videoPreview: some View {
        ZStack {
            AppPalette.mediaWell
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // Controls-free AVPlayerLayer render. We avoid AVKit's
            // VideoPlayer because it ships with its own native scrubber
            // + play/pause controls that fight the waveform scrubber
            // + the custom play button below (two scrubbers on one
            // preview, two sources of truth for "is this playing").
            PreviewVideoView(player: previewPlayer)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(isPreviewPlaying ? 1 : 0.95)
        }
        .frame(height: 240)
        .overlay(alignment: .bottomTrailing) {
            previewPlaybackButton
                .padding(12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var previewPlaybackButton: some View {
        Button {
            togglePreviewPlayback()
        } label: {
            Image(systemName: isPreviewPlaying ? "pause.fill" : "play.fill")
                .font(.headline.weight(.black))
                .foregroundStyle(AppPalette.background)
                .frame(width: 44, height: 44)
                .background(AppPalette.accent, in: Circle())
                .shadow(color: Color.black.opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPreviewPlaying ? "Pause preview" : "Play preview")
    }

    private var emptyVideoState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(AppPalette.accent)

            Text("No source video")
                .font(.headline.weight(.bold))
                .foregroundStyle(AppPalette.primaryText)

            Text("Import a clip from Files or Photos to start planning your cut.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(AppPalette.mediaWell, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var sourceTimelineScrubber: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Preview timeline", systemImage: "rectangle.stack")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)

                Spacer()

                Text("\(viewModel.scrubPositionLabel) / \(viewModel.durationLabel)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)
            }

            HStack(spacing: 10) {
                Picker("Zoom", selection: $viewModel.timelineZoom) {
                    ForEach(TimelineZoom.allCases) { zoom in
                        Text(zoom.rawValue).tag(zoom)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 142)

                Text(viewModel.frameSnapLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.mutedText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            if viewModel.sourceThumbnails.isEmpty {
                thumbnailSkeleton
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.sourceThumbnails) { thumbnail in
                            thumbnailButton(thumbnail)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            WaveformStrip(
                samples: viewModel.waveformSamples,
                plannedRanges: liveTimelineRanges,
                duration: viewModel.durationSeconds ?? 0,
                scrubPosition: viewModel.scrubPositionSeconds,
                onScrub: { seconds in
                    viewModel.updateScrubPosition(seconds)
                    // Scrubbing the waveform repositions the playhead AND
                    // pauses — continuing to play while the user drags
                    // causes visible "skip ahead" jitter. `pause: true`
                    // halts playback; the play button is the only way to
                    // resume. (Previously: scrub called `play: true`,
                    // which started playback on every drag tick.)
                    seekPreview(to: seconds, pause: true)
                    // Scrubbing inside a clip selects it; scrubbing into a gap
                    // clears the selection so the handles disappear.
                    if let index = liveTimelineRanges.firstIndex(where: {
                        seconds >= $0.startSeconds && seconds <= $0.endSeconds
                    }) {
                        userSelectedRangeIndex = index
                    } else {
                        userSelectedRangeIndex = nil
                    }
                },
                selectedRangeIndex: effectiveSelectedRangeIndex,
                frameDuration: viewModel.frameDurationSeconds,
                onSelectRange: { index in
                    userSelectedRangeIndex = index
                    PolishKit.Haptics.selection.play()
                },
                onUpdateRange: { index, newRange in
                    viewModel.updatePlannedRange(at: index, to: newRange)
                },
                draftHighlight: viewModel.cutMode == .highlight ? viewModel.highlightDraft : nil,
                onMoveDraft: { newStart in
                    viewModel.moveHighlightDraft(toStart: newStart)
                },
                onResizeDraftStart: { newStart in
                    viewModel.setHighlightStart(newStart)
                },
                onResizeDraftEnd: { newEnd in
                    viewModel.setHighlightEnd(newEnd)
                }
            )
            .animation(.snappy(duration: 0.22), value: liveTimelineRanges)
            .animation(.snappy(duration: 0.22), value: effectiveSelectedRangeIndex)
            .animation(.snappy(duration: 0.22), value: viewModel.highlightDraft)

            // Previously: a system `Slider` rendered here as a SECOND
            // scrubber on top of the waveform. Two scrubbers, two
            // sources of truth for "where is the playhead" — every
            // scrub tick raced between the two. Now removed; the
            // waveform is the single canonical scrub surface, and the
            // thumbnail row + transcript word taps also seek via
            // `seekPreview(to:)` (no playback change).
        }
        .padding(12)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var thumbnailSkeleton: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppPalette.timelineBlock)
                    .frame(
                        width: timelineThumbnailSize.width,
                        height: timelineThumbnailSize.height
                    )
            }
        }
        .redacted(reason: .placeholder)
    }

    private func thumbnailButton(_ thumbnail: MediaThumbnail) -> some View {
        // Use `liveTimelineRanges` (not `viewModel.plannedRanges`) so the
        // green/red border tracks the cut recipe in real time — typing a new
        // segment length in Fixed mode recolours the thumbnails immediately,
        // without waiting for the user to tap "Plan fixed clips". Until a
        // recipe is valid, `liveTimelineRanges` falls back to the last
        // persisted `plannedRanges`, so existing analyses still display.
        let isInPlannedRange = liveTimelineRanges.contains { range in
            thumbnail.timeSeconds >= range.startSeconds && thumbnail.timeSeconds <= range.endSeconds
        }
        let isNearScrubPosition = abs(thumbnail.timeSeconds - viewModel.scrubPositionSeconds) < max((viewModel.durationSeconds ?? 1) / 24, 0.5)
        let frame = timelineThumbnailFrame(for: thumbnail.image.size)

        // Border color: green (success) when this frame falls inside a planned
        // clip, red (danger) when it falls outside (will be cut). The lime
        // accent stays reserved for the active scrub head.
        let borderColor: Color
        let borderWidth: CGFloat
        if isNearScrubPosition {
            borderColor = AppPalette.accent
            borderWidth = 3
        } else if isInPlannedRange {
            borderColor = AppPalette.success
            borderWidth = 2
        } else {
            borderColor = AppPalette.danger
            borderWidth = 1.5
        }

        return Button {
            viewModel.updateScrubPosition(thumbnail.timeSeconds)
            seekPreview(to: thumbnail.timeSeconds)
        } label: {
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: thumbnail.image)
                    .resizable()
                    .aspectRatio(thumbnail.image.size, contentMode: .fit)
                    .frame(width: frame.width, height: frame.height)
                    .background(AppPalette.mediaWell)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(isInPlannedRange ? 1.0 : 0.32)
                    .saturation(isInPlannedRange ? 1.0 : 0.4)

                Text(ClipRangeFormatter.formatTime(thumbnail.timeSeconds))
                    .font(.system(size: 10, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.48), in: Capsule())
                    .padding(5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(borderColor, lineWidth: borderWidth)
            }
            .overlay(alignment: .topTrailing) {
                if isInPlannedRange {
                    Circle()
                        .fill(AppPalette.success)
                        .frame(width: 8, height: 8)
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Seek to \(ClipRangeFormatter.formatTime(thumbnail.timeSeconds))")
    }

    private var timelineThumbnailSize: CGSize {
        let safeAspectRatio = viewModel.sourceAspectRatio.isFinite && viewModel.sourceAspectRatio > 0
            ? min(max(viewModel.sourceAspectRatio, 0.1), 10)
            : 16.0 / 9.0
        let height = 58.0 * viewModel.timelineZoom.thumbnailScale
        let width = height * safeAspectRatio
        return CGSize(width: width, height: height)
    }

    /// Container frame for a thumbnail, locked to the image's own aspect ratio.
    /// This way the thumbnail always preserves its visual aspect regardless of
    /// how `viewModel.sourceAspectRatio` was computed or which zoom level is
    /// active — and the height still scales with `timelineZoom.thumbnailScale`.
    private func timelineThumbnailFrame(for imageSize: CGSize) -> CGSize {
        let baseHeight = 58.0 * viewModel.timelineZoom.thumbnailScale
        let imageAspect: Double
        if imageSize.width > 0, imageSize.height > 0 {
            imageAspect = Double(imageSize.width / imageSize.height)
        } else {
            imageAspect = viewModel.sourceAspectRatio.isFinite && viewModel.sourceAspectRatio > 0
                ? min(max(viewModel.sourceAspectRatio, 0.1), 10)
                : 16.0 / 9.0
        }
        return CGSize(width: baseHeight * imageAspect, height: baseHeight)
    }

    private var cutComposer: some View {
        VStack(alignment: .leading, spacing: 14) {
            collapsibleSectionTitle(
                "Cut recipe",
                detail: modeDescription,
                section: .cutRecipe,
                systemImage: viewModel.cutMode.symbolName
            )

            if !isSectionCollapsed(.cutRecipe) {
                VStack(spacing: 14) {
                    modeSelector
                    safetyStrip
                    if viewModel.cutMode == .fixed {
                        fixedModeQueryControl
                    } else {
                        // Smart Pause uses the length directly. Highlight
                        // mode ALSO shows this as the fallback default —
                        // `highlightDraftDuration` initializes from it and
                        // any edit here resets the Highlight value back to
                        // match (one-way sync). The Highlight-only "Clip
                        // length" control below is the user override that
                        // DOESN'T write back here.
                        secondsControl
                    }
                    if viewModel.cutMode == .highlight {
                        // Highlight mode is fully manual — no prompt, no AI.
                        // User picks a clip duration, drags the band on the
                        // timeline, taps "Add to plan".
                        highlightDurationControl
                        highlightAddToPlanButton
                    } else if viewModel.cutMode == .aiAssist {
                        promptControl
                    }
                    if viewModel.cutMode == .aiAssist {
                        miniMaxPanel
                    }
                }
                .padding(.top, 4)
            }
        }
        .premiumSurface()
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.secondaryText)

            HStack(spacing: 8) {
                ForEach(CutMode.allCases) { mode in
                    Button {
                        let previous = viewModel.cutMode
                        viewModel.cutMode = mode
                        // When entering Highlight, seed its duration from
                        // the persistent "Seconds per clip" default so
                        // both controls start in sync.
                        if mode == .highlight, previous != .highlight {
                            viewModel.enterHighlightMode()
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: mode.symbolName)
                                .font(.subheadline.weight(.bold))
                            Text(mode.shortTitle)
                                .font(.caption.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(viewModel.cutMode == mode ? AppPalette.background : AppPalette.primaryText)
                        .background(viewModel.cutMode == mode ? AppPalette.accent : AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cut mode \(mode.shortTitle)")
                }
            }
        }
    }

    private var safetyStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                metricTile(
                    title: "Duration",
                    value: viewModel.durationLabel,
                    systemImage: "clock"
                )
                metricTile(
                    title: "Expected",
                    value: viewModel.expectedClipCountLabel,
                    systemImage: "rectangle.stack"
                )
            }
            feasibilityChip
        }
    }

    @ViewBuilder
    private var feasibilityChip: some View {
        if let feasibility = viewModel.liveRecipeFeasibility {
            switch feasibility.severity {
            case .fits:
                if feasibility.requestedCount != nil, feasibility.achievableCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.success)
                        Text(feasibilityExplainer(for: feasibility))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                }
            case .truncated:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.danger)
                    Text(feasibilityExplainer(for: feasibility))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppPalette.danger.opacity(0.35), lineWidth: 1)
                }
            case .tooShort:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.danger)
                    Text("Source is shorter than one clip. Lower the per-clip duration to fit the source, or pick a longer source.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.primaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.danger.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppPalette.danger.opacity(0.5), lineWidth: 1)
                }
            }
        }
    }

    /// "Source can hold 6 clips — you asked for 100."
    /// "Recipe will produce 1 clip, leaving 25s unused."
    private func feasibilityExplainer(for f: ClipQuery.Feasibility) -> String {
        guard let requested = f.requestedCount else { return "" }
        if f.achievableCount == 0 {
            return "Source is shorter than one clip at this duration."
        }
        if f.leftoverSeconds > 0.5 {
            let roundedLeftover = String(format: "%.1f", f.leftoverSeconds)
            return "Will produce \(f.achievableCount) clip\(f.achievableCount == 1 ? "" : "s") (you asked for \(requested)) — \(roundedLeftover)s of source will be left unused."
        }
        return "Will produce \(f.achievableCount) clip\(f.achievableCount == 1 ? "" : "s") (you asked for \(requested))."
    }

    private var secondsControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(secondsFieldTitle)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.secondaryText)

            HStack(spacing: 12) {
                Slider(
                    value: segmentStepperBinding,
                    in: 5...120,
                    step: 1
                )
                .tint(AppPalette.accent)

                Text(viewModel.segmentLengthText)
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    /// Highlight-mode-specific duration input. Same shape as
    /// `secondsControl` but bound to `highlightDraftDuration` so it doesn't
    /// get tangled with Fixed mode's segment-length slider.
    private var highlightDurationControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Clip length")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)
                Spacer()
                Text("\(formattedHighlightDuration) sec")
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
            }

            HStack(spacing: 10) {
                Slider(
                    value: highlightDurationBinding,
                    in: 1...60,
                    step: 1
                )
                .tint(AppPalette.accent)

                Button {
                    viewModel.setHighlightDuration(max(viewModel.highlightDraftDuration - 1, 1))
                } label: {
                    Image(systemName: "minus")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(AppPalette.controlSurface, in: Circle())
                }
                .buttonStyle(.plain)
                Button {
                    viewModel.setHighlightDuration(viewModel.highlightDraftDuration + 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(AppPalette.controlSurface, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The big "Add to plan" button. Committing the current draft appends
    /// it to `plannedRanges`, advances the draft start to the end of the
    /// just-added clip, and persists.
    private var highlightAddToPlanButton: some View {
        Button {
            viewModel.addHighlightDraftToPlan()
            PolishKit.Haptics.selection.play()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                Text("Add to planned clips")
                    .font(.subheadline.weight(.bold))
                Spacer()
                if viewModel.highlightDraft != nil {
                    Text("(\(formattedHighlightStart) → \(formattedHighlightEnd) sec)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppPalette.background.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(viewModel.highlightDraft != nil ? AppPalette.accent : AppPalette.disabledSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(AppPalette.background)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.highlightDraft == nil)
    }

    private var highlightDurationBinding: Binding<Double> {
        Binding(
            get: { viewModel.highlightDraftDuration },
            set: { viewModel.setHighlightDuration($0) }
        )
    }

    private var formattedHighlightDuration: String {
        let v = viewModel.highlightDraftDuration
        let rounded = (v * 10).rounded() / 10
        return rounded.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    private var formattedHighlightStart: String {
        guard let s = viewModel.highlightDraft?.startSeconds else { return "0" }
        return String(format: "%.1f", (s * 10).rounded() / 10)
    }

    private var formattedHighlightEnd: String {
        guard let e = viewModel.highlightDraft?.endSeconds else { return "0" }
        return String(format: "%.1f", (e * 10).rounded() / 10)
    }

    private var fixedModeQueryControl: some View {
        let parsed = viewModel.effectiveFixedQuery

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clip recipe")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)
                Spacer()
                Picker("Input style", selection: Binding(
                    get: { viewModel.fixedModeInputStyle },
                    set: { newStyle in
                        // Two-way sync: carry the user's intent across
                        // modes so neither input feels like a reset.
                        viewModel.syncFixedModeAcrossStyles(to: newStyle)
                        viewModel.fixedModeInputStyle = newStyle
                        PolishKit.Haptics.tap(.light).play()
                    }
                )) {
                    ForEach(FixedModeInputStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            switch viewModel.fixedModeInputStyle {
            case .text:
                fixedModeTextInput
            case .buttons:
                fixedModeButtonInputs
            }

            fixedModeDetectionChips(parsed: parsed)
        }
        .animation(.snappy(duration: 0.2), value: parsed)
    }

    private var fixedModeTextInput: some View {
        let parsed = viewModel.parsedFixedQuery
        let queryEmpty = viewModel.fixedModeQueryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let parsedIsValid = parsed?.isValid == true
        let showRepair = !queryEmpty
            && !parsedIsValid
            && viewModel.isAppleIntelligenceRepairAvailable

        return VStack(alignment: .leading, spacing: 8) {
            TextField(
                "e.g. 4 five-second clips cut every 10 seconds",
                text: $viewModel.fixedModeQueryDraft,
                axis: .vertical
            )
            .lineLimit(2...3)
            .focused($isSegmentFieldFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        parsedIsValid ? AppPalette.accent.opacity(0.55) : AppPalette.hairline,
                        lineWidth: parsedIsValid ? 1.5 : 1
                    )
            }
            .foregroundStyle(AppPalette.primaryText)
            .font(.subheadline)

            HStack(spacing: 6) {
                if queryEmpty {
                    Image(systemName: "info.circle")
                        .font(.caption.weight(.bold))
                    Text("Type a recipe, or switch to Buttons.")
                        .font(.caption)
                } else if parsedIsValid {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption.weight(.bold))
                    Text(parsed?.summary ?? "")
                        .font(.caption.weight(.semibold))
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.bold))
                    Text("Couldn't parse — try \"4 five-second clips every 10 seconds\"")
                        .font(.caption)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(
                queryEmpty
                    ? AppPalette.mutedText
                    : (parsedIsValid ? AppPalette.accent : AppPalette.secondaryText)
            )

            // AI repair affordance. Only visible when the parse failed
            // AND Apple Intelligence is available on this device.
            if showRepair {
                fixedModeRepairAffordance
            }
        }
        .animation(.snappy(duration: 0.2), value: viewModel.fixedModeRepairState)
    }

    @ViewBuilder
    private var fixedModeRepairAffordance: some View {
        switch viewModel.fixedModeRepairState {
        case .idle:
            Button {
                viewModel.repairFixedModeQuery()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.purple)
                    Text("Repair with Apple Intelligence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.primaryText)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppPalette.mutedText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.10), Color.blue.opacity(0.06)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.purple.opacity(0.25), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Repair recipe with Apple Intelligence")

        case .running:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.75)
                Text("Asking Apple Intelligence…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .repaired(let suggestion):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.purple)
                    Text("Suggestion")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.mutedText)
                        .textCase(.uppercase)
                        .tracking(0.6)
                    Spacer(minLength: 0)
                }
                Text(suggestion)
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button {
                        viewModel.applyRepairedFixedModeQuery(suggestion)
                    } label: {
                        Text("Use this")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(AppPalette.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    Button {
                        viewModel.dismissRepairedFixedModeQuery()
                    } label: {
                        Text("Discard")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .background(
                LinearGradient(
                    colors: [Color.purple.opacity(0.08), Color.blue.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.purple.opacity(0.25), lineWidth: 1)
            }

        case .failed(let reason):
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryText)
                Spacer(minLength: 0)
                Button("Try again") {
                    viewModel.repairFixedModeQuery()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var fixedModeButtonInputs: some View {
        VStack(spacing: 10) {
            fixedModeStepper(
                title: "Clip amount",
                systemImage: "rectangle.stack",
                value: Binding(
                    get: { viewModel.fixedModeButtonCount },
                    set: { viewModel.fixedModeButtonCount = max(1, $0) }
                ),
                range: 1...50,
                step: 1,
                unit: ""
            )
            fixedModeStepper(
                title: "Duration of clip",
                systemImage: "clock",
                value: Binding(
                    get: { viewModel.fixedModeButtonDuration },
                    set: { viewModel.fixedModeButtonDuration = max(1, $0) }
                ),
                range: 1...120,
                step: 1,
                unit: "s"
            )
            fixedModeStepper(
                title: "Increment of space",
                systemImage: "arrow.left.and.right",
                value: Binding(
                    get: { viewModel.fixedModeButtonInterval },
                    set: { viewModel.fixedModeButtonInterval = max(1, $0) }
                ),
                range: 1...300,
                step: 1,
                unit: "s"
            )
        }
    }

    private func fixedModeStepper(
        title: String,
        systemImage: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        unit: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 30, height: 30)
                .background(AppPalette.accent.opacity(0.12), in: Circle())

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.primaryText)

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                stepperButton(
                    systemImage: "minus",
                    disabled: value.wrappedValue <= range.lowerBound
                ) {
                    let next = max(range.lowerBound, value.wrappedValue - step)
                    if next != value.wrappedValue {
                        value.wrappedValue = next
                        PolishKit.Haptics.tap(.light).play()
                    }
                }

                // Tappable-to-type: tap the number to type a precise value
                // instead of hammering +/- to reach 47.
                Text("\(value.wrappedValue)\(unit)")
                    .font(.subheadline.monospacedDigit().weight(.black))
                    .foregroundStyle(AppPalette.primaryText)
                    .frame(minWidth: 56)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        PolishKit.Haptics.tap(.light).play()
                        promptForValue(range: range, value: value, unit: unit)
                    }

                stepperButton(
                    systemImage: "plus",
                    disabled: value.wrappedValue >= range.upperBound
                ) {
                    let next = min(range.upperBound, value.wrappedValue + step)
                    if next != value.wrappedValue {
                        value.wrappedValue = next
                        PolishKit.Haptics.tap(.light).play()
                    }
                }
            }
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }
            .animation(.snappy(duration: 0.18), value: value.wrappedValue)
        }
    }

    /// Single +/- button used inside `fixedModeStepper`. Prominent border
    /// + 44pt hit area + opacity-on-disabled so it both reads and behaves
    /// reliably.
    @ViewBuilder
    private func stepperButton(
        systemImage: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .frame(width: 44, height: 44)
                .foregroundStyle(disabled ? AppPalette.mutedText : AppPalette.primaryText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// Present a tiny alert with a numeric TextField so the user can type
    /// an exact value rather than tapping +/- to reach it. We coerce to
    /// the stepper's range and apply a haptic on commit.
    private func promptForValue(range: ClosedRange<Int>, value: Binding<Int>, unit: String) {
        let alert = UIAlertController(
            title: "Enter value",
            message: "Pick a number between \(range.lowerBound) and \(range.upperBound)\(unit).",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.keyboardType = UIKeyboardType.numberPad
            tf.text = "\(value.wrappedValue)"
            tf.clearButtonMode = UITextField.ViewMode.whileEditing
            tf.selectAll(nil)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Set", style: .default) { _ in
            let raw = alert.textFields?.first?.text ?? ""
            if let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               range.contains(parsed) {
                value.wrappedValue = parsed
                PolishKit.Haptics.tap(.light).play()
            } else {
                PolishKit.Haptics.warning.play()
            }
        })
        // Walk up the responder chain to find the topmost VC.
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return }
        // Walk to the topmost presented controller so we present above
        // any sheets (e.g. the paywall) that might be in the stack.
        var top: UIViewController = root
        while let presented = top.presentedViewController { top = presented }
        top.present(alert, animated: true)
    }

    @ViewBuilder
    private func fixedModeDetectionChips(parsed: ClipQuery?) -> some View {
        HStack(spacing: 8) {
            fixedModeChip(
                title: "Count",
                value: parsed?.count.map { "\($0)" },
                detected: parsed?.detectedCount == true
            )
            fixedModeChip(
                title: "Duration",
                value: parsed?.durationSeconds.map { "\(Int($0))s" },
                detected: parsed?.detectedDuration == true
            )
            fixedModeChip(
                title: "Spacing",
                value: parsed?.intervalSeconds.map { "\(Int($0))s" },
                detected: parsed?.detectedInterval == true
            )
        }
    }

    private func fixedModeChip(title: String, value: String?, detected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: detected ? "checkmark.circle.fill" : "circle.dashed")
                .font(.caption.weight(.bold))
                .foregroundStyle(detected ? AppPalette.accent : AppPalette.mutedText)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.mutedText)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text(value ?? "—")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(detected ? AppPalette.primaryText : AppPalette.mutedText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (detected ? AppPalette.accent.opacity(0.15) : AppPalette.controlSurface),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(detected ? AppPalette.accent.opacity(0.45) : AppPalette.hairline, lineWidth: 1)
        }
    }

    private var promptControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit intent")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.secondaryText)

            TextField(
                "What should the cut feel like?",
                text: $viewModel.editPrompt,
                axis: .vertical
            )
            .lineLimit(2...4)
            .focused($isSegmentFieldFocused)
            .textInputAutocapitalization(.sentences)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }
            .foregroundStyle(AppPalette.primaryText)
        }
    }

    @ViewBuilder
    private var miniMaxPanel: some View {
        if !viewModel.hasMiniMaxAPIKey {
            VStack(alignment: .leading, spacing: 8) {
                Text("MiniMax API key required")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)

                Text("Add your MiniMax API key in Settings to use AI Assist.")
                    .font(.caption)
                    .foregroundStyle(AppPalette.mutedText)
            }
        }
    }

    private var transcriptSection: some View {
        TranscriptView(
            transcript: viewModel.transcript,
            state: viewModel.transcriptState,
            plannedRanges: liveTimelineRanges,
            onTapWord: { word in
                viewModel.updateScrubPosition(word.startSeconds)
                seekPreview(to: word.startSeconds)
            },
            onRetranscribe: {
                guard let url = viewModel.sourceURL else { return }
                viewModel.transcript = nil
                viewModel.transcriptState = .processing
                Task { [weak viewModel] in
                    let service = TranscriptService()
                    do {
                        let result = try await service.transcribe(audioFileURL: url)
                        guard let viewModel else { return }
                        viewModel.transcript = result
                        viewModel.transcriptState = .ready
                        viewModel.persistCurrentProject()
                    } catch {
                        guard let viewModel else { return }
                        viewModel.transcriptState = .failed(error.localizedDescription)
                    }
                }
            },
            exportTier: .studio,
            canExport: subscriptionStore.hasAccess(to: .studio),
            onRequestUpgrade: {
                pendingAction = nil
                showPaywall = true
            }
        )
    }

    private var plannedClipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            collapsibleSectionTitle(
                "Planned clips",
                detail: plannedClipsDetail,
                section: .plannedClips,
                systemImage: "list.bullet.rectangle"
            )

            if !isSectionCollapsed(.plannedClips) {
                if viewModel.plannedRanges.isEmpty {
                    plannedClipsEmptyState
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(viewModel.plannedRanges.indices), id: \.self) { index in
                            clipRangeRow(index: index, range: viewModel.plannedRanges[index])
                        }
                    }
                }
            }
        }
        .premiumSurface()
    }

    private func clipRangeRow(index: Int, range: ClipRange) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("#\(index + 1)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.background)
                    .frame(width: 34, height: 34)
                    .background(AppPalette.accent, in: Circle())
                Text(ClipRangeFormatter.durationLabel(for: range))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(ClipRangeFormatter.title(for: range))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)

                EditableClipRangeBar(
                    range: range,
                    duration: viewModel.durationSeconds ?? 0,
                    frameDuration: 1.0 / 30.0,
                    onChange: { newRange in
                        viewModel.updatePlannedRange(at: index, to: newRange)
                    }
                )
            }
        }
        .padding(12)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var savedClipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            collapsibleSectionTitle(
                "Saved clips",
                detail: viewModel.clips.isEmpty
                    ? "None yet"
                    : (viewModel.clips.count == 1 ? "1 clip" : "\(viewModel.clips.count) clips"),
                section: .savedClips,
                systemImage: "checkmark.circle"
            )

            if !isSectionCollapsed(.savedClips), !viewModel.clips.isEmpty {
                VStack(spacing: 10) {
                    ForEach(viewModel.clips) { clip in
                        savedClipRow(clip)
                    }
                }
            }
        }
        .premiumSurface()
    }

    private func savedClipRow(_ clip: SegmentOutput) -> some View {
        let isShareable = viewModel.isClipShareable(clip)
        let clipRange = ClipRange(startSeconds: clip.startSeconds, endSeconds: clip.endSeconds)
        let midpoint = (clip.startSeconds + clip.endSeconds) / 2

        return HStack(spacing: 12) {
            VideoThumbnailView(
                id: clip.id,
                url: clip.url,
                fallbackSymbol: "film",
                midpointSeconds: midpoint,
                cornerRadius: 10,
                iconFont: .headline.weight(.bold)
            )
            .frame(width: 56, height: 56)
            .opacity(isShareable ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 4) {
                EditableClipTitleField(
                    clip: clip,
                    onCommit: { newTitle in
                        viewModel.renameClip(clip.id, to: newTitle)
                    }
                )
                Text(ClipRangeFormatter.durationLabel(for: clipRange))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
            }

            Spacer()

            Button {
                presentShareSheet(for: clip)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(isShareable ? AppPalette.primaryText : AppPalette.mutedText)
                    .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isShareable)
            .accessibilityLabel("Open iOS share sheet for \(clip.title)")
        }
        .padding(12)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isShareable ? AppPalette.hairline : AppPalette.hairline.opacity(0.45), lineWidth: 1)
        }
    }

    private var actionDock: some View {
        VStack(spacing: 10) {
            if viewModel.isProcessing {
                ProgressView(value: viewModel.progress)
                    .tint(AppPalette.accent)
                    .progressViewStyle(.linear)

                PolishKit.ShimmerText(
                    text: "\(progressPercent)% complete",
                    systemImage: "wand.and.stars",
                    tint: AppPalette.accent
                )
            }

            HStack(spacing: 10) {
                Button {
                    isSegmentFieldFocused = false
                    PolishKit.Haptics.tap(.medium).play()
                    guardActionAndShowPaywallIfNeeded {
                        viewModel.prepareCuts()
                    }
                } label: {
                    Label(viewModel.isProcessing ? "Processing" : analyzeButtonTitle, systemImage: "wand.and.stars")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.background)
                .background(viewModel.canPrepare ? AppPalette.accent : AppPalette.disabledSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .disabled(!viewModel.canPrepare)
                .polishPressFeedback(scale: 0.97, pressedOpacity: 0.85)

                if viewModel.isProcessing {
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
            }

            if !viewModel.plannedRanges.isEmpty {
                Button {
                    isSegmentFieldFocused = false
                    PolishKit.Haptics.tap(.medium).play()
                    viewModel.exportPreparedClips()
                } label: {
                    Label("Export & Save to Photos", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.canExportPreparedClips ? AppPalette.primaryText : AppPalette.mutedText)
                .background(viewModel.canExportPreparedClips ? AppPalette.controlSurface : AppPalette.disabledSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(!viewModel.canExportPreparedClips)
                .polishPressFeedback()
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

    private var segmentStepperBinding: Binding<Double> {
        Binding(
            get: {
                viewModel.parsedSegmentLength ?? 30
            },
            set: { newValue in
                guard newValue.isFinite else { return }
                viewModel.segmentLengthText = "\(Int(newValue.rounded()))"
            }
        )
    }

    /// Run an action if entitlement allows; otherwise stash the action and
    /// show the paywall. The action re-runs after the user subscribes
    /// because `PaywallView` listens to tier change and we read pendingAction
    /// back in `onChange(of:)`.
    private func guardActionAndShowPaywallIfNeeded(_ action: @escaping () -> Void) {
        // AI Assist requires Creator; the other modes run for free.
        let required: SubscriptionStore.Tier = (viewModel.cutMode == .aiAssist) ? .creator : .free
        if subscriptionStore.hasAccess(to: required) {
            action()
        } else {
            pendingAction = action
            showPaywall = true
        }
    }

    private var progressPercent: Int {
        guard viewModel.progress.isFinite else { return 0 }
        return Int((min(max(viewModel.progress, 0), 1) * 100).rounded())
    }

    // `scrubBinding` removed — the system Slider that used it was removed.
    // Waveform scrub, thumbnail tap, and transcript word taps all seek
    // directly via `seekPreview(to:)`. Single source of truth for
    // "where is the playhead."

    /// Seek the preview player to a specific time and *optionally* start
    /// playback.
    ///
    /// Scrubbing the waveform, tapping a thumbnail, or tapping a transcript
    /// word only repositions the playhead — it does NOT auto-start playback.
    /// The play button is the single path that ever calls `play: true`.
    /// This avoids the bug where every scrub tick forced playback to start.
    ///
    /// `play()` and `pause()` are idempotent on `AVPlayer`, so we always
    /// call them unconditionally — no `timeControlStatus` race against the
    /// async `seek`.
    ///
    /// When `play: false` (the default), `seekPreview` preserves the current
    /// playback state: if the user is already playing, playback continues
    /// from the new position; if they're paused, they stay paused. This
    /// matches the "tap a thumbnail to jump there and keep watching" mental
    /// model while letting the waveform scrub explicitly pause (it passes
    /// `pause: true`).
    private func seekPreview(to seconds: Double, play: Bool = false, pause: Bool = false) {
        guard seconds.isFinite, seconds >= 0 else { return }
        // Don't try to drive a player that has no media attached — that
        // path leads to AVFoundation throwing inside `play()` and crashing
        // the editor view. The play button is the only path that should
        // ever start playback for a fresh import; scrubbing on an empty
        // timeline is a no-op until the user picks a video.
        guard previewPlayer.currentItem != nil else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        previewPlayer.seek(
            to: time,
            toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600)
        )
        if play {
            // Previously gated on `timeControlStatus != .playing` which
            // raced against the async `seek` above. `play()` is idempotent
            // when already playing, so just call it.
            previewPlayer.play()
            isPreviewPlaying = true
        } else if pause {
            // Explicit pause — waveform scrub passes this so dragging the
            // playhead halts playback. Without it, continuing to play while
            // the user drags causes visible "skip ahead" jitter.
            previewPlayer.pause()
            isPreviewPlaying = false
        }
        // else: neither play nor pause — preserve current state. A
        // thumbnail or transcript-word tap jumps the playhead but lets
        // playback continue (or stay paused) as it was.
    }

    private func togglePreviewPlayback() {
        guard previewPlayer.currentItem != nil else { return }
        if isPreviewPlaying {
            previewPlayer.pause()
            isPreviewPlaying = false
        } else {
            // First-time play: bring up the audio session so sound comes
            // through even when the ringer switch is off. Done here (not
            // at view appear) because activating the audio session takes
            // over the audio route from other apps, which is appropriate
            // the moment the user explicitly asks for sound.
            configureAudioSessionForPlayback()
            previewPlayer.play()
            isPreviewPlaying = true
        }
    }

    private func configureAudioSessionForPlayback() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true, options: [])
        } catch {
            // Non-fatal — the video still previews without sound.
        }
    }

    private var analyzeButtonTitle: String {
        switch viewModel.cutMode {
        case .fixed:
            return "Plan Fixed Clips"
        case .smartPause:
            return "Analyze Smart Cuts"
        case .highlight:
            return "Find Highlights"
        case .aiAssist:
            return viewModel.hasMiniMaxAPIKey ? "Ask MiniMax" : "Add MiniMax Key"
        }
    }

    private var secondsFieldTitle: String {
        // Non-fixed modes use the same length internally as a fallback when
        // their first-pass analysis doesn't find cuts, but that's an internal
        // detail — the label stays user-facing either way.
        return "Seconds per clip"
    }

    private var modeDescription: String {
        switch viewModel.cutMode {
        case .fixed:
            return "Exact chunks for quick batch prep."
        case .smartPause:
            return "Finds quiet audio gaps and keeps fallback timing ready."
        case .highlight:
            return "Scores visual moments with on-device analysis."
        case .aiAssist:
            return "Uses local timeline signals and MiniMax M3 to draft clips."
        }
    }

    private var plannedClipsDetail: String {
        let count = viewModel.plannedRanges.count

        guard count > 0 else {
            return "No plan yet"
        }

        let countLabel = count == 1 ? "1 clip" : "\(count) clips"
        return viewModel.hasUnsavedPlan ? "\(countLabel) - Review" : "\(countLabel) - Exported"
    }

    private var plannedClipsEmptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 32, height: 32)
                .background(AppPalette.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("No clips planned")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                Text("Adjust the recipe or run analysis to preview the cut list.")
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.clearError()
                }
            }
        )
    }

    private func presentShareSheet(for clip: SegmentOutput) {
        guard viewModel.isClipShareable(clip) else {
            viewModel.errorMessage = "This clip file is no longer available. Export the planned clips again to share it."
            return
        }

        clipToShare = clip
    }

    private func isSectionCollapsed(_ section: CollapsibleSection) -> Bool {
        collapsedSections.contains(section)
    }

    private func toggleSection(_ section: CollapsibleSection) {
        withAnimation(.snappy(duration: 0.22)) {
            if collapsedSections.contains(section) {
                collapsedSections.remove(section)
            } else {
                collapsedSections.insert(section)
            }
        }
    }

    private func collapsibleSectionTitle(
        _ title: String,
        detail: String,
        section: CollapsibleSection,
        systemImage: String
    ) -> some View {
        let isCollapsed = isSectionCollapsed(section)

        return Button {
            toggleSection(section)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 32, height: 32)
                    .background(AppPalette.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text(detail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.black))
                    .foregroundStyle(AppPalette.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Expand \(title)" : "Collapse \(title)")
    }

    private func metricTile(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 30, height: 30)
                .background(AppPalette.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                Text(value)
                    .font(.subheadline.monospacedDigit().weight(.black))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }
}

/// Inline-editable clip title. Always shows a TextField (styled to read like
/// static text) so renaming doesn't need a mode toggle. Local `@State draft`
/// is the source of truth while the field is focused; on submit or focus-loss
/// we hand the trimmed value back via `onCommit`. Re-syncs from `clip.title`
/// when the parent updates the title for a reason unrelated to this field
/// (e.g. project rename regenerating defaults) and we're not actively editing.
private struct EditableClipTitleField: View {
    let clip: SegmentOutput
    let onCommit: (String) -> Void
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(clip: SegmentOutput, onCommit: @escaping (String) -> Void) {
        self.clip = clip
        self.onCommit = onCommit
        _draft = State(initialValue: clip.title)
    }

    var body: some View {
        TextField(clip.displayTitle, text: $draft)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(AppPalette.primaryText)
            .lineLimit(1)
            .submitLabel(.done)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .focused($isFocused)
            .accessibilityLabel("Clip title")
            .accessibilityHint("Tap to rename this clip.")
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: clip.title) { _, newValue in
                // External title change — only re-seed if the user isn't
                // actively typing, otherwise we'd clobber their edits.
                guard !isFocused, draft != newValue else { return }
                draft = newValue
            }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // No-op if the value matches the stored title and the draft isn't
        // visibly different — avoids an unnecessary persist round-trip when
        // the user taps the field and walks away.
        guard trimmed != clip.title.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return
        }
        onCommit(trimmed)
    }
}