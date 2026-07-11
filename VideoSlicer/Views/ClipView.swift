import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum CollapsibleSection: Hashable {
    case cutRecipe
    case plannedClips
    case savedClips
    case transcript
}

struct ClipView: View {
    @EnvironmentObject private var viewModel: VideoSplitterViewModel
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Binding var selectedTab: RootView.AppTab

    @State private var previewPlayer = AVPlayer()
    @State private var isPreviewPlaying = false
    @State private var isScrubbing = false
    @State private var isSceneSourceFileImporterPresented = false
    @State private var isSceneSourceSheetPresented = false
    @State private var sceneSourcePickerItem: PhotosPickerItem? = nil
    @State private var pendingSceneSourceFileURL: URL? = nil
    @State private var pendingSceneSourcePhotoItem: PhotosPickerItem? = nil
    @State private var isSceneSourcePlanDialogPresented = false
    @State private var isSceneResetConfirmationPresented = false
    @State private var isExportTargetChooserPresented = false
    @State private var isExportScenePickerPresented = false
    /// Drives the per-project export-settings sheet. Opens via
    /// the header pill (see `exportSettingsPill`); saves via
    /// `viewModel.updateExportSettings(_:)`.
    @State private var isExportSettingsSheetPresented = false
    // .reelclip project file export — separate from the bottom
    // "Export" button which renders video clips. Top header button
    // (formerly "Projects") now triggers this so the user can save
    // the whole project to Files / iCloud Drive without leaving the
    // editor. See `prepareReelClipExport` + the `.fileExporter`
    // modifier on the root.
    @State private var isReelClipExporterPresented = false
    @State private var reelClipExportURL: URL?
    @State private var collapsedSections: Set<CollapsibleSection> = [.transcript, .plannedClips]
    @State private var showPaywall = false
    @State private var pendingAction: (() -> Void)?
    @State private var previewTimeObserver: Any?
    @State private var userSelectedRangeIndex: Int? = nil
    @State private var isProjectTitleComposing: Bool = false
    @State private var loopPlayer = AVPlayer()
    @State private var loopingClipIndex: Int? = nil
    @State private var loopingProjectPreviewID: String? = nil
    @State private var loopingSavedClipID: String? = nil
    @State private var loopObserver: NSObjectProtocol? = nil
    /// Discrete size level for the main video preview. The
    /// user cycles through these via a button pinned to the
    /// bottom-left of the preview box — `.auto` fits the
    /// source aspect to the available width, the named levels
    /// (.small / .medium / .large) set a fixed height. Tighter
    /// UX than a free-form drag handle: the user knows what
    /// they're going to get, and the 3-step cycle is fast
    /// enough that finding the right size is one or two taps.
    /// Replaces the drag-to-resize handle which was buggy
    /// (gesture conflicts with the existing tap path, the
    /// visual feedback was a thin pill that's hard to grab
    /// on a phone-sized screen, and the free-form height had
    /// no obvious meaning).
    @State private var previewSizeLevel: PreviewSizeLevel = .medium
    /// Observer + state for the main preview's "loop within the
    /// selected clip" behavior. When the user picks a planned
    /// range and taps play, we set the AVPlayerItem's
    /// forwardPlaybackEndTime to the clip's end and observe
    /// .AVPlayerItemDidPlayToEndTime so we can rewind to the
    /// start and keep playing. The loop is cleared on pause,
    /// scene switch, source change, or selection clear.
    @State private var clipLoopObserver: NSObjectProtocol? = nil
    @State private var clipLoopActiveRangeIndex: Int? = nil
    @FocusState private var isSegmentFieldFocused: Bool
    @FocusState private var isProjectTitleFocused: Bool
    @State private var isSceneRenamePresented = false
    @State private var sceneNameDraft = ""
    @State private var scenePendingDelete: MediaProjectScene? = nil
    /// Drives the confirmation alert for the destructive "Clear
    /// saved clips" affordance in the saved-clips section. Kept
    /// distinct from the planned-clips clear flow so a clear on
    /// one side doesn't accidentally wipe the other.
    @State private var isClearSavedClipsPresented = false
    @State private var isClearPlannedClipsPresented = false
    @State private var showAppleIntelligenceInfo: Bool = false
    @State private var isClearProjectExportPresented = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()
                editorWorkspace
            }
            .navigationBarTitleDisplayMode(.inline)
            // Keyboard accessory: only show a Done button when a
            // `isSegmentFieldFocused` field is focused. Without
            // this gate, the keyboard input accessory is added to
            // EVERY TextField in the editor (project title, clip
            // title, the random-range value alert) which stacks
            // on top of any per-field `.submitLabel(.done)` /
            // per-field `.toolbar` Done button and gives the user
            // a "Done, Done" pair. Per-field toolbars own the
            // dismiss path for the project title + clip title
            // (they explicitly release focus + commit on
            // onChange), and the alert TextFields dismiss via
            // their own Set/Cancel. So the shared toolbar only
            // needs to handle the prompt + query fields that
            // share `isSegmentFieldFocused`.
            .toolbar {
                if isSegmentFieldFocused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            isSegmentFieldFocused = false
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if shouldShowActionDock {
                    ClipExportActionDock(
                        dismissKeyboard: { isSegmentFieldFocused = false },
                        chooseExportTarget: { isExportTargetChooserPresented = true }
                    )
                    .environmentObject(viewModel)
                }
            }
            .alert("Processing stopped", isPresented: errorBinding) {
                Button("OK") {
                    viewModel.clearError()
                }
            } message: {
                Text(viewModel.errorMessage ?? "Try another video or segment length.")
            }
            .alert("Rename scene", isPresented: $isSceneRenamePresented) {
                TextField("Scene name", text: $sceneNameDraft)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .onSubmit {
                        viewModel.renameActiveScene(to: sceneNameDraft)
                    }
                Button("Save") {
                    viewModel.renameActiveScene(to: sceneNameDraft)
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Clear saved clips?", isPresented: $isClearSavedClipsPresented) {
                Button("Clear saved", role: .destructive) {
                    viewModel.clearSavedClips()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let count = viewModel.savedClips.count
                Text(count == 1
                     ? "This removes the 1 clip you previously committed. You can re-save the planned clips to commit them again."
                     : "This removes the \(count) clips you previously committed. You can re-save the planned clips to commit them again.")
            }
            .alert("Clear planned clips?", isPresented: $isClearPlannedClipsPresented) {
                Button("Clear planned", role: .destructive) {
                    viewModel.clearPlannedRangesForCurrentMode()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let count = viewModel.plannedRangesForCurrentMode.count
                Text(count == 1
                     ? "This removes the 1 planned clip in the current scene and recipe."
                     : "This removes the \(count) planned clips in the current scene and recipe.")
            }
            .alert("Clear project export preview?", isPresented: $isClearProjectExportPresented) {
                Button("Clear project", role: .destructive) {
                    viewModel.clearProjectExportPlan()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let count = projectPlannedClipPreviewItems.count
                Text(count == 1
                     ? "This removes the 1 planned clip from the project export queue."
                     : "This removes all \(count) planned clips from the project export queue across scenes.")
            }
        }
        .tint(AppPalette.accent)
        .fileExporter(
            isPresented: $isReelClipExporterPresented,
            document: ReelClipProjectDocument(url: reelClipExportURL),
            contentType: UTType.reelClipProject,
            defaultFilename: reelClipExportURL?.deletingPathExtension().lastPathComponent ?? "ReelClip Project"
        ) { result in
            // Tidy up the temp file regardless of outcome —
            // same pattern as HomeView's exporter handler.
            if let url = reelClipExportURL {
                try? FileManager.default.removeItem(at: url)
            }
            reelClipExportURL = nil
            switch result {
            case .success:
                viewModel.statusMessage = "Exported project file."
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: viewModel.sourceURL) { _, newURL in
            isPreviewPlaying = false
            userSelectedRangeIndex = nil
            previewPlayer.pause()
            removePreviewTimeObserver()
            // Source changed — drop the clip loop because the
            // observer is bound to the old item and the new
            // item has no forwardPlaybackEndTime. Cleared
            // before replaceCurrentItem so the loop teardown
            // can find the old item.
            clearClipLoop()
            stopPlannedClipLoop()
            if let previewURL = viewModel.resolvedPlaybackURL(for: newURL) {
                previewPlayer.replaceCurrentItem(with: AVPlayerItem(url: previewURL))
                installPreviewTimeObserver()
            } else {
                previewPlayer.replaceCurrentItem(with: nil)
            }
        }
        .onChange(of: viewModel.playbackURL) { _, newURL in
            guard viewModel.sourceURL != nil, let newURL else { return }
            replacePreviewMediaPreservingPosition(with: newURL)
        }
        // Scene / selection change — also drop the loop. The
        // user might have selected a different range, or
        // switched to a scene with a different source entirely.
        // Either way the previous loop is no longer meaningful.
        .onChange(of: viewModel.activeSceneId) { _, _ in
            userSelectedRangeIndex = nil
            clearClipLoop()
            stopPlannedClipLoop()
        }
        .onChange(of: viewModel.cutMode) { _, _ in
            userSelectedRangeIndex = nil
            clearClipLoop()
            stopPlannedClipLoop()
        }
        .onChange(of: userSelectedRangeIndex) { _, _ in
            // If the user clears the selection (or picks a
            // different range), the loop should follow. The
            // observer stays installed; just retarget the loop
            // boundaries so the next play uses the new range.
            if let newIndex = userSelectedRangeIndex,
               viewModel.plannedRanges.indices.contains(newIndex) {
                if isPreviewPlaying, clipLoopActiveRangeIndex != newIndex {
                    setupClipLoop(for: viewModel.plannedRanges[newIndex], at: newIndex)
                }
            } else {
                clearClipLoop()
            }
        }
        .onAppear {
            if previewPlayer.currentItem == nil,
               let playbackURL = viewModel.resolvedPlaybackURL(for: viewModel.sourceURL) {
                previewPlayer.replaceCurrentItem(with: AVPlayerItem(url: playbackURL))
            }
            installPreviewTimeObserver()
        }
        .onDisappear {
            previewPlayer.pause()
            isPreviewPlaying = false
            removePreviewTimeObserver()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let endedItem = notification.object as? AVPlayerItem,
                  endedItem == previewPlayer.currentItem
            else {
                return
            }
            isPreviewPlaying = false
            previewPlayer.seek(to: .zero)
            viewModel.updateScrubPosition(0)
        }
        .sheet(isPresented: $viewModel.isShowingExportPreview) {
            exportPreviewSheet
        }
        .sheet(isPresented: $viewModel.showTightenedPreview) {
            tightenedPreviewSheet
        }
        .alert(
            "Reset \(viewModel.activeSceneName)?",
            isPresented: $isSceneResetConfirmationPresented
        ) {
            Button("Reset scene", role: .destructive) {
                viewModel.resetActiveSceneToEmpty()
                userSelectedRangeIndex = nil
                clearClipLoop()
                stopPlannedClipLoop()
                PolishKit.Haptics.warning.play()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the source video, recipe drafts, planned clips, saved clips, and export preview. The project and scene stay in place.")
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
            // limit checks (duration, export preset, AI quota, transcript export)
            // pick up the user's current plan. The `initial: true` makes sure
            // a restored purchase on cold launch syncs once.
            viewModel.updateTier(newTier)
        }
    }

    private var shouldShowActionDock: Bool {
        viewModel.sourceURL != nil || viewModel.isProcessing || !viewModel.plannedRanges.isEmpty
    }

    /// Indices into `viewModel.plannedRanges` whose `cutMode` matches the
    /// current cut mode — the same filter `liveTimelineRanges` uses to
    /// decide what to render on the timeline. We keep the original
    /// indices (not the filtered ranges) so call sites that index
    /// back into `viewModel.plannedRanges` (select / delete / loop
    /// preview) keep working without remapping.
    private var visiblePlannedRangeIndices: [Int] {
        viewModel.plannedRanges.indices.filter { index in
            viewModel.plannedRanges[index].cutMode == viewModel.cutMode
        }
    }

    /// Ranges currently shown on the timeline preview. In Fixed mode we use the
    /// live `effectiveFixedQuery` so the user sees the planned cut pattern update
    /// the moment they type or change a button. In every other mode the
    /// `plannedRanges` from the last "Plan …" tap is the only thing we have,
    /// so we fall back to that.
    private var liveTimelineRanges: [ClipRange] {
        let duration = viewModel.durationSeconds ?? 0
        guard duration > 0, duration.isFinite else { return viewModel.plannedRangesForCurrentMode }

        // Fixed mode shows the live query ranges (computed from the
        // current count/segmentLength settings) and falls back to
        // planned ranges stamped with `.fixed` when there's no query.
        // We filter by cutMode so a highlight clip planned earlier
        // doesn't bleed into fixed mode and confuse the user.
        switch viewModel.cutMode {
        case .fixed:
            if let sourceDuration = viewModel.durationSeconds {
                let ranges = viewModel.fixedModeRanges(forSourceDuration: sourceDuration)
                if !ranges.isEmpty { return ranges }
            }
            return viewModel.plannedRanges.filter { $0.cutMode == .fixed }
        case .highlight:
            return viewModel.plannedRanges.filter { $0.cutMode == .highlight }
        case .smartPause:
            let smartPauseRanges = viewModel.plannedRanges.filter { $0.cutMode == .smartPause }
            if !smartPauseRanges.isEmpty { return smartPauseRanges }
            return liveSegmentDurationPreview.map { [$0] } ?? []
        case .aiAssist:
            let aiAssistRanges = viewModel.plannedRanges.filter { $0.cutMode == .aiAssist }
            if !aiAssistRanges.isEmpty { return aiAssistRanges }
            return liveSegmentDurationPreview.map { [$0] } ?? []
        }
    }

    private var liveSegmentDurationPreview: ClipRange? {
        guard let duration = viewModel.durationSeconds,
              duration.isFinite,
              duration > 0,
              let segmentLength = viewModel.parsedSegmentLength,
              segmentLength.isFinite,
              segmentLength > 0
        else {
            return nil
        }

        let length = min(segmentLength, duration)
        let start = min(
            max(viewModel.scrubPositionSeconds, 0),
            max(0, duration - length)
        )
        return ClipRange(startSeconds: start, endSeconds: min(start + length, duration))
    }

    private func requestSceneSourceReplacement(
        fileURL: URL? = nil,
        photoItem: PhotosPickerItem? = nil
    ) {
        guard fileURL != nil || photoItem != nil else { return }
        guard !viewModel.isImportingMedia else {
            clearPendingSceneSourceReplacement()
            return
        }

        pendingSceneSourceFileURL = fileURL
        pendingSceneSourcePhotoItem = photoItem

        guard !viewModel.plannedRanges.isEmpty else {
            performPendingSceneSourceReplacement(planAction: .keep)
            return
        }

        isSceneSourcePlanDialogPresented = true
    }

    private func performPendingSceneSourceReplacement(planAction: SceneSourceReplacementPlanAction) {
        if let fileURL = pendingSceneSourceFileURL {
            viewModel.replaceActiveSceneSource(from: fileURL, planAction: planAction)
        } else if let photoItem = pendingSceneSourcePhotoItem {
            viewModel.replaceActiveSceneSource(from: photoItem, planAction: planAction)
        }

        clearPendingSceneSourceReplacement()
    }

    private func clearPendingSceneSourceReplacement() {
        pendingSceneSourceFileURL = nil
        pendingSceneSourcePhotoItem = nil
        isSceneSourcePlanDialogPresented = false
        sceneSourcePickerItem = nil
        if viewModel.hasOpenProjectContext {
            viewModel.selectedItem = nil
        }
    }

    /// Which clip the timeline should highlight as "selected" — drives the
    /// edge-handle affordance. Explicit user tap wins; otherwise we follow the
    /// scrubber so the user always has a clip selected while previewing, and
    /// fall back to the first clip if the scrubber is in a gap.
    private var effectiveSelectedRangeIndex: Int? {
        guard !liveTimelineRanges.isEmpty else { return nil }
        let ranges = liveTimelineRanges
        if !isUsingGeneratedFixedTimelinePreview,
           let userSelectedRangeIndex,
           let timelineIndex = visiblePlannedRangeIndices.firstIndex(of: userSelectedRangeIndex),
           ranges.indices.contains(timelineIndex) {
            return timelineIndex
        }
        if let index = ranges.firstIndex(where: {
            viewModel.scrubPositionSeconds >= $0.startSeconds &&
            viewModel.scrubPositionSeconds <= $0.endSeconds
        }) {
            return index
        }
        return ranges.isEmpty ? nil : 0
    }

    private var isUsingGeneratedFixedTimelinePreview: Bool {
        guard viewModel.cutMode == .fixed,
              let sourceDuration = viewModel.durationSeconds else {
            return false
        }
        return !viewModel.fixedModeRanges(forSourceDuration: sourceDuration).isEmpty
    }

    private func plannedRangeIndex(forTimelineIndex timelineIndex: Int) -> Int? {
        guard !isUsingGeneratedFixedTimelinePreview else { return nil }
        let visibleIndices = visiblePlannedRangeIndices
        guard visibleIndices.indices.contains(timelineIndex) else { return nil }
        return visibleIndices[timelineIndex]
    }

    private var editorWorkspace: AnyView {
        AnyView(
            ScrollView {
                VStack(spacing: 18) {
                    // `Spacer` at the very top of the scroll
                    // content so the preference-key GeometryReader
                    // below has a stable `minY` baseline (the
                    // spacer's top edge). Without it, the inner
                    // content's `minY` would equal the content's
                    // own height, which is way more than the
                    // threshold we care about. The spacer is 0pt
                    // tall so it doesn't shift the layout.
                    Color.clear.frame(height: 0)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: EditorScrollOffsetKey.self,
                                    value: proxy.frame(in: .named("editor-scroll")).minY
                                )
                            }
                        )
                    headerSection
                    // Cut recipe tabs (Splice / Cut / Silence / AI)
                    // pulled out of the source card so the row reads
                    // as its own tab bar — "which cut recipe am I
                    // using" is independent of "which source am I
                    // editing", and pairing them in the same card
                    // conflated the two decisions. Now the tabs sit
                    // directly above the preview so the user reads
                    // them as the recipe the preview is currently
                    // applying.
                    modeTabBar
                    mediaStage
                    cutComposer
                    // Transcript is only relevant in Smart Pause mode
                    // — that's the mode that uses the audio transcript
                    // to find quiet gaps for cutting. In other modes
                    // (Fixed / Highlight / AI Assist) the transcript
                    // adds vertical scroll without helping the user,
                    // so we hide it entirely. When it IS shown, it
                    // starts collapsed (the CollapsibleSection default
                    // initialised to [.transcript] above) so the
                    // Smart Pause workflow isn't dominated by a wall
                    // of words the user didn't ask to see.
                    if viewModel.cutMode == .smartPause {
                        AnyView(transcriptSection)
                    }
                    plannedClipsSection
                    if !projectPlannedClipPreviewItems.isEmpty {
                        projectExportPreviewSection
                    }
                    savedClipsSection
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, shouldShowActionDock ? 156 : 28)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "editor-scroll")
            .onPreferenceChange(EditorScrollOffsetKey.self) { minY in
                // `minY` is the y-position of the spacer's
                // top edge in the scroll's coordinate space.
                // 0 = at the very top, negative = scrolled
                // down. We auto-collapse the cut-recipe
                // section when the user is within 60pt of the
                // top — gives them back the recipe's vertical
                // real estate (the recipe body is 200+pt)
                // for the video preview + scene + tabs at the
                // top of the editor. One-way effect: scrolling
                // back down doesn't auto-expand the recipe,
                // since the user can just tap the chevron
                // again to get it back. Aggressive on
                // collapse, conservative on expand.
                if minY > -60, !collapsedSections.contains(.cutRecipe) {
                    _ = withAnimation(.snappy(duration: 0.22)) {
                        collapsedSections.insert(.cutRecipe)
                    }
                }
            }
            // Auto-expand the Planned clips section the moment the user
            // adds their first clip (and auto-collapse when the list goes
            // back to empty), so the section reacts to the underlying
            // data rather than only the user's manual toggle. User can
            // still collapse it manually after.
            .onChange(of: viewModel.plannedRanges.count) { _, newCount in
                if newCount > 0, isSectionCollapsed(.plannedClips) {
                    toggleSection(.plannedClips)
                } else if newCount == 0, !isSectionCollapsed(.plannedClips) {
                    toggleSection(.plannedClips)
                }
            }
            // The transcript starts collapsed to protect the editor viewport,
            // but it must open when transcription completes or the user sees
            // only the status pill and assumes no rows were generated.
            .onChange(of: viewModel.transcriptState) { _, newState in
                guard newState == .processing || newState == .ready else { return }
                revealTranscriptIfAvailable()
            }
            .onChange(of: viewModel.cutMode) { _, _ in
                revealTranscriptIfAvailable()
            }
            .onAppear {
                revealTranscriptIfAvailable()
            }
        )
    }

    private var headerSection: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    AppBrandLockup(
                        iconSize: 40,
                        titleFont: .system(.title3, design: .rounded).weight(.black)
                    )

                    Spacer(minLength: 0)

                    projectsHeaderButton
                }

                Divider()
                    .background(AppPalette.hairline)

                HStack(alignment: .top, spacing: 12) {
                    projectTitleBlock
                        .frame(maxWidth: .infinity, alignment: .leading)

                    exportSettingsPill
                }
            }
            .premiumSurface()
            .sheet(isPresented: $isExportSettingsSheetPresented) {
                ExportSettingsSheet()
                    .environmentObject(viewModel)
                    .environmentObject(subscriptionStore)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        )
    }

    private var projectsHeaderButton: some View {
        Button {
            // Replaces the old "Projects" navigation. Same icon
            // family (`square.and.arrow.up` matches the bottom
            // Export) so the two export affordances read as a pair:
            // top = project file, bottom = video clips. Disabled
            // when there is no project to export — mirrors
            // HomeView's gating on `currentProjectID`.
            prepareReelClipExport()
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.caption.weight(.bold))
                .foregroundStyle(viewModel.currentProjectID == nil ? AppPalette.mutedText : AppPalette.primaryText)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(AppPalette.raisedSurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.currentProjectID == nil)
        .accessibilityLabel("Export project file")
        .accessibilityHint("Saves the whole project as a .reelclip file you can share or back up.")
    }

    /// Build a temp file containing the current project's `.reelclip`
    /// snapshot, then surface the system export sheet so the user
    /// can pick a destination (Files, iCloud Drive, AirDrop).
    /// Mirrors `HomeView.prepareExport` — kept separate so each
    /// view wires its own state without coupling the two screens.
    private func prepareReelClipExport() {
        do {
            let prepared = try viewModel.exportCurrentProjectToTemporaryFile()
            reelClipExportURL = prepared.url
            isReelClipExporterPresented = true
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private var projectTitleBlock: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    "Untitled project",
                    text: $viewModel.projectTitleDraft
                )
                .font(.system(.title2, design: .rounded).weight(.black))
                .foregroundStyle(AppPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .focused($isProjectTitleFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                // `.toolbar(placement: .keyboard)` adds a Done
                // button to the keyboard's accessory bar that's
                // wired to release focus. SwiftUI's `.onSubmit`
                // on a TextField doesn't always fire when the
                // keyboard's green Done button is tapped on
                // iOS 26 — this is the reliable fallback. Both
                // paths route through the focus-release → save
                // onChange, so the title commits either way.
                // Don't add `.submitLabel(.done)` here — the
                // per-field toolbar's Done is the single source
                // of truth for the keyboard's input accessory.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            isProjectTitleFocused = false
                        }
                        .fontWeight(.semibold)
                    }
                }
                .accessibilityLabel("Project title")
                .accessibilityHint("Tap to rename this project.")
                .onSubmit {
                    viewModel.updateProjectTitle(viewModel.projectTitleDraft)
                    isProjectTitleFocused = false
                }
                .onChange(of: isProjectTitleFocused) { _, isFocused in
                    // Track composing state, then save on focus loss (tap outside,
                    // dismiss keyboard, switch tabs) so the user never has to
                    // remember to hit Done. Combined into one modifier to avoid
                    // iOS 26.5 SwiftUI runtime corruption from stacked onChange
                    // observers on the same value.
                    if isFocused {
                        isProjectTitleComposing = true
                    } else if isProjectTitleComposing {
                        isProjectTitleComposing = false
                        viewModel.updateProjectTitle(viewModel.projectTitleDraft)
                    }
                }

                if !viewModel.isProcessing {
                    Text(viewModel.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        )
    }

    private var statusCapsule: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(viewModel.durationLabel)
                .font(.system(.headline, design: .rounded).monospacedDigit().weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
            let label = viewModel.expectedClipCountLabel
            Text(label == "Auto" ? "auto clips" : "\(label) clips")
                .font(.caption2.weight(.black))
                .foregroundStyle(clipLabelColor(for: label))
        }
        .frame(minWidth: 76)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppPalette.raisedSurface, in: Capsule())
        .overlay {
            Capsule().stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    /// Compact export-settings pill. Sits next to the status capsule
    /// in the project header — shows the current resolution + fps
    /// and opens the settings sheet on tap. Replaces the missing
    /// "where will my export be quality-wise" affordance that was
    /// previously hidden behind the export-preview sheet.
    private var exportSettingsPill: AnyView {
        let effective = viewModel.projectExportSettings.resolved(for: subscriptionStore.tier)
        let label = "\(effective.resolution.displayName) · \(effective.frameRate.displayName)"

        return AnyView(
            Button {
                isExportSettingsSheetPresented = true
                PolishKit.Haptics.tap(.light).play()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2.weight(.black))
                    Text(label)
                        .font(.caption2.weight(.black))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .black))
                }
                .foregroundStyle(AppPalette.primaryText)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(AppPalette.raisedSurface, in: Capsule())
                .overlay {
                    Capsule().stroke(AppPalette.hairline, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Export settings: \(label). Tap to change.")
        )
    }

    /// Render the clip-count line in red when it's a truncated "X of Y" so
    /// the discrepancy reads at a glance.
    private func clipLabelColor(for label: String) -> Color {
        if label.contains(" of ") { return AppPalette.danger }
        return AppPalette.secondaryText
    }

    private var mediaStage: some View {
        return VStack(alignment: .leading, spacing: 14) {
            // Cut mode toggle moved to its own `modeTabBar` row
            // directly above this card — "which cut recipe" and
            // "which source" are independent decisions and pairing
            // them in the same card conflated the two.

            HStack {
                // Scene selector stays beside the stage controls so the
                // user can see which scene the reset applies to.
                sceneSwitcherPill

                Spacer()

                // Reset is deliberately the only inline action here. Source
                // replacement remains available from the scene menu, while
                // this control always means "start this scene over".
                // When the scene has no content (just-reset or a fresh
                // empty scene), the same slot flips to an Import CTA so
                // the user has a single affordance to bring media back
                // — no need to dig into the scene menu.
                let sceneIsEmpty = !viewModel.hasActiveSceneContent
                Button {
                    guard !viewModel.isImportingMedia else { return }
                    if sceneIsEmpty {
                        isSceneSourceFileImporterPresented = true
                    } else {
                        isSceneResetConfirmationPresented = true
                    }
                    PolishKit.Haptics.tap(.medium).play()
                } label: {
                    Label(
                        sceneIsEmpty ? "Import" : "Reset",
                        systemImage: sceneIsEmpty ? "square.and.arrow.down" : "arrow.counterclockwise"
                    )
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
                .disabled(viewModel.isImportingMedia)
                .accessibilityLabel(sceneIsEmpty ? "Import a video into this scene" : "Reset active scene")
                .accessibilityHint("Clears this scene while keeping the project and scene name")
            }

            if let _ = viewModel.sourceURL {
                videoPreview
                    // No transition — the default SwiftUI `.scale`
                    // transition makes the canvas zoom out + back in
                    // when the project loads and the source URL is
                    // first resolved.
                    .transition(.identity)
            } else {
                emptyVideoState
                    .transition(.identity)
            }

            if let duration = viewModel.durationSeconds, duration > 0 {
                sourceTimelineScrubber
                    .transition(.identity)
            }
        }
        .premiumSurface()
    }

    /// Standalone tab bar for the four cut recipes (Splice / Cut /
    /// Silence / AI). Lives directly above the preview so the user
    /// reads the tabs as "which recipe is the preview currently
    /// applying" — recipe selection and source selection are
    /// independent, so they no longer share a card. Tabs are
    /// separated by thin vertical dividers (not chip borders) so
    /// the row reads as a connected segmented control rather than
    /// four loose buttons. Selected tab gets the accent fill.
    private var modeTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(CutMode.allCases.enumerated()), id: \.element.id) { index, mode in
                if index > 0 {
                    Rectangle()
                        .fill(AppPalette.hairline)
                        .frame(width: 1)
                        .frame(maxHeight: 24)
                }
                Button {
                    let previous = viewModel.cutMode
                    viewModel.cutMode = mode
                    // When entering Highlight, seed its duration from
                    // the persistent "Seconds per clip" default so both
                    // controls start in sync.
                    if mode == .highlight, previous != .highlight {
                        viewModel.enterHighlightMode()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.symbolName)
                            .font(.caption.weight(.bold))
                        Text(mode.shortTitle)
                            .font(.caption.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(viewModel.cutMode == mode ? AppPalette.background : AppPalette.primaryText)
                    .background(
                        viewModel.cutMode == mode ? AppPalette.accent : Color.clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cut mode \(mode.shortTitle)")
            }
        }
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
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
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture {
                    togglePreviewPlayback()
                }
                .accessibilityLabel(isPreviewPlaying ? "Pause video preview" : "Play video preview")
        }
        // Adapt the preview's frame to the source video's display
        // aspect ratio OR to a fixed user-picked size level. The
        // discrete-level path (`.small` / `.medium` / `.large`)
        // is the new affordance — replaces a free-form drag-resize
        // handle that was buggy. 9:16 vertical sources still
        // default to filling the width; the user can tap the
        // bottom-left button to collapse the preview to a
        // 180/280/380pt window. `videoGravity = .resizeAspect`
        // inside `PreviewVideoView` keeps the video letterboxed
        // inside whatever container the user picks.
        .frame(maxWidth: .infinity)
        .modifier(VideoPreviewSizingModifier(
            sizeLevel: previewSizeLevel,
            sourceAspectRatio: viewModel.sourceAspectRatio
        ))
        .overlay(alignment: .bottomTrailing) {
            previewPlaybackButton
                .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            previewSizeLevelButton
                .padding(12)
        }
        .overlay(alignment: .topLeading) {
            if viewModel.isGeneratingProxy || viewModel.isUsingProxy {
                previewProxyStatus
                    .padding(12)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var previewProxyStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: viewModel.isGeneratingProxy
                  ? "arrow.triangle.2.circlepath"
                  : "checkmark.circle.fill")
                .font(.caption.weight(.black))
            Text(viewModel.isGeneratingProxy
                 ? "Proxy \(Int((viewModel.proxyGenerationProgress * 100).rounded()))%"
                 : "Proxy preview")
                .font(.caption2.weight(.black))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.black.opacity(0.68), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.isGeneratingProxy
                            ? "Preparing proxy preview, \(Int((viewModel.proxyGenerationProgress * 100).rounded())) percent"
                            : "Using proxy preview")
    }

    /// Bottom-left resize button. Cycles the video preview
    /// through `auto → small → medium → large → auto` so the
    /// user can collapse a tall 9:16 source to a comfortable
    /// fixed window without free-form dragging. The icon
    /// rotates (clockwise) with each level so the affordance
    /// reads "more / less preview space" without an explicit
    /// label. The level itself is shown as a small caption
    /// below the icon so the user knows where they are in the
    /// cycle.
    private var previewSizeLevelButton: some View {
        Button {
            PolishKit.Haptics.tap(.light).play()
            withAnimation(.snappy(duration: 0.18)) {
                previewSizeLevel = previewSizeLevel.next
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: previewSizeLevel.iconName)
                    .font(.caption.weight(.black))
                Text(previewSizeLevel.shortLabel)
                    .font(.system(size: 10, weight: .black, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(AppPalette.accent.opacity(0.4), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resize video preview")
        .accessibilityValue(previewSizeLevel.accessibilityValue)
        .accessibilityHint("Cycles the preview through auto, small, medium, and large sizes.")
        .accessibilityAddTraits(.isButton)
    }

    private var previewPlaybackButton: some View {
        Button {
            togglePreviewPlayback()
        } label: {
            // Show a small "loop" badge on the play button when
            // the preview is looping within a selected clip, so
            // the user knows playback won't continue past the
            // clip's end. The badge sits at the top-right of the
            // play button — visible at a glance, doesn't replace
            // the play/pause icon (which is the primary affordance).
            ZStack(alignment: .topTrailing) {
                Image(systemName: isPreviewPlaying ? "pause.fill" : "play.fill")
                    .font(.headline.weight(.black))
                    .foregroundStyle(AppPalette.background)
                    .frame(width: 44, height: 44)
                    .background(AppPalette.accent, in: Circle())
                    .shadow(color: Color.black.opacity(0.35), radius: 8, y: 4)

                if clipLoopActiveRangeIndex != nil {
                    Image(systemName: "repeat")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(AppPalette.background)
                        .frame(width: 18, height: 18)
                        .background(AppPalette.accent.opacity(0.85), in: Circle())
                        .overlay {
                            Circle().stroke(AppPalette.background, lineWidth: 1.5)
                        }
                        .offset(x: 4, y: -4)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isPreviewPlaying
                ? (clipLoopActiveRangeIndex != nil
                    ? "Pause preview (looping within selected clip)"
                    : "Pause preview")
                : (clipLoopActiveRangeIndex != nil
                    ? "Play preview (looping within selected clip)"
                    : "Play preview")
        )
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Preview timeline", systemImage: "rectangle.stack")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)

                Spacer()

                zoomSlider
            }

            if viewModel.sourceThumbnails.isEmpty {
                thumbnailSkeleton
                    // No transition — the default SwiftUI `.scale`
                    // transition zooms the page in/out when the
                    // skeleton is replaced by the real timeline.
                    .transition(.identity)
            } else {
                // Single continuous film strip + waveform surface with all
                // marker overlays (planned ranges, draft highlight, drag
                // handles) sharing one zoomed horizontal timeline.
                VideoTimelineView(
                    thumbnails: viewModel.sourceThumbnails,
                    plannedRanges: liveTimelineRanges,
                    waveformSamples: viewModel.waveformSamples,
                    duration: viewModel.durationSeconds ?? 0,
                    scrubPosition: viewModel.scrubPositionSeconds,
                    draftHighlight: viewModel.cutMode == .highlight ? viewModel.highlightDraft : nil,
                    frameDuration: viewModel.frameDurationSeconds,
                    thumbnailScale: viewModel.timelineZoom.thumbnailScale,
                    selectedRangeIndex: effectiveSelectedRangeIndex,
                    onTap: { seconds in
                        viewModel.updateScrubPosition(seconds)
                        seekPreview(to: seconds, pause: true)
                        if let index = liveTimelineRanges.firstIndex(where: {
                            seconds >= $0.startSeconds && seconds <= $0.endSeconds
                        }), let rawIndex = plannedRangeIndex(forTimelineIndex: index) {
                            userSelectedRangeIndex = rawIndex
                        } else {
                            userSelectedRangeIndex = nil
                        }
                    },
                    onSelectRange: { index in
                        userSelectedRangeIndex = plannedRangeIndex(forTimelineIndex: index)
                        PolishKit.Haptics.selection.play()
                    },
                    onUpdateRange: { index, newRange in
                        guard let rawIndex = plannedRangeIndex(forTimelineIndex: index),
                              viewModel.plannedRanges.indices.contains(rawIndex) else { return }
                        let current = viewModel.plannedRanges[rawIndex]
                        updatePlannedRangeAndPreview(at: rawIndex, from: current, to: newRange)
                    },
                    onToggleRangeLock: { index in
                        guard let rawIndex = plannedRangeIndex(forTimelineIndex: index) else { return }
                        viewModel.togglePlannedRangeLock(at: rawIndex)
                        PolishKit.Haptics.success.play()
                    },
                    onScrub: { seconds in
                        // Body-drag scrub on a selected planned
                        // range. Updates the playhead + seeks
                        // the preview. Clamping to the range
                        // bounds is already done by the gesture,
                        // so we just forward through.
                        viewModel.updateScrubPosition(seconds)
                        seekPreview(to: seconds, pause: true)
                    },
                    onMoveDraft: { newStart in
                        viewModel.moveHighlightDraft(toStart: newStart)
                        let scrubTarget = viewModel.highlightDraft?.startSeconds ?? newStart
                        viewModel.updateScrubPosition(scrubTarget)
                        seekPreview(to: scrubTarget, pause: true)
                    },
                    onResizeDraftStart: { newStart in
                        viewModel.setHighlightStart(newStart)
                        let scrubTarget = viewModel.highlightDraft?.startSeconds ?? newStart
                        viewModel.updateScrubPosition(scrubTarget)
                        seekPreview(to: scrubTarget, pause: true)
                    },
                    onResizeDraftEnd: { newEnd in
                        viewModel.setHighlightEnd(newEnd)
                        let scrubTarget = viewModel.highlightDraft?.endSeconds ?? newEnd
                        viewModel.updateScrubPosition(scrubTarget)
                        seekPreview(to: scrubTarget, pause: true)
                    },
                    onEdgeDragPreview: { seconds in
                        // User is dragging the start or end handle of
                        // a planned range (or the draft highlight).
                        // Mirror the body-scrub path: seek the big
                        // video preview above to the handle's new
                        // position so the user sees the exact frame
                        // they're about to commit in the larger
                        // view, instead of the old small
                        // frame-thumbnail tooltip pinned to the
                        // timeline (which we no longer render).
                        // This used to drive a `tooltipClearance`
                        // bubble that consumed 58pt of vertical
                        // real-estate above the strip; the
                        // bubble's gone, the bigger preview is
                        // the new feedback surface.
                        viewModel.updateScrubPosition(seconds)
                        seekPreview(to: seconds, pause: true)
                    }
                )
                .animation(.snappy(duration: 0.22), value: liveTimelineRanges)
                .animation(.snappy(duration: 0.22), value: effectiveSelectedRangeIndex)
                .animation(.snappy(duration: 0.22), value: viewModel.highlightDraft)
                // No transition — same default-scale glitch as
                // `thumbnailSkeleton` above. Skeleton ↔ real-timeline is
                // the only conditional here, and we want the swap to be
                // instantaneous.
                .transition(.identity)
            }

            playbackScrubber
        }
        .padding(12)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    /// 4-stop zoom slider: Fit, 2x, 4x, 8x. Lives in the top-right of the
    /// "Preview timeline" panel header. Driven by
    /// `TimelineZoom.allCases` so adding a new zoom level only needs
    /// a new case on the enum.
    private var zoomSlider: some View {
        let lastIdx = max(0, TimelineZoom.allCases.count - 1)
        return HStack(spacing: 6) {
            Image(systemName: "minus.magnifyingglass")
                .font(.caption2)
                .foregroundStyle(AppPalette.secondaryText)
            Slider(
                value: Binding(
                    get: { Double(TimelineZoom.allCases.firstIndex(of: viewModel.timelineZoom) ?? 0) },
                    set: { newValue in
                        let idx = max(0, min(lastIdx, Int(newValue.rounded())))
                        viewModel.timelineZoom = TimelineZoom.allCases[idx]
                    }
                ),
                in: 0...Double(lastIdx),
                step: 1
            )
            .frame(width: 110)
            Text(viewModel.timelineZoom.rawValue)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
                .frame(width: 24, alignment: .leading)
        }
        .frame(width: 188)
    }

    /// Single canonical playback scrubber. Replaces the previous second
    /// scrubber that lived on the waveform (which was removed to avoid
    /// two surfaces fighting for the same playhead value).
    private var playbackScrubber: some View {
        HStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { viewModel.scrubPositionSeconds },
                    set: { newValue in
                        viewModel.updateScrubPosition(newValue)
                        seekPreview(to: newValue, pause: true)
                    }
                ),
                in: 0...max(1, viewModel.durationSeconds ?? 1)
            )

            Text("\(viewModel.scrubPositionLabel) / \(viewModel.durationLabel)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(AppPalette.secondaryText)
                .frame(width: 90, alignment: .trailing)
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
            // "Default clip settings" used to render a read-only
            // summary card here (4 chips mirroring what lives in
            // Settings). Removed in v2.0: the duplicate confused
            // users who expected chips to be editable. The
            // canonical place for defaults is the Settings tab —
            // the `Reset Recipe` button in the Cut recipe section
            // still applies whatever's saved there.

            collapsibleSectionTitle(
                "Cut recipe",
                detail: modeDescription,
                section: .cutRecipe,
                systemImage: viewModel.cutMode.symbolName
            )

            if !isSectionCollapsed(.cutRecipe) {
                // Collapsible body: the recipe's input controls +
                // the safety strip. Add + Reset live OUTSIDE this
                // `if` so they remain reachable when the section
                // is collapsed — collapsing should hide the
                // configurable knobs, not the commit action.
                VStack(spacing: 14) {
                    // Mode selector moved out of the cut-recipe
                    // card into its own `modeTabBar` row above the
                    // preview (see `editorWorkspace`). Scene
                    // selector moved out of the cut-recipe card
                    // into the mediaStage row beside the scene selector
                    // (see `mediaStage`).
                    if viewModel.cutMode == .fixed {
                        fixedModeQueryControl
                    } else if viewModel.cutMode == .smartPause {
                        smartPauseRecipeControl
                    } else if viewModel.cutMode != .highlight {
                        // Smart Pause uses the length directly; AI Assist
                        // uses it as a seed for the prompt planner. Highlight
                        // mode is visual-only — duration comes from the
                        // timeline drag, so the editable "Seconds per clip"
                        // field is hidden in Highlight.
                        secondsControl
                    }
                    if viewModel.cutMode == .smartPause {
                        // Smart-Enhance with Apple Intelligence. Only
                        // meaningful when the user has already planned
                        // silence-mode clips — taps into the existing
                        // .smartPause ranges, runs them through
                        // FoundationModels to drop ranges that sound
                        // like false starts or awkward pauses, and
                        // replaces the planned ranges in place. Free
                        // users see the button but it's gated behind
                        // the monthly AI plan quota (3/mo); Creator
                        // users get unlimited.
                        silenceEnhanceButton
                    }
                    if viewModel.cutMode == .highlight {
                        // Highlight mode is fully manual — no prompt, no AI.
                        // User taps the timeline to set start, drags the
                        // band's edge handles to set end, taps "Add to plan".
                        // The "Clip length" field below is read-only — it
                        // shows the LIVE length of the current draft.
                        highlightDurationDisplay
                    } else if viewModel.cutMode == .aiAssist {
                        promptControl
                    }
                    // Duration + Expected safety badges moved to
                    // sit immediately above the Add + Reset row
                    // so the user reads the recipe inputs → the
                    // predicted outcome → the action that
                    // commits it, in that order. Previously these
                    // were at the top of the card (between the
                    // title and the inputs), which separated
                    // "what will happen" from "make it happen"
                    // by the entire recipe-input section.
                    safetyStrip
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }

            // Add + Reset row — always visible regardless of
            // collapsed state. These are the commit actions for
            // the recipe, and they need to stay reachable when
            // the user has the card collapsed (i.e. they accept
            // the current inputs and just want to fire Add or
            // Reset without expanding the card to see the
            // controls).
            replaceTargetBanner
            addPlanAndResetRow
        }
        .premiumSurface()
    }

    /// True when the user can manage multiple scenes — add,
    /// switch, duplicate, delete, or multi-scene export. Locked to
    /// Creator and Studio; Free users get exactly one auto-managed
    /// scene and can only export that scene.
    private var canManageScenes: Bool {
        subscriptionStore.hasAccess(to: .creator)
    }

    /// Compact scene dropdown that lives in the mediaStage row
    /// beside the Reset action. The "Project / Scene 1 / Creator"
    /// pill — tap it to open a menu with the full scene list,
    /// rename, duplicate, change-source, and delete actions. The
    /// previously-attached direct trash + add buttons were
    /// retired: every option they exposed is reachable from the
    /// menu, and the inline icons crowded the row once the
    /// scene pill moved next to the stage reset action.
    private var sceneSwitcherPill: some View {
        Menu {
            if viewModel.scenes.isEmpty {
                Button(viewModel.activeSceneName) {}
                    .disabled(true)
            } else if canManageScenes {
                // Multi-scene users see the full scene list.
                ForEach(viewModel.scenes) { scene in
                    Button {
                        viewModel.switchToScene(scene.id)
                        userSelectedRangeIndex = nil
                        PolishKit.Haptics.selection.play()
                    } label: {
                        Label(
                            scene.name,
                            systemImage: scene.id == viewModel.activeSceneId ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            } else {
                // Free users see only the active scene — no
                // switcher, no way to hop to legacy scenes
                // (Free projects are guaranteed single-scene
                // on the create path; this protects legacy
                // Free users with multi-scene data from
                // accidentally exporting the wrong scene).
                Button(viewModel.activeSceneName) {}
                    .disabled(true)
            }

            Divider()

            Button {
                sceneNameDraft = viewModel.activeSceneName
                isSceneRenamePresented = true
                PolishKit.Haptics.selection.play()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(viewModel.scenes.isEmpty)

            // Add scene — visible to every tier. Creator+
            // users get the actual action; Free users see
            // the option in the menu but tapping it routes to
            // the paywall. Hiding the option entirely on Free
            // left the multi-scene feature undiscoverable;
            // showing it as a paywall-routed option turns the
            // menu into a discovery surface for the upgrade.
            Button {
                if canManageScenes {
                    viewModel.addBlankScene()
                    userSelectedRangeIndex = nil
                    PolishKit.Haptics.success.play()
                } else {
                    showPaywall = true
                    PolishKit.Haptics.selection.play()
                }
            } label: {
                Label("Add scene", systemImage: "plus.square.on.square")
            }

            // Duplicate scene — same paywall-routed pattern.
            // Only shown when there's an active scene to
            // duplicate (i.e. the project has at least one
            // scene and the active id is valid).
            if let activeId = viewModel.activeSceneId,
               viewModel.scenes.contains(where: { $0.id == activeId }) {
                Button {
                    if canManageScenes {
                        viewModel.duplicateScene(id: activeId)
                        userSelectedRangeIndex = nil
                        PolishKit.Haptics.success.play()
                    } else {
                        showPaywall = true
                        PolishKit.Haptics.selection.play()
                    }
                } label: {
                    Label("Duplicate scene", systemImage: "doc.on.doc")
                }
            }

            // Change source — visible to every tier. Creator+
            // users get the per-scene source sheet; Free users
            // get routed to the paywall. Previously hidden on
            // Free, again losing the discoverability.
            if viewModel.activeSceneId != nil,
               !viewModel.scenes.isEmpty {
                Divider()
                Button {
                    if canManageScenes {
                        isSceneSourceSheetPresented = true
                        PolishKit.Haptics.selection.play()
                    } else {
                        showPaywall = true
                        PolishKit.Haptics.selection.play()
                    }
                } label: {
                    Label("Change source…", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            // Delete scene — destructive. Hidden when there's
            // only one scene (so the user can't delete their
            // last scene and end up with an empty project —
            // rename instead). For Free users with their
            // single auto-managed scene this never renders
            // because the count check fails. Tapping Delete on
            // a Free user who somehow has >1 scene (legacy
            // imported project) also routes to the paywall.
            if viewModel.scenes.count > 1,
               let activeId = viewModel.activeSceneId {
                Divider()
                Button(role: .destructive) {
                    if canManageScenes {
                        if let scene = viewModel.scenes.first(where: { $0.id == activeId }) {
                            scenePendingDelete = scene
                            PolishKit.Haptics.warning.play()
                        }
                    } else {
                        showPaywall = true
                        PolishKit.Haptics.warning.play()
                    }
                } label: {
                    Label("Delete scene", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)

                // Scene name only — no "Project" / "Active scene"
                // subtitle. The scene pill already lives next to
                // scene selector in the mediaStage row, so the
                // scene is obviously the "active" one in this
                // editing context; the subtitle was visual
                // redundancy. The chevron (Creator+) / Creator
                // chip (Free) on the right still surfaces
                // the scene-management affordance.
                Text(viewModel.activeSceneName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if canManageScenes {
                    // Creator+ users get the chevron — the menu
                    // opens the full scene-management list.
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.black))
                        .foregroundStyle(AppPalette.secondaryText)
                } else {
                    // Free users see their current tier as a
                    // chip on the scene pill — previously the
                    // chip read "Creator" which was misleading
                    // (Free users are NOT on Creator). The
                    // pill now reflects reality: the user is
                    // on the Free plan, and the menu still
                    // opens but Creator-only options route to
                    // the paywall. The Creator label belongs
                    // on the paywall itself, not on the
                    // user's current-tier badge.
                    Text(subscriptionStore.tier.displayName)
                        .font(.caption2.weight(.black))
                        .foregroundStyle(AppPalette.background)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(AppPalette.mutedText, in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        // Confirmation before the destructive "Delete scene" action.
        // Driven by `scenePendingDelete` (a non-optional scene object
        // when the dialog should appear) so we can show the scene name
        // in the message and pass the id to the view model on confirm.
        .confirmationDialog(
            "Delete \(scenePendingDelete?.name ?? "scene")?",
            isPresented: Binding(
                get: { scenePendingDelete != nil },
                set: { presented in
                    if !presented { scenePendingDelete = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let scene = scenePendingDelete else { return }
                viewModel.deleteScene(id: scene.id)
                userSelectedRangeIndex = nil
                PolishKit.Haptics.warning.play()
            }
            Button("Cancel", role: .cancel) {
                scenePendingDelete = nil
            }
        } message: {
            if let scene = scenePendingDelete {
                Text("This deletes \(scene.name) and any planned clips in it. Exported clips stay.")
            }
        }
        // "Change source for this scene" sheet — gives the user a
        // focused UI to pick a new source for the active scene only.
        // The two pickers (Files / Photos) live inside the sheet so
        // they don't conflict with the main source stage's pickers,
        // which are wired to the "new project" flow.
        .sheet(isPresented: $isSceneSourceSheetPresented) {
            sceneSourcePickerSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        // Pre-export chooser. Multi-scene options ("Pick a scene…"
        // + "All scenes") are gated to Creator+ — Free users get
        // "Current recipe" only. The chooser itself still appears
        // when there are multiple scenes (so legacy Free users
        // with multi-scene data don't see a UI change for the
        // current-recipe export), but the multi-scene rows are
        // hidden and a single "Unlock multi-scene export" button
        // routes them to the paywall.
        .confirmationDialog(
            "Export which scenes?",
            isPresented: $isExportTargetChooserPresented,
            titleVisibility: .visible
        ) {
            Button("Current recipe (\(viewModel.activeSceneName))") {
                viewModel.prepareExport(target: .activeRecipe)
            }
            if canManageScenes {
                Button("Pick a scene…") {
                    isExportScenePickerPresented = true
                }
                Button("All scenes") {
                    viewModel.prepareExport(target: .allScenes)
                }
            } else {
                Button("Unlock multi-scene export") {
                    showPaywall = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if canManageScenes {
                Text("Each scene renders against its own source. Scenes with no planned clips are skipped. Scenes whose source file is missing are skipped (and listed in the preview).")
            } else {
                Text("Free plan exports the active scene only. Upgrade to Creator to export specific scenes or combine every scene in this project into one batch.")
            }
        }
        .confirmationDialog(
            "Replace source and planned clips?",
            isPresented: $isSceneSourcePlanDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Keep planned clips") {
                performPendingSceneSourceReplacement(planAction: .keep)
            }
            Button("Clamp clips to new video") {
                performPendingSceneSourceReplacement(planAction: .clamp)
            }
            Button("Clear planned clips", role: .destructive) {
                performPendingSceneSourceReplacement(planAction: .clear)
            }
            Button("Cancel", role: .cancel) {
                clearPendingSceneSourceReplacement()
            }
        } message: {
            Text("This scene already has planned clips. Keep them as-is, clamp any out-of-range clips to the new video length, or clear the scene plan.")
        }
        // Scene picker sub-sheet for the "Pick a scene…" branch of
        // the export chooser. Lists all scenes with a planned-clips
        // count; tapping one kicks off the render for that scene.
        .sheet(isPresented: $isExportScenePickerPresented) {
            exportScenePickerSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // File importer for the scene-source flow. Triggered by the
        // "Pick from Files" button in the sheet above.
        .fileImporter(
            isPresented: $isSceneSourceFileImporterPresented,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    requestSceneSourceReplacement(fileURL: url)
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    /// Sheet that lets the user pick a new source for the active
    /// scene. Two large buttons: one for the file importer (Files)
    /// and one for the system Photos library. The PhotosPicker is
    /// embedded directly so the user can tap once to open the
    /// library; on selection, `onChange` routes through
    /// `replaceActiveSceneSource(from:)`.
    private var sceneSourcePickerSheet: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Replace source for this scene")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                Text("Other scenes keep their source. If this scene already has planned clips, choose whether to keep, clamp, or clear them after picking the new video.")
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                guard !viewModel.isImportingMedia else { return }
                isSceneSourceSheetPresented = false
                // Defer the file importer to the next runloop tick
                // so the sheet has a chance to dismiss first;
                // presenting both at the same time breaks SwiftUI.
                DispatchQueue.main.async {
                    isSceneSourceFileImporterPresented = true
                }
            } label: {
                Label("Pick from Files", systemImage: "externaldrive")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppPalette.hairline, lineWidth: 1)
                    }
                    .foregroundStyle(AppPalette.primaryText)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isImportingMedia)

            PhotosPicker(
                selection: $sceneSourcePickerItem,
                matching: .videos,
                preferredItemEncoding: .current,
                photoLibrary: .shared()
            ) {
                Label("Pick from Photos", systemImage: "photo.on.rectangle")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AppPalette.hairline, lineWidth: 1)
                    }
                    .foregroundStyle(AppPalette.primaryText)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isImportingMedia)
            .onChange(of: sceneSourcePickerItem) { _, newItem in
                guard newItem != nil else { return }
                guard !viewModel.isImportingMedia else {
                    sceneSourcePickerItem = nil
                    return
                }
                requestSceneSourceReplacement(photoItem: newItem!)
                isSceneSourceSheetPresented = false
                sceneSourcePickerItem = nil
            }

            Button("Cancel", role: .cancel) {
                isSceneSourceSheetPresented = false
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.mutedText)
        }
        .padding(24)
        .background(AppPalette.background)
    }

    private var resetRecipeButton: some View {
        // When no video is loaded, the recipe has nothing to reset
        // — instead the button transforms into an "Import" CTA
        // that opens the file picker. Same slot, same touch target,
        // same row layout, but the affordance matches what the
        // user actually wants to do. The Accent fill on Import
        // (vs. muted control-surface on Reset) reflects the
        // priority: getting a source loaded is the gate to every
        // other action in the editor.
        let hasSource = viewModel.sourceURL != nil
        let title = hasSource ? "Reset" : "Import"
        let symbol = hasSource ? "arrow.counterclockwise" : "square.and.arrow.down"
        return Button {
            if hasSource {
                viewModel.resetCurrentRecipeFields()
                PolishKit.Haptics.selection.play()
            } else {
                guard !viewModel.isImportingMedia else { return }
                PolishKit.Haptics.tap(.medium).play()
                isSceneSourceFileImporterPresented = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(.caption.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(hasSource ? AppPalette.secondaryText : AppPalette.background)
            .background(
                hasSource
                    ? AnyShapeStyle(AppPalette.controlSurface)
                    : AnyShapeStyle(AppPalette.accent),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasSource ? "Reset cut recipe to defaults" : "Import a video to start editing")
    }

    private var addPlanAndResetRow: some View {
        // Every mode gets a paired Add + Reset row at the bottom
        // of the cut-recipe card. The two buttons share the row
        // 50/50 via .frame(maxWidth: .infinity). The Add button
        // is the primary action (accent fill); Reset is the
        // secondary (control-surface fill) — same visual language
        // as Highlight had pre-v2.0, now applied across the
        // board so Cut / SmartPause / AI users get the same
        // affordance the Splice workflow had.
        HStack(spacing: 10) {
            recipeAddButton
            resetRecipeButton
        }
    }

    /// Inline banner that appears in the cut-recipe card while a
    /// row is the active replace target. Sits between the recipe
    /// inputs and the Add/Reset row so the user reads:
    /// "recipe inputs" → "I'm about to swap a row" → "make it
    /// happen". Tells the user exactly which row is being
    /// targeted (start/end + the visible counter) so they can
    /// confirm before tapping Swap.
    /// Cancel clears `replacingPlannedRangeIndex` and the recipe
    /// falls back to plain Add-on-tap behavior.
    /// Auto-collapses to `EmptyView` when nothing is targeted so
    /// the card stays clean for the normal Add path.
    @ViewBuilder
    private var replaceTargetBanner: some View {
        if let targetIdx = viewModel.replacingPlannedRangeIndex,
           viewModel.plannedRanges.indices.contains(targetIdx) {
            let target = viewModel.plannedRanges[targetIdx]
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Swapping clip \(targetIdx + 1)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text(
                        "\(ClipRangeFormatter.formatTime(target.startSeconds)) → \(ClipRangeFormatter.formatTime(target.endSeconds)) — tap Swap to replace, Cancel to keep both."
                    )
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") {
                    PolishKit.Haptics.tap(.light).play()
                    viewModel.cancelReplace()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppPalette.accent)
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel replace")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppPalette.accent.opacity(0.35), lineWidth: 1)
            }
        }
    }

    /// Primary "Add" affordance for the active recipe. Unified
    /// across all four modes so the label, icon, and behavior
    /// match. For Cut / SmartPause / AI: runs the recipe, adds
    /// the result to planned, then clears the recipe's draft
    /// fields. For Splice (Highlight): adds the current draft
    /// to planned and auto-advances the start pointer (existing
    /// `addHighlightDraftToPlan` behavior). The button shows a
    /// spinner when a recipe run is in flight and is disabled
    /// when the recipe can't run (no source, etc.).
    private var recipeAddButton: some View {
        let isProcessing = viewModel.isProcessing
        let canAdd = viewModel.canPrepare && !isProcessing
        // When a row is the current "replace with…" target, the
        // Add button swaps that row in place instead of appending —
        // the label and icon switch to make the affordance obvious.
        // The actual behavior is owned by
        // `viewModel.addRecipeToPlannedAndReset()` via the
        // `replacingPlannedRangeIndex` branch — the view just
        // surfaces the state.
        let isReplaceMode = viewModel.replacingPlannedRangeIndex != nil
        let title: String
        let symbol: String
        if viewModel.cutMode == .highlight {
            title = isReplaceMode ? "Swap clip" : "Add"
            symbol = isReplaceMode ? "arrow.triangle.2.circlepath" : "plus.circle.fill"
        } else if viewModel.cutMode == .smartPause {
            title = isProcessing
                ? (isReplaceMode ? "Swapping…" : "Analyzing…")
                : (isReplaceMode ? "Swap clip" : "Analyze & add")
            symbol = isReplaceMode ? "arrow.triangle.2.circlepath" : "waveform"
        } else {
            title = isProcessing
                ? (isReplaceMode ? "Swapping…" : "Adding…")
                : (isReplaceMode ? "Swap clip" : "Add")
            symbol = isReplaceMode ? "arrow.triangle.2.circlepath" : "plus.circle.fill"
        }
        return Button {
            let modeAtTap = viewModel.cutMode
            isSegmentFieldFocused = false
            PolishKit.Haptics.tap(.medium).play()
            guardActionAndShowPaywallIfNeeded(for: modeAtTap) {
                viewModel.addRecipeToPlannedAndReset(for: modeAtTap)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(.caption.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(AppPalette.background)
            .background(canAdd ? AppPalette.accent : AppPalette.disabledSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
        .accessibilityLabel(
            isReplaceMode
                ? "Swap clip with recipe result"
                : (viewModel.cutMode == .smartPause
                    ? "Analyze the selected range and add audible clips to the plan"
                    : "Add recipe result to planned clips")
        )
    }

    /// Silence mode is an analysis recipe, not a preset clip generator. Make
    /// the trigger and its scope explicit so the user knows what Add does.
    @ViewBuilder
    private var smartPauseRecipeControl: some View {
        // Smart Pause mode auto-determines clip duration from the
        // detected silent gaps — there's no meaningful user input
        // for "seconds per clip" here, so the RecipeDurationSelector
        // that previously sat at the bottom of this card was
        // confusing. Removed in v2.0: SmartCutAnalyzer's
        // `minClipDuration` (1s) and `maxClipDuration` (8s) are the
        // real bounds and they're tuned defaults. The card now shows
        // the mode's readiness + the analysis scope, which are the
        // only user-facing knobs that matter.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 22)
                Text("Smart Pause")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                Spacer(minLength: 8)
                Text(smartPauseReadinessLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(smartPauseReadinessLabel == "Ready" ? AppPalette.accent : AppPalette.mutedText)
            }

            Text(viewModel.smartPauseRecipeDetail)
                .font(.caption)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                Text(viewModel.analysisScopeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppPalette.accent.opacity(0.28), lineWidth: 1)
        }
    }

    private var smartPauseReadinessLabel: String {
        if viewModel.sourceURL == nil {
            return "Needs video"
        }
        if viewModel.durationSeconds == nil {
            return "Loading"
        }
        return "Ready"
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
            // The .truncated case (will produce X clips you asked for Y)
            // used to render a red warning banner here. Removed — the
            // user can see the actual clip count in the safety-strip
            // metric tile, and the truncated warning was more alarming
            // than informative when the source just rounds down.
            case .truncated:
                EmptyView()
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
        RecipeDurationSelector(
            title: secondsFieldTitle,
            systemImage: "timer",
            value: Binding(
                // Per-mode default as the fallback so each
                // recipe's stored value shows through when the
                // per-project text is empty.
                get: { viewModel.parsedSegmentLength ?? Double(viewModel.defaultSegmentLengthForMode(viewModel.cutMode)) },
                set: { viewModel.setSegmentDuration($0) }
            ),
            range: selectableClipDurationRange,
            detail: segmentDurationDetail
        )
    }

    /// Highlight-mode clip length control. Updates the draft range as the
    /// user picks presets or moves the slider, so the timeline previews the
    /// selected duration immediately.
    private var highlightDurationDisplay: some View {
        RecipeDurationSelector(
            title: "Clip length",
            systemImage: "ruler",
            value: Binding(
                get: { viewModel.highlightDraft?.duration ?? viewModel.highlightDraftDuration },
                set: { viewModel.setHighlightDuration($0) }
            ),
            range: selectableClipDurationRange,
            detail: highlightDurationDetail
        )
    }

    private var selectableClipDurationRange: ClosedRange<Double> {
        let sourceLimitedMaximum: Double
        if let duration = viewModel.durationSeconds, duration.isFinite, duration > 0 {
            sourceLimitedMaximum = min(max(duration, 1), 120)
        } else {
            sourceLimitedMaximum = 120
        }
        return 1...max(1, sourceLimitedMaximum)
    }

    private var segmentDurationDetail: String? {
        guard let duration = viewModel.durationSeconds,
              duration.isFinite,
              duration > 0,
              let clipLength = viewModel.parsedSegmentLength,
              clipLength.isFinite,
              clipLength > 0
        else {
            return nil
        }

        let estimatedCount = max(Int(ceil(duration / clipLength)), 1)
        return "About \(estimatedCount) clip\(estimatedCount == 1 ? "" : "s") across \(viewModel.durationLabel)"
    }

    private var fixedDurationDetail: String? {
        guard let query = viewModel.effectiveFixedQuery,
              query.isValid,
              let duration = query.durationSeconds,
              duration.isFinite,
              duration > 0
        else {
            return nil
        }

        let count = query.count ?? viewModel.fixedModeButtonCount
        let durationText = viewModel.fixedModeRandomDuration
            ? "random \(RecipeDurationFormatter.format(Double(viewModel.fixedModeRandomDurationMinimum)))-\(RecipeDurationFormatter.format(Double(viewModel.fixedModeRandomDurationMaximum)))"
            : RecipeDurationFormatter.format(duration)
        let spacing = query.intervalSeconds ?? Double(viewModel.fixedModeButtonInterval)
        let spacingText = viewModel.fixedModeRandomInterval
            ? "random \(RecipeDurationFormatter.format(Double(viewModel.fixedModeRandomIntervalMinimum)))-\(RecipeDurationFormatter.format(Double(viewModel.fixedModeRandomIntervalMaximum))) spacing"
            : "every \(RecipeDurationFormatter.format(spacing))"
        return "\(count) clip\(count == 1 ? "" : "s") at \(durationText), \(spacingText)"
    }

    /// Detail text for the "Increment of space" durationSelector.
    /// Reuses the same query-aware summary as the duration
    /// detail so the two controls read as a matched pair
    /// ("4 clips at 9s, every 12s"). Empty when no query is
    /// active — the selector still works without a detail; the
    /// summary just doesn't show.
    private var fixedIntervalDetail: String? {
        fixedDurationDetail
    }

    private var highlightDurationDetail: String? {
        if let draft = viewModel.highlightDraft {
            return "Live range \(ClipRangeFormatter.formatTime(draft.startSeconds)) - \(ClipRangeFormatter.formatTime(draft.endSeconds))"
        }

        guard viewModel.durationSeconds != nil else { return nil }
        return "Starts at \(viewModel.scrubPositionLabel)"
    }

    /// The big "Add to plan" button. Committing the current draft appends
    /// it to `plannedRanges`, advances the draft start to the end of the
    /// just-added clip, and persists.
    private var highlightAddToPlanButton: some View {
        Button {
            viewModel.addHighlightDraftToPlan()
            PolishKit.Haptics.selection.play()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.caption.weight(.bold))
                Text("Add")
                    .font(.caption.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(AppPalette.background)
            .background(viewModel.highlightDraft != nil ? AppPalette.accent : AppPalette.disabledSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add splice draft to planned clips")
        .disabled(viewModel.highlightDraft == nil)
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
        FixedRecipeEditor(
            title: "Clip recipe",
            inputStyle: Binding(
                get: { viewModel.fixedModeInputStyle },
                set: { viewModel.setFixedModeInputStyle($0) }
            ),
            queryDraft: Binding(
                get: { viewModel.fixedModeQueryDraft },
                set: { viewModel.updateFixedModeQueryDraft($0) }
            ),
            buttonCount: Binding(
                get: { viewModel.fixedModeButtonCount },
                set: { viewModel.setFixedModeButtonCount($0) }
            ),
            buttonDuration: Binding(
                get: { viewModel.fixedModeButtonDuration },
                set: { viewModel.setFixedModeButtonDuration(Double($0)) }
            ),
            buttonInterval: Binding(
                get: { viewModel.fixedModeButtonInterval },
                set: { viewModel.setFixedModeButtonInterval($0) }
            ),
            randomDurationBinding: Binding(
                get: { viewModel.fixedModeRandomDuration },
                set: { viewModel.setFixedModeRandomDuration($0) }
            ),
            randomIntervalBinding: Binding(
                get: { viewModel.fixedModeRandomInterval },
                set: { viewModel.setFixedModeRandomInterval($0) }
            ),
            randomDurationMinimum: Binding(
                get: { Double(viewModel.fixedModeRandomDurationMinimum) },
                set: { viewModel.setFixedModeRandomDurationMinimum($0) }
            ),
            randomDurationMaximum: Binding(
                get: { Double(viewModel.fixedModeRandomDurationMaximum) },
                set: { viewModel.setFixedModeRandomDurationMaximum($0) }
            ),
            randomIntervalMinimum: Binding(
                get: { Double(viewModel.fixedModeRandomIntervalMinimum) },
                set: { viewModel.setFixedModeRandomIntervalMinimum($0) }
            ),
            randomIntervalMaximum: Binding(
                get: { Double(viewModel.fixedModeRandomIntervalMaximum) },
                set: { viewModel.setFixedModeRandomIntervalMaximum($0) }
            ),
            durationRange: selectableClipDurationRange,
            parsedQuery: viewModel.effectiveFixedQuery,
            durationDetail: fixedDurationDetail,
            intervalDetail: fixedIntervalDetail,
            textFocus: $isSegmentFieldFocused,
            repairState: viewModel.fixedModeRepairState,
            isRepairAvailable: viewModel.isAppleIntelligenceRepairAvailable,
            onRepair: { viewModel.repairFixedModeQuery() },
            onApplyRepair: { viewModel.applyRepairedFixedModeQuery($0) },
            onDismissRepair: { viewModel.dismissRepairedFixedModeQuery() }
        )
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

            // "Powered by Apple Intelligence" badge. Sits flush under
            // the prompt so the user knows the engine behind the
            // magic. Tap opens a sheet explaining the on-device
            // guarantee + the free-tier quota. Free users see this
            // too — the upgrade isn't pushed, the transparency is.
            appleIntelligenceBadge
        }
    }

    private var appleIntelligenceBadge: some View {
        let hasCreatorAccess = subscriptionStore.hasAccess(to: .creator)
        let quotaLabel = hasCreatorAccess
            ? "Unlimited"
            : "\(max(0, MediaProcessingLimits.monthlyFreeAIQuota - viewModel.aiPlansThisMonth)) free left"

        return Button {
            showAppleIntelligenceInfo = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.purple)
                Text("Powered by Apple Intelligence")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppPalette.primaryText)
                Text(quotaLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(hasCreatorAccess ? .purple : AppPalette.accent)
                Spacer(minLength: 0)
                Image(systemName: "info.circle")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.mutedText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: [Color.purple.opacity(0.10), Color.blue.opacity(0.06)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.purple.opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Powered by Apple Intelligence — tap for details")
        .sheet(isPresented: $showAppleIntelligenceInfo) {
            appleIntelligenceInfoSheet
        }
    }

    private var appleIntelligenceInfoSheet: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        appleIntelligenceInfoCard
                        Spacer(minLength: 24)
                    }
                    .padding(18)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Apple Intelligence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showAppleIntelligenceInfo = false
                    }
                    .foregroundStyle(AppPalette.accent)
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(AppPalette.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var appleIntelligenceInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.purple)
                Text("On-device AI")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .foregroundStyle(.purple)
            }

            Text("Your video never leaves your phone")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(AppPalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text("ReelClip uses Apple's Foundation Models framework for AI planning. Everything runs on-device on Apple Silicon — no servers, no uploads, no API keys.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(AppPalette.hairline)

            HStack(spacing: 12) {
                Image(systemName: viewModel.currentTier == .creator ? "infinity" : "gauge.with.dots.needle.bottom.50percent")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(viewModel.currentTier == .creator ? .purple : AppPalette.accent)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    let remaining = max(0, MediaProcessingLimits.monthlyFreeAIQuota - viewModel.aiPlansThisMonth)
                    Text(viewModel.currentTier == .creator ? "Unlimited AI plans" : "\(remaining) free AI plans left this month")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text(viewModel.currentTier == .creator ? "Creator tier — no quota." : "Resets monthly. Upgrade for unlimited.")
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryText)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.purple.opacity(0.12), Color.blue.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.purple.opacity(0.25), lineWidth: 1)
        }
    }

    /// Silence-mode "Smart-Enhance with Apple Intelligence" button.
    /// Only meaningful when the user has already planned
    /// silence-mode clips — taps into the existing .smartPause
    /// ranges, runs them through FoundationModels to drop ranges
    /// that sound like false starts or awkward pauses, and
    /// replaces the planned ranges in place. Free users see the
    /// button but it's gated behind the monthly AI plan quota
    /// (3/mo); Creator users get unlimited.
    private var silenceEnhanceButton: some View {
        let smartPauseRanges = viewModel.plannedRanges.filter { $0.cutMode == .smartPause }
        let hasExisting = !smartPauseRanges.isEmpty
        let canRun = viewModel.canRunAnotherFreeAIPlan
        let isProcessing = viewModel.isProcessing

        return Button {
            guard hasExisting, !isProcessing else {
                return
            }
            guard canRun else {
                pendingAction = nil
                showPaywall = true
                return
            }
            PolishKit.Haptics.tap(.medium).play()
            viewModel.enhanceSilenceModeWithAppleIntelligence()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.purple)
                Text(canRun
                     ? "Smart-Enhance with Apple Intelligence"
                     : "Upgrade for unlimited AI enhance")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.primaryText)
                Spacer(minLength: 0)
                if isProcessing {
                    ProgressView().controlSize(.mini).tint(.purple)
                } else if !hasExisting {
                    Text("Run Smart Pause first")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppPalette.mutedText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [Color.purple.opacity(0.10), Color.blue.opacity(0.06)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        canRun && hasExisting
                            ? Color.purple.opacity(0.30)
                            : AppPalette.hairline,
                        lineWidth: 1
                    )
            }
            .opacity(canRun && hasExisting ? 1.0 : 0.65)
        }
        .buttonStyle(.plain)
        .disabled(!hasExisting || isProcessing)
        .accessibilityLabel(canRun
                            ? "Smart-enhance silence mode clips with Apple Intelligence"
                            : "Free tier quota reached, upgrade for unlimited")
    }

    @ViewBuilder
    private var appleIntelligencePanel: some View {
        // No-op panel kept for backwards compatibility with the
        // call site (a small "powered by Apple Intelligence"
        // note). Replaces the old `miniMaxPanel` which used to
        // gate the AI Assist workflow on a MiniMax API key.
        // Apple Intelligence is a system framework so there is
        // no key to add — if the device is ineligible, the
        // planner surfaces its own "Apple Intelligence is
        // unavailable on this device" error when the user
        // actually runs AI Assist.
        EmptyView()
    }

    private var transcriptSection: some View {
        // Wrapped in `.premiumSurface()` so the title + actions row +
        // segment body all live in ONE card, matching the
        // `savedClipsSection` / `cutRecipe` design pattern. The
        // TranscriptView body itself no longer applies
        // `.premiumSurface()` (see TranscriptView.swift) — otherwise
        // we'd get card-in-card. TranscriptView's own inner header
        // (Ready pill, SRT/VTT, refresh, Process) sits flush inside
        // this outer card without competing for visual hierarchy.
        VStack(alignment: .leading, spacing: 12) {
            collapsibleSectionTitle(
                "Transcript",
                detail: transcriptSectionDetail,
                section: .transcript,
                systemImage: "text.bubble"
            )

            if !isSectionCollapsed(.transcript) {
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
                    exportTier: .creator,
                    canExport: subscriptionStore.hasAccess(to: .creator),
                    onRequestUpgrade: {
                        pendingAction = nil
                        showPaywall = true
                    },
                    canProcess: !viewModel.isProcessing && viewModel.sourceURL != nil && (viewModel.durationSeconds ?? 0) > 0,
                    onProcess: {
                        viewModel.processTranscriptToSingleClip()
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .premiumSurface()
    }

    /// Detail text for the transcript collapsible title. Shows the
    /// current transcript state so the user can see whether one
    /// is ready, processing, or missing without expanding the
    /// section. Falls back to "Not generated" when no transcript
    /// has been produced for this source.
    private var transcriptSectionDetail: String {
        switch viewModel.transcriptState {
        case .ready:
            let count = viewModel.transcript?.segments.count ?? 0
            return count == 1 ? "1 word" : "\(count) words"
        case .processing:
            return "Transcribing…"
        case .failed:
            return "Failed — tap to retry"
        case .idle:
            return "Not generated"
        }
    }

    /// Indices for the active recipe's local planned-clips section.
    /// This is intentionally independent from the project export
    /// shuffle: this row answers "what clips did I add in this tab
    /// for this scene?", while the project export preview row answers
    /// "what will the project export, and in what order?".
    private var displayedClipIndices: [Int] {
        visiblePlannedRangeIndices
    }

    private var displayedPlannedRows: [PlannedClipRowItem] {
        displayedClipIndices.enumerated().map { position, rawIndex in
            PlannedClipRowItem(
                position: position,
                rawIndex: rawIndex,
                range: viewModel.plannedRanges[rawIndex]
            )
        }
    }

    /// Transcript-pane Process action's preview sheet. Extracted to
    /// its own computed property to keep the parent body simple
    /// enough for Swift's type-checker — the sheet has 7 viewModel
    /// dependencies that overwhelm the inline closure form.
    @ViewBuilder
    private var tightenedPreviewSheet: some View {
        if let tightened = viewModel.tightenedClips.first {
            TightenedPreviewSheet(
                output: tightened,
                keptRanges: viewModel.tightenedKeptRanges,
                sourceDuration: viewModel.tightenedSourceDuration,
                tier: viewModel.tightenedTier,
                frameDuration: viewModel.tightenedFrameDuration,
                onSave: { viewModel.confirmTightenedExport() },
                onCancel: { viewModel.cancelTightenedExport() }
            )
        }
    }

    /// Project-level export preview sheet (planned clips → Photos).
    /// Extracted for the same type-checker reason as the tightened
    /// sheet — 6 viewModel dependencies in a single closure blows up.
    @ViewBuilder
    private var exportPreviewSheet: some View {
        if let pending = viewModel.pendingExportClips {
            ExportPreviewSheet(
                clips: pending,
                sceneLabels: viewModel.pendingExportSceneLabels,
                missingScenes: viewModel.pendingExportMissingScenes,
                onSave: { viewModel.confirmPendingExport() },
                onDelete: { viewModel.removePendingExportClip($0) },
                onCancel: { viewModel.cancelPendingExport() }
            )
        }
    }

    private var plannedClipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section title is now a single coherent header —
            // the dice + chevron live in the title's right-side
            // button group (via `collapsibleSectionTitle`'s
            // `trailing:` slot) instead of a wide standalone
            // pill. Visual noise drops; affordance stays the
            // same: tap dice to shuffle, tap chevron to
            // collapse, long-press dice for the reset menu.
            collapsibleSectionTitle(
                "Planned clips · \(viewModel.cutMode.shortTitle)",
                detail: plannedClipsDetail,
                section: .plannedClips,
                systemImage: "list.bullet.rectangle",
                trailing: {
                    HStack(spacing: 8) {
                        if !displayedClipIndices.isEmpty {
                            shuffleDiceButton
                            plannedClipsTrashButton
                        }
                    }
                }
            )

            if !isSectionCollapsed(.plannedClips) {
                if displayedClipIndices.isEmpty {
                    plannedClipsEmptyState
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 10) {
                            ForEach(displayedPlannedRows) { row in
                                clipRangeRow(
                                    displayPosition: row.position,
                                    index: row.rawIndex,
                                    range: row.range
                                )
                            }
                        }
                        .padding(.trailing, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 420)
                    .scrollIndicators(.visible)
                    // SwiftUI's id-based reorder animation: when the
                    // displayed indices are reordered (shuffle tap OR
                    // a drop commit), rows slide to their new
                    // positions. Springy easing feels right for both
                    // a "shuffle" gesture and a "drag" release.
                    .animation(.spring(response: 0.42, dampingFraction: 0.78), value: displayedPlannedRows.map(\.id))
                }
            }
        }
        .premiumSurface()
    }

    /// Compact icon-only shuffle button that lives in the
    /// Planned clips section title's trailing slot (next to the
    /// collapse chevron). Replaces the old wide "Shuffle" pill
    /// which crowded the header. The `shuffle` SF Symbol reads
    /// as "reorder" more clearly than the 5-dot `die.face.5.fill`
    /// it replaced. Tapping re-rolls the order; long-press surfaces
    /// the reset menu. Accent fill when shuffled so the user
    /// knows export is using a custom order.
    private var shuffleDiceButton: some View {
        return Button {
            viewModel.randomizePlannedClipsForCurrentMode()
            PolishKit.Haptics.tap(.light).play()
        } label: {
            Image(systemName: "shuffle")
                .font(.caption.weight(.black))
                .foregroundStyle(AppPalette.primaryText)
                .frame(width: 30, height: 30)
                .background(
                    AppPalette.raisedSurface,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Randomize planned clip order")
        .accessibilityHint("Randomizes the current scene and recipe order only.")
    }

    private var plannedClipsTrashButton: some View {
        Button(role: .destructive) {
            isClearPlannedClipsPresented = true
            PolishKit.Haptics.warning.play()
        } label: {
            Image(systemName: "trash")
                .font(.caption.weight(.black))
                .foregroundStyle(AppPalette.danger)
                .frame(width: 30, height: 30)
                .background(
                    AppPalette.danger.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear planned clips for this recipe")
    }

    private var projectExportPreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            projectPlannedClipsRow(items: projectPlannedClipPreviewItems)
        }
        .premiumSurface()
    }

    private var projectPlannedClipPreviewItems: [ProjectPlannedClipPreviewItem] {
        let fallbackSceneID = viewModel.activeSceneId
            ?? viewModel.currentProjectID
            ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

        // Legacy v1: no scenes table, plannedRanges live on the
        // viewModel. There's nothing cross-scene to permute, so
        // canonical time order is the only sensible order. The
        // shuffle state is irrelevant here.
        if viewModel.scenes.isEmpty {
            return viewModel.plannedRanges.indices.map { index in
                makeProjectPreviewItem(
                    sceneID: fallbackSceneID,
                    sceneName: viewModel.activeSceneName,
                    exportIndex: index,
                    range: viewModel.plannedRanges[index],
                    sourceURL: viewModel.sourceURL
                )
            }
        }

        // Multi-scene (and single-scene via the scenes table):
        // walk `orderedFlatExportClips` so the preview reflects
        // the user's shuffle + manual drag-to-reorder in real
        // time. Each entry carries its own scene + source URL
        // so the preview can render the right scene name even
        // when the order is cross-scene. Bug: previously this
        // iterated `viewModel.scenes` in scene order and each
        // scene's `plannedRanges` in canonical index order,
        // silently ignoring `shuffledOrder` — so shuffling the
        // planned-clips section reordered the top of the screen
        // but left the bottom preview stuck in time order.
        return viewModel.orderedFlatExportClips.map { entry in
            makeProjectPreviewItem(
                sceneID: entry.scene.id,
                sceneName: entry.scene.name,
                exportIndex: entry.clipIndex,
                range: entry.range,
                sourceURL: entry.sourceURL ?? viewModel.sourceURL
            )
        }
    }

    private func makeProjectPreviewItem(
        sceneID: UUID,
        sceneName: String,
        exportIndex: Int,
        range: ClipRange,
        sourceURL: URL?
    ) -> ProjectPlannedClipPreviewItem {
        let thumbnailID = projectPreviewThumbnailID(sceneID: sceneID, rangeIndex: exportIndex)
        let isSourceAvailable = sourceURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let previewURL = viewModel.resolvedPlaybackURL(for: sourceURL)
        return ProjectPlannedClipPreviewItem(
            id: "\(sceneID.uuidString)-\(exportIndex)",
            sceneID: sceneID,
            sceneName: sceneName,
            clipIndex: exportIndex,
            range: range,
            thumbnailID: thumbnailID,
            sourceURL: previewURL,
            isSourceAvailable: isSourceAvailable
        )
    }

    private func projectPreviewThumbnailID(sceneID: UUID, rangeIndex: Int) -> UUID {
        var uuid = sceneID.uuid
        uuid.14 = uuid.14 &+ UInt8((rangeIndex >> 8) & 0xff)
        uuid.15 = uuid.15 &+ UInt8(rangeIndex & 0xff)
        return UUID(uuid: uuid)
    }

    private func projectPlannedClipsRow(items: [ProjectPlannedClipPreviewItem]) -> some View {
        let exportableCount = items.filter { $0.isSourceAvailable }.count
        let skippedCount = max(0, items.count - exportableCount)
        let sceneCount = Set(items.map(\.sceneID)).count
        let totalDuration = items
            .filter { $0.isSourceAvailable }
            .reduce(0.0) { $0 + max($1.range.duration, 0) }
        let previewItems = Array(items.prefix(36))

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: "film.stack")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 32, height: 32)
                    .background(AppPalette.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Project export preview")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text(projectExportSummaryText(
                        totalCount: items.count,
                        exportableCount: exportableCount,
                        skippedCount: skippedCount,
                        sceneCount: sceneCount,
                        totalDuration: totalDuration
                    ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(role: .destructive) {
                    isClearProjectExportPresented = true
                    PolishKit.Haptics.warning.play()
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(items.isEmpty ? AppPalette.mutedText : AppPalette.danger)
                        .frame(width: 42, height: 42)
                        .background(
                            items.isEmpty ? AppPalette.disabledSurface : AppPalette.danger.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
                .accessibilityLabel("Clear project export preview")

                // Shuffle button for the project export preview.
                // This is intentionally project-wide: it reorders
                // every planned clip across every scene and recipe.
                // The active planned-clips section stays local to
                // the current scene + current recipe.
                Button {
                    viewModel.shufflePlannedClips()
                    PolishKit.Haptics.tap(.light).play()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(viewModel.isShuffled ? AppPalette.background : AppPalette.primaryText)
                        .frame(width: 42, height: 42)
                        .background(
                            viewModel.isShuffled ? AppPalette.accent : AppPalette.raisedSurface,
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.isShuffled ? "Reshuffle export order" : "Shuffle export order")
                .accessibilityHint("Randomizes the export order. Long-press to reset.")
                .contextMenu {
                    Button("Reset to scene order", action: viewModel.resetShuffle)
                        .disabled(!viewModel.isShuffled)
                }

                Button {
                    isSegmentFieldFocused = false
                    PolishKit.Haptics.tap(.medium).play()
                    viewModel.prepareExport(target: .allScenes)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(exportableCount == 0 ? AppPalette.mutedText : AppPalette.background)
                        .frame(width: 42, height: 42)
                        .background(
                            exportableCount == 0 ? AppPalette.disabledSurface : AppPalette.accent,
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(exportableCount == 0 || viewModel.isProcessing)
                .accessibilityLabel("Export all planned clips in this project")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(previewItems.enumerated()), id: \.element.id) { exportIndex, item in
                        projectPlannedClipTile(item: item, exportIndex: exportIndex)
                    }

                    if items.count > previewItems.count {
                        projectPlannedClipOverflowTile(extraCount: items.count - previewItems.count)
                    }
                }
                .padding(.vertical, 1)
                .animation(.spring(response: 0.42, dampingFraction: 0.78), value: items.map(\.id))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppPalette.accent.opacity(0.35), lineWidth: 1)
        }
    }

    private func projectExportSummaryText(
        totalCount: Int,
        exportableCount: Int,
        skippedCount: Int,
        sceneCount: Int,
        totalDuration: Double
    ) -> String {
        let clipLabel = totalCount == 1 ? "1 clip" : "\(totalCount) clips"
        let sceneLabel = sceneCount == 1 ? "1 scene" : "\(sceneCount) scenes"
        let durationLabel = ClipRangeFormatter.formatTime(totalDuration)
        if skippedCount > 0 {
            return "\(exportableCount) ready of \(clipLabel) · \(sceneLabel) · \(durationLabel) ready · \(skippedCount) skipped"
        }
        return "\(clipLabel) · \(sceneLabel) · \(durationLabel) total"
    }

    private func projectPlannedClipTile(
        item: ProjectPlannedClipPreviewItem,
        exportIndex: Int
    ) -> some View {
        let loopID = "project-\(item.id)"
        let isLooping = loopingProjectPreviewID == loopID
        let isDraggingSource = viewModel.draggingProjectExportIndex == exportIndex
        let isDropTarget = viewModel.projectExportDragTargetIndex == exportIndex
            && viewModel.draggingProjectExportIndex != nil
            && !isDraggingSource

        return VStack(alignment: .leading, spacing: 5) {
            ZStack {
                if isLooping {
                    PreviewVideoView(player: loopPlayer)
                        .frame(width: 58, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if let sourceURL = item.sourceURL, item.isSourceAvailable {
                    VideoThumbnailView(
                        id: item.thumbnailID,
                        url: sourceURL,
                        fallbackSymbol: "film",
                        midpointSeconds: item.range.midpointSeconds,
                        cornerRadius: 10,
                        iconFont: .caption.weight(.bold)
                    )
                    .frame(width: 58, height: 74)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppPalette.mediaWell)
                        .frame(width: 58, height: 74)
                        .overlay {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppPalette.mutedText)
                        }
                }
            }
            .frame(width: 58, height: 74)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture {
                toggleProjectPreviewLoop(item: item)
                PolishKit.Haptics.tap(.medium).play()
            }
            .overlay(alignment: .topLeading) {
                Text("\(exportIndex + 1)")
                    .font(.system(size: 9, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.52), in: Capsule())
                    .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                Button(role: .destructive) {
                    stopPlannedClipLoop()
                    viewModel.removeProjectExportClip(sceneID: item.sceneID, clipIndex: item.clipIndex)
                    PolishKit.Haptics.tap(.medium).play()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(AppPalette.danger.opacity(0.88), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel("Delete project clip \(exportIndex + 1)")
            }
            .overlay(alignment: .bottomTrailing) {
                Text(ClipRangeFormatter.formatTime(item.range.duration))
                    .font(.system(size: 9, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.52), in: Capsule())
                    .padding(4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isDropTarget ? AppPalette.accent
                            : item.isSourceAvailable ? AppPalette.hairline : AppPalette.danger.opacity(0.45),
                        lineWidth: isDropTarget ? 2 : 1
                    )
            }
            .opacity(item.isSourceAvailable ? 1 : 0.52)

            Text(item.sceneName)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(item.isSourceAvailable ? AppPalette.secondaryText : AppPalette.mutedText)
                .lineLimit(1)
                .frame(width: 58, alignment: .leading)
        }
        .onDrag {
            stopPlannedClipLoop()
            viewModel.draggingProjectExportIndex = exportIndex
            return NSItemProvider(object: "\(exportIndex)" as NSString)
        }
        .onDrop(of: [UTType.text], delegate: ProjectExportTileDropDelegate(
            targetPosition: exportIndex,
            viewModel: viewModel
        ))
        .contextMenu {
            Button(role: .destructive) {
                stopPlannedClipLoop()
                viewModel.removeProjectExportClip(sceneID: item.sceneID, clipIndex: item.clipIndex)
            } label: {
                Label("Delete clip", systemImage: "trash")
            }
        }
        .scaleEffect(isDraggingSource ? 1.05 : 1)
        .shadow(
            color: isDraggingSource ? AppPalette.accent.opacity(0.35) : .clear,
            radius: isDraggingSource ? 10 : 0,
            x: 0,
            y: isDraggingSource ? 5 : 0
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isDraggingSource)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isDropTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.sceneName), project clip \(exportIndex + 1), \(ClipRangeFormatter.title(for: item.range))"
        )
    }

    private func projectPlannedClipOverflowTile(extraCount: Int) -> some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppPalette.raisedSurface)
                .frame(width: 58, height: 74)
                .overlay {
                    Text("+\(extraCount)")
                        .font(.headline.monospacedDigit().weight(.black))
                        .foregroundStyle(AppPalette.primaryText)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }

            Text("More")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(AppPalette.secondaryText)
                .frame(width: 58, alignment: .leading)
        }
        .accessibilityLabel("\(extraCount) more planned project clips")
    }

    // MARK: - Long-press clip preview (loops the [start, end] range muted)

    private func startPlannedClipLoop(at index: Int) {
        guard let url = viewModel.resolvedPlaybackURL(for: viewModel.sourceURL) else { return }
        guard viewModel.plannedRanges.indices.contains(index) else { return }
        let range = viewModel.plannedRanges[index]
        if loopingClipIndex == index { return }
        startClipLoop(url: url, range: range) {
            loopingClipIndex = index
        }
    }

    private func stopPlannedClipLoop() {
        loopPlayer.pause()
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        loopObserver = nil
        loopingClipIndex = nil
        loopingProjectPreviewID = nil
        loopingSavedClipID = nil
    }

    private func startClipLoop(
        url: URL,
        range: ClipRange,
        markActive: () -> Void
    ) {
        stopPlannedClipLoop()

        let timescale: CMTimeScale = 600
        let start = CMTime(seconds: range.startSeconds, preferredTimescale: timescale)
        let end = CMTime(seconds: range.endSeconds, preferredTimescale: timescale)
        let item = AVPlayerItem(url: url)
        item.forwardPlaybackEndTime = end

        PolishKit.configureVideoPlaybackAudio()
        loopPlayer.isMuted = false
        loopPlayer.replaceCurrentItem(with: item)
        loopPlayer.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            loopPlayer.play()
        }
        markActive()

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [start] _ in
            loopPlayer.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                loopPlayer.play()
            }
        }
    }

    /// Toggle the looped preview for a planned clip. Tap a different
    /// clip while one is playing — the previous loop stops and the new
    /// one starts. Tap the same clip again to stop.
    private func togglePlannedClipLoop(at index: Int) {
        if loopingClipIndex == index {
            stopPlannedClipLoop()
        } else {
            startPlannedClipLoop(at: index)
        }
    }

    private func toggleProjectPreviewLoop(item: ProjectPlannedClipPreviewItem) {
        let loopID = "project-\(item.id)"
        if loopingProjectPreviewID == loopID {
            stopPlannedClipLoop()
            return
        }
        guard let url = item.sourceURL, item.isSourceAvailable else { return }
        startClipLoop(url: url, range: item.range) {
            loopingProjectPreviewID = loopID
        }
    }

    private func toggleSavedClipLoop(range: ClipRange, displayIndex: Int) {
        let loopID = "saved-\(displayIndex)-\(range.savedRowID)"
        if loopingSavedClipID == loopID {
            stopPlannedClipLoop()
            return
        }
        guard let url = viewModel.resolvedPlaybackURL(for: viewModel.sourceURL) else { return }
        startClipLoop(url: url, range: range) {
            loopingSavedClipID = loopID
        }
    }

    private func clipRangeRow(displayPosition: Int, index: Int, range: ClipRange) -> some View {
        // True while this row is being lifted off the list (the
        // source of the current drag). Surfaces a small lift +
        // shadow so the user can see what's moving.
        let isDraggingSource = viewModel.draggingClipIndex == displayPosition
        // True while another row is being dragged over this one.
        // The accent-tinted border tells the user "this is where
        // the row will land on drop".
        let isDropTarget = viewModel.dragTargetIndex == displayPosition
            && viewModel.draggingClipIndex != nil
            && !isDraggingSource
        // True while this row is the current "replace with…" target
        // — the next recipe run will swap this row in place instead
        // of appending. Distinct accent treatment from the drop
        // target so the user can tell them apart.
        let isReplaceTarget = viewModel.replacingPlannedRangeIndex == index

        return HStack(spacing: 12) {
            plannedClipFramePair(index: index, range: range)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // Tap to toggle the looped preview. Replaces the
                // long-press-to-hold behavior — the user gets to scrub
                // the trim bar / change other settings while the clip
                // keeps playing on the preview.
                .onTapGesture {
                    togglePlannedClipLoop(at: index)
                    PolishKit.Haptics.tap(.medium).play()
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(ClipRangeFormatter.title(for: range))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)

                if let reason = range.reason, !reason.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                        Text(reason)
                            .font(.caption)
                            .italic()
                    }
                    .foregroundStyle(AppPalette.accent.opacity(0.8))
                    .lineLimit(2)
                }

                EditableClipRangeBar(
                    range: range,
                    duration: viewModel.durationSeconds ?? 0,
                    frameDuration: viewModel.frameDurationSeconds,
                    thumbnails: viewModel.sourceThumbnails,
                    onChange: { newRange in
                        updatePlannedRangeAndPreview(at: index, from: range, to: newRange)
                    },
                    onScrub: { seconds in
                        // Middle-grab scrub: seek the preview live to
                        // the dragged position. Does NOT mutate the
                        // range — only the playhead. Tracks the
                        // looped-clip index so the preview knows
                        // which range to follow once playback
                        // resumes. Stops the loop only if the user
                        // scrubs OUTSIDE the current loop's range;
                        // a scrub inside the looped range keeps the
                        // loop running so the user can keep
                        // previewing.
                        userSelectedRangeIndex = index
                        viewModel.updateScrubPosition(seconds)
                        if let loopIndex = loopingClipIndex,
                           loopIndex != index,
                           viewModel.plannedRanges.indices.contains(loopIndex) {
                            let loopRange = viewModel.plannedRanges[loopIndex]
                            if seconds < loopRange.startSeconds || seconds > loopRange.endSeconds {
                                stopPlannedClipLoop()
                            }
                        }
                        seekPreview(to: seconds, pause: true)
                    }
                )
            }

            // Drag handle. Long-press here to start a reorder
            // drag; tap on the body still goes to the loop
            // toggle, so the two interactions don't fight each
            // other. Hides during an active drag because the
            // lifted source row already has the shadow treatment
            // and the affordance would be redundant.
            Image(systemName: "line.3.horizontal")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.secondaryText.opacity(isDraggingSource ? 0.3 : 0.7))
                .frame(width: 24, height: 32)
                .contentShape(Rectangle())
                .onDrag {
                    viewModel.draggingClipIndex = displayPosition
                    return NSItemProvider(object: "\(displayPosition)" as NSString)
                }
                .accessibilityLabel("Reorder clip")
                .accessibilityHint("Long-press to drag this clip to a new position in the export list.")
        }
        .padding(12)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isReplaceTarget ? AppPalette.accent
                        : isDropTarget ? AppPalette.accent
                        : AppPalette.hairline,
                    lineWidth: (isDropTarget || isReplaceTarget) ? 2 : 1
                )
        }
        // Per-clip row actions. Long-press surfaces a context menu
        // with Delete clip (cuts that single planned range) and
        // Replace with… (opens the cut-recipe card in replace mode
        // for the current mode). The replace option only shows when
        // the row is in the same mode as the active tab — cross-mode
        // replace needs its own picker sheet (deferred).
        // The Cancel replace option only shows when THIS row is
        // currently the replace target, giving the user a way out
        // without tapping Cancel on the cut-recipe card.
        .contextMenu {
            Button(role: .destructive) {
                PolishKit.Haptics.tap(.medium).play()
                viewModel.removePlannedRange(atIndex: index)
            } label: {
                Label("Delete clip", systemImage: "trash")
            }
            if isReplaceTarget {
                Button {
                    PolishKit.Haptics.tap(.light).play()
                    viewModel.cancelReplace()
                } label: {
                    Label("Cancel replace", systemImage: "xmark.circle")
                }
            } else if range.cutMode == viewModel.cutMode {
                Button {
                    PolishKit.Haptics.tap(.light).play()
                    viewModel.beginReplacingPlannedRange(atIndex: index)
                } label: {
                    Label("Replace with…", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        // Drop target for the reorder gesture. The whole row
        // accepts the drop (not just the handle) so the user can
        // target any row without aiming for a narrow strip.
        .onDrop(of: [UTType.text], delegate: ClipRowDropDelegate(
            targetPosition: displayPosition,
            viewModel: viewModel
        ))
        // Lift effect on the source row so the user can see
        // what's being dragged. Slight scale + drop shadow;
        // springy to match the row-reorder animation.
        .scaleEffect(isDraggingSource ? 1.02 : 1.0)
        .shadow(
            color: isDraggingSource ? AppPalette.accent.opacity(0.35) : .clear,
            radius: isDraggingSource ? 12 : 0,
            x: 0,
            y: isDraggingSource ? 6 : 0
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isDraggingSource)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isDropTarget)
    }

    private func updatePlannedRangeAndPreview(at index: Int, from oldRange: ClipRange, to proposedRange: ClipRange) {
        viewModel.updatePlannedRange(at: index, to: proposedRange)
        guard viewModel.plannedRanges.indices.contains(index) else { return }

        let updatedRange = viewModel.plannedRanges[index]
        let startDelta = abs(updatedRange.startSeconds - oldRange.startSeconds)
        let endDelta = abs(updatedRange.endSeconds - oldRange.endSeconds)
        let targetSeconds = endDelta > startDelta ? updatedRange.endSeconds : updatedRange.startSeconds

        userSelectedRangeIndex = index
        if loopingClipIndex == index {
            stopPlannedClipLoop()
        }
        viewModel.updateScrubPosition(targetSeconds)
        seekPreview(to: targetSeconds, pause: true)
    }

    private func plannedClipFramePair(index: Int, range: ClipRange) -> some View {
        ZStack {
            HStack(spacing: 4) {
                plannedClipFrameBadge(
                    thumbnail: closestThumbnail(to: range.startSeconds)
                )
                plannedClipFrameBadge(
                    thumbnail: closestThumbnail(to: outPreviewSeconds(for: range))
                )
            }
            .opacity(loopingClipIndex == index ? 0 : 1)

            if loopingClipIndex == index {
                PreviewVideoView(player: loopPlayer)
                    .frame(width: 92, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(width: 92, height: 58)
        .overlay(alignment: .topLeading) {
            // Clip number — 1-indexed, top-left. White text on
            // a translucent black capsule so it reads on any
            // thumbnail. Same overlay pattern as the timeline
            // preview's per-frame timecode (WaveformStrip.swift
            // timelineThumb button).
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.48), in: Capsule())
                .padding(4)
        }
        .overlay(alignment: .topTrailing) {
            // Clip duration — top-right. Same overlay style as
            // the clip number for visual symmetry. Uses the
            // same `formatTime` helper as the title so the
            // values match exactly ("0:05" rather than "5 sec").
            Text(ClipRangeFormatter.formatTime(range.duration))
                .font(.system(size: 9, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.48), in: Capsule())
                .padding(4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        // The total source video duration used to render under
        // the frame pair as `Text(viewModel.durationLabel)`.
        // Removed in v2.0: the clip's start–end in the row
        // title + this top-right clip-duration overlay already
        // give the user the relevant timecode. The total source
        // length belongs to the editor's status capsule, not
        // every row in the list.
    }

    private func plannedClipFrameBadge(thumbnail: MediaThumbnail?) -> some View {
        // Just the thumbnail (or a film-icon placeholder when no frame
        // is available yet). The IN/OUT + timecode overlay is gone — the
        // user gets that info from the title + trim bar in the same row.
        // ZStack wrapper so the two branches can have different modifier
        // chains but a single unified return type.
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 58)
                    .clipShape(Rectangle())
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppPalette.mediaWell)
                    .frame(width: 44, height: 58)
                    .overlay {
                        Image(systemName: "film")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.secondaryText)
                    }
            }
        }
        .frame(width: 44, height: 58)
        .clipped()
    }

    private func outPreviewSeconds(for range: ClipRange) -> Double {
        let frameDuration = viewModel.frameDurationSeconds.isFinite && viewModel.frameDurationSeconds > 0
            ? viewModel.frameDurationSeconds
            : 1.0 / 30.0
        return max(range.startSeconds, range.endSeconds - frameDuration)
    }

    /// Find the source thumbnail closest to a given time. Used to show a
    /// preview frame for each planned clip card.
    private func closestThumbnail(to seconds: Double) -> MediaThumbnail? {
        guard !viewModel.sourceThumbnails.isEmpty else { return nil }
        return viewModel.sourceThumbnails.min { abs($0.timeSeconds - seconds) < abs($1.timeSeconds - seconds) }
    }

    private var savedClipsSection: some View {
        // Shows the project's `savedClips` — the snapshot the user
        // committed via the "Save clips" action. NOT the rendered
        // output (that lives in the export preview sheet, then
        // ships to Photos). v2.0 flow: Plan → Save → Export.
        // Walks `displayedSavedClips` so the row respects the
        // user's saved-side shuffle in real time.
        VStack(alignment: .leading, spacing: 12) {
            collapsibleSectionTitle(
                "Saved clips",
                detail: viewModel.savedClips.isEmpty
                    ? "None yet"
                    : (viewModel.savedClips.count == 1 ? "1 clip" : "\(viewModel.savedClips.count) clips"),
                section: .savedClips,
                systemImage: "checkmark.circle",
                trailing: { savedClipsShuffleButton }
            )

            if !isSectionCollapsed(.savedClips), !viewModel.savedClips.isEmpty {
                savedClipsPreviewRow(ranges: viewModel.displayedSavedClips)
            }
        }
        .premiumSurface()
    }

    /// Saved-side shuffle control, sized to match the
    /// collapsible section title's chevron. Lives in the
    /// title's `trailing:` slot so it stays reachable when
    /// the section is collapsed — the user can reshuffle
    /// without expanding the row first. Disabled when
    /// there are no saved clips to permute. Tapping
    /// re-rolls; long-press surfaces the reset-to-commit-
    /// order menu. Accent fill when shuffled.
    private var savedClipsShuffleButton: some View {
        let canShuffle = viewModel.savedClips.count > 1
        return Button {
            viewModel.shuffleSavedClips()
            PolishKit.Haptics.tap(.light).play()
        } label: {
            Image(systemName: "shuffle")
                .font(.caption.weight(.black))
                .foregroundStyle(
                    canShuffle && viewModel.isSavedClipsShuffled
                        ? AppPalette.background
                        : AppPalette.primaryText
                )
                .frame(width: 30, height: 30)
                .background(
                    canShuffle && viewModel.isSavedClipsShuffled
                        ? AppPalette.accent
                        : AppPalette.raisedSurface,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canShuffle)
        .accessibilityLabel(viewModel.isSavedClipsShuffled ? "Reshuffle saved clips" : "Shuffle saved clips")
        .accessibilityHint("Randomizes the order of the committed clips. Long-press to reset.")
        .contextMenu {
            Button("Reset to commit order", action: viewModel.resetSavedClipsShuffle)
                .disabled(!viewModel.isSavedClipsShuffled)
        }
    }

    private func savedClipsPreviewRow(ranges: [ClipRange]) -> some View {
        let totalDuration = ranges.reduce(0.0) { total, range in
            total + max(range.endSeconds - range.startSeconds, 0)
        }
        let previewRanges = Array(ranges.prefix(36))

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 32, height: 32)
                    .background(AppPalette.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Committed clips")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text(savedClipsSummaryText(
                        totalCount: ranges.count,
                        totalDuration: totalDuration
                    ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                // Clear-saved affordance. Shuffle moved up to
                // the section title's trailing slot so it stays
                // reachable when the section is collapsed. The
                // body header just hosts the Clear-saved trash
                // now.
                Button(role: .destructive) {
                    isClearSavedClipsPresented = true
                    PolishKit.Haptics.warning.play()
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.danger)
                        .frame(width: 42, height: 42)
                        .background(
                            AppPalette.danger.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear saved clips")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    // ClipRange doesn't conform to Identifiable
                    // (it's a value type shared with the timeline
                    // plumbing), so we key the ForEach by a stable
                    // composite string of its position + duration.
                    // The displayIndex-based approach in the planned
                    // section works because ClipRange doesn't change
                    // underneath, but here in the saved row the
                    // user can re-save and replace the list — so
                    // we tie the id to the range's content instead.
                    ForEach(Array(previewRanges.enumerated()), id: \.element.savedRowID) { displayIndex, range in
                        savedClipTile(range: range, displayIndex: displayIndex)
                    }

                    if ranges.count > previewRanges.count {
                        projectPlannedClipOverflowTile(extraCount: ranges.count - previewRanges.count)
                    }
                }
                .padding(.vertical, 1)
                // Match the planned-clips section's row-reorder
                // animation — when the saved row is shuffled the
                // tiles slide to their new positions.
                .animation(.spring(response: 0.42, dampingFraction: 0.78), value: ranges.map(\.savedRowID))
            }

            SavedClipsPlaybackStrip(
                ranges: ranges,
                sourceURL: viewModel.resolvedPlaybackURL(for: viewModel.sourceURL)
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppPalette.accent.opacity(0.35), lineWidth: 1)
        }
    }

    private func savedClipsSummaryText(
        totalCount: Int,
        totalDuration: Double
    ) -> String {
        let clipLabel = totalCount == 1 ? "1 clip" : "\(totalCount) clips"
        let durationLabel = ClipRangeFormatter.formatTime(totalDuration)
        return "\(clipLabel) · \(durationLabel) committed"
    }

    /// Thumbnail tile for a single committed `ClipRange`. Pulls a
    /// representative frame from the source via `closestThumbnail`
    /// (the same lookup the planned-clips section uses) so the
    /// user recognises the range visually. Shows a 1-indexed
    /// position pill and the clip's duration so the saved row
    /// reads as a numbered list rather than a free-for-all.
    private func savedClipTile(range: ClipRange, displayIndex: Int) -> some View {
        let midpoint = (range.startSeconds + range.endSeconds) / 2
        let thumbnail = closestThumbnail(to: midpoint)
        let loopID = "saved-\(displayIndex)-\(range.savedRowID)"
        let isLooping = loopingSavedClipID == loopID
        return VStack(alignment: .leading, spacing: 5) {
            ZStack {
                if isLooping {
                    PreviewVideoView(player: loopPlayer)
                        .frame(width: 58, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if let thumbnail {
                    Image(uiImage: thumbnail.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppPalette.mediaWell)
                        .frame(width: 58, height: 74)
                        .overlay {
                            Image(systemName: "film")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppPalette.mutedText)
                        }
                }
            }
            .frame(width: 58, height: 74)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture {
                toggleSavedClipLoop(range: range, displayIndex: displayIndex)
                PolishKit.Haptics.tap(.medium).play()
            }
            .overlay(alignment: .topLeading) {
                Text("\(displayIndex + 1)")
                    .font(.system(size: 9, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.52), in: Capsule())
                    .padding(4)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(ClipRangeFormatter.formatTime(range.duration))
                    .font(.system(size: 9, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.52), in: Capsule())
                    .padding(4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }

            Text(ClipRangeFormatter.title(for: range))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(AppPalette.secondaryText)
                .lineLimit(1)
                .frame(width: 58, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saved clip \(displayIndex + 1), \(ClipRangeFormatter.title(for: range))")
    }

    /// Run an action if entitlement or the Free AI allowance permits it.
    /// Free users receive the configured monthly quota; only an exhausted
    /// allowance opens the paywall. The mode is captured at tap time so a
    /// mode switch while the paywall is visible cannot change the decision.
    private func guardActionAndShowPaywallIfNeeded(
        for mode: CutMode,
        _ action: @escaping () -> Void
    ) {
        let hasCreatorAccess = subscriptionStore.hasAccess(to: .creator)
        let hasFreeAIAllowance = mode != .aiAssist || viewModel.canRunAnotherFreeAIPlan

        if hasCreatorAccess || hasFreeAIAllowance {
            action()
        } else {
            pendingAction = action
            showPaywall = true
        }
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

    /// Switch from the source to its proxy without resetting the user's
    /// playhead. Proxy and source share the same media timebase, so planned
    /// ranges and loop bounds remain valid across the item replacement.
    private func replacePreviewMediaPreservingPosition(with url: URL) {
        if let currentURL = (previewPlayer.currentItem?.asset as? AVURLAsset)?.url,
           currentURL.standardizedFileURL == url.standardizedFileURL {
            return
        }

        let currentSeconds = previewPlayer.currentTime().seconds
        let seekSeconds = currentSeconds.isFinite ? max(currentSeconds, 0) : viewModel.scrubPositionSeconds
        let wasPlaying = isPreviewPlaying
        let loopRange = activePlannedRangeForLoop()

        clearClipLoop()
        previewPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
        let target = CMTime(seconds: seekSeconds, preferredTimescale: 600)
        previewPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                if let loopRange,
                   viewModel.plannedRanges.indices.contains(loopRange.index) {
                    setupClipLoop(for: loopRange.range, at: loopRange.index)
                }
                if wasPlaying {
                    previewPlayer.play()
                }
            }
        }
    }

    private func installPreviewTimeObserver() {
        guard previewTimeObserver == nil,
              previewPlayer.currentItem != nil
        else {
            return
        }

        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        previewTimeObserver = previewPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard previewPlayer.currentItem != nil,
                  previewPlayer.timeControlStatus == .playing,
                  time.seconds.isFinite
            else {
                return
            }

            Task { @MainActor in
                viewModel.syncScrubPositionFromPlayback(time.seconds)
            }
        }
    }

    private func removePreviewTimeObserver() {
        guard let previewTimeObserver else { return }
        previewPlayer.removeTimeObserver(previewTimeObserver)
        self.previewTimeObserver = nil
    }

    private func togglePreviewPlayback() {
        guard previewPlayer.currentItem != nil else { return }
        if isPreviewPlaying {
            previewPlayer.pause()
            isPreviewPlaying = false
            // User paused — drop the clip-loop so the next play
            // starts fresh from wherever the playhead is, not
            // forced back to the clip's start.
            clearClipLoop()
        } else {
            // First-time play: bring up the audio session so sound comes
            // through even when the ringer switch is off. Done here (not
            // at view appear) because activating the audio session takes
            // over the audio route from other apps, which is appropriate
            // the moment the user explicitly asks for sound.
            configureAudioSessionForPlayback()
            viewModel.syncScrubPositionFromPlayback(previewPlayer.currentTime().seconds)

            // If the user has a clip selected (or has scrubbed
            // the playhead into a planned range), loop the
            // preview within that range instead of playing
            // through the full source video. The loop is
            // implemented via the AVPlayerItem's
            // forwardPlaybackEndTime + an end-of-playback
            // notification observer that rewinds to the start.
            if let loopRange = activePlannedRangeForLoop(),
               viewModel.plannedRanges.indices.contains(loopRange.index) {
                setupClipLoop(for: loopRange.range, at: loopRange.index)
            }

            previewPlayer.play()
            isPreviewPlaying = true
        }
    }

    /// Resolves which planned range the preview should loop in,
    /// if any. Two sources: the user's explicit `userSelectedRangeIndex`
    /// (set by tapping a range on the timeline) or the auto-selected
    /// range that the scrubber is currently inside. Returns
    /// `(index, range)` if a loop is applicable, `nil` otherwise.
    private func activePlannedRangeForLoop() -> (index: Int, range: ClipRange)? {
        // Explicit selection wins.
        if let userIdx = userSelectedRangeIndex,
           viewModel.plannedRanges.indices.contains(userIdx),
           viewModel.plannedRanges[userIdx].cutMode == viewModel.cutMode {
            return (userIdx, viewModel.plannedRanges[userIdx])
        }
        // Otherwise, if the playhead is inside a planned range,
        // loop that one. `liveTimelineRanges` is the mode-filtered
        // view so this respects the active cut mode.
        let playhead = viewModel.scrubPositionSeconds
        if let idx = liveTimelineRanges.firstIndex(where: {
            playhead >= $0.startSeconds && playhead <= $0.endSeconds
        }), let rawIndex = plannedRangeIndex(forTimelineIndex: idx),
            viewModel.plannedRanges.indices.contains(rawIndex) {
            return (rawIndex, viewModel.plannedRanges[rawIndex])
        }
        return nil
    }

    /// Set up the preview-player clip loop. Sets
    /// `forwardPlaybackEndTime` on the current item to the clip's
    /// end, seeks the playhead into the clip if it's outside,
    /// and installs an end-of-playback observer that rewinds to
    /// the clip's start and replays. Safe to call when already
    /// looping — clears the previous loop first.
    private func setupClipLoop(for range: ClipRange, at index: Int) {
        clearClipLoop()
        guard let item = previewPlayer.currentItem else { return }

        let timescale: CMTimeScale = 600
        let start = CMTime(seconds: range.startSeconds, preferredTimescale: timescale)
        let end = CMTime(seconds: range.endSeconds, preferredTimescale: timescale)

        item.forwardPlaybackEndTime = end

        // If the playhead is outside the clip (e.g., the user
        // selected a different clip without scrubbing into it),
        // seek to the clip's start before playing. Async seek
        // completion just signals success — the caller (toggle)
        // already calls `play()` immediately after, which is
        // idempotent.
        let currentTime = previewPlayer.currentTime().seconds
        if currentTime < range.startSeconds || currentTime > range.endSeconds {
            previewPlayer.seek(
                to: start,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        // Rewind + replay on end. Capture the start time and
        // the index by value so the closure doesn't retain
        // self; the loop continues until the user pauses or
        // the selection changes.
        clipLoopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [start] _ in
            // Guard against the loop outliving the item (scene
            // switch, source change). If the observer fires
            // after the item was replaced, `previewPlayer.currentItem`
            // won't match the one we observed on, so skip.
            guard previewPlayer.currentItem === item else { return }
            previewPlayer.seek(
                to: start,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                previewPlayer.play()
            }
        }

        clipLoopActiveRangeIndex = index
    }

    /// Tear down the clip loop. Removes the end-of-playback
    /// observer, clears the AVPlayerItem's forward end time,
    /// and resets the active-range index. Safe to call when no
    /// loop is active.
    private func clearClipLoop() {
        if let observer = clipLoopObserver {
            NotificationCenter.default.removeObserver(observer)
            clipLoopObserver = nil
        }
        // `forwardPlaybackEndTime` defaults to `CMTime.invalid`
        // (which AVPlayer interprets as "no end time"). Reset
        // back to that so the preview plays past the end again
        // after the user pauses.
        previewPlayer.currentItem?.forwardPlaybackEndTime = .invalid
        clipLoopActiveRangeIndex = nil
    }

    private func configureAudioSessionForPlayback() {
        PolishKit.configureVideoPlaybackAudio()
    }

    private var analyzeButtonTitle: String {
        switch viewModel.cutMode {
        case .fixed:
            return "Plan Fixed Clips"
        case .smartPause:
            return "Keep Audible Sections"
        case .highlight:
            return "Add Clip"
        case .aiAssist:
            return "Ask Apple Intelligence"
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
            return "Analyze the selected range, keep audible sections, and skip silent gaps."
        case .highlight:
            return "Manually pick moments to keep."
        case .aiAssist:
            return "Uses Apple Intelligence on-device to draft clips from your timeline signals."
        }
    }

    private var plannedClipsDetail: String {
        // Match the list filter (visiblePlannedRangeIndices) so the
        // header count and the row count never disagree. If the user
        // is in fixed mode and only has highlight ranges planned, the
        // header should say "No plan yet" and the list should be
        // empty — not "3 clips" with an empty list.
        let visibleCount = visiblePlannedRangeIndices.count
        let visibleRanges = visiblePlannedRangeIndices.map { viewModel.plannedRanges[$0] }

        guard visibleCount > 0 else {
            return "No plan yet"
        }

        let countLabel = visibleCount == 1 ? "1 clip" : "\(visibleCount) clips"
        let hasAIReasons = visibleRanges.contains { $0.reason != nil }
        if hasAIReasons {
            return "\(countLabel) · AI suggested"
        }
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

    private func revealTranscriptIfAvailable() {
        guard viewModel.cutMode == .smartPause,
              viewModel.transcriptState == .processing || viewModel.transcriptState == .ready,
              isSectionCollapsed(.transcript) else {
            return
        }
        toggleSection(.transcript)
    }

    private func collapsibleSectionTitle(
        _ title: String,
        detail: String,
        section: CollapsibleSection,
        systemImage: String,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
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

                // Optional trailing accessory (e.g. a shuffle
                // button on the Planned clips section). Lives
                // inside the title's hit area so the user gets a
                // single coherent affordance group on the right;
                // the trailing button's own gesture overrides
                // the title's collapse tap.
                trailing()

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

    /// Sheet that lists every scene for the "Pick a scene…" branch
    /// of the export chooser. Each row shows the scene name, the
    /// planned-clip count, and (when different from the current
    /// scene) the source filename. Tapping a row kicks off
    /// `prepareExport(target: .specificScene(id))` and dismisses
    /// the sheet.
    private var exportScenePickerSheet: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(viewModel.scenes) { scene in
                            Button {
                                isExportScenePickerPresented = false
                                viewModel.prepareExport(target: .specificScene(scene.id))
                            } label: {
                                exportScenePickerRow(scene: scene)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Pick a scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        isExportScenePickerPresented = false
                    }
                    .foregroundStyle(AppPalette.primaryText)
                }
            }
        }
        .tint(AppPalette.accent)
    }

    private func exportScenePickerRow(scene: MediaProjectScene) -> some View {
        let clipCount = scene.plannedRanges.count
        let hasSource = scene.sourceURL != nil || scene.sourcePhotoLibraryIdentifier != nil
        return HStack(spacing: 12) {
            Image(systemName: scene.id == viewModel.activeSceneId
                  ? "checkmark.circle.fill"
                  : "rectangle.stack")
                .font(.title3.weight(.bold))
                .foregroundStyle(scene.id == viewModel.activeSceneId ? AppPalette.accent : AppPalette.secondaryText)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(scene.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(clipCount == 0
                         ? "No planned clips"
                         : "\(clipCount) planned clip\(clipCount == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                    if let fileName = scene.sourceFileName ?? scene.sourceOriginalFilename {
                        Text("·")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.mutedText)
                        Text(fileName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.secondaryText)
                            .lineLimit(1)
                    } else if !hasSource {
                        Text("·")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.mutedText)
                        Text("No source")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.mutedText)
                    }
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.mutedText)
        }
        .padding(13)
        .frame(maxWidth: .infinity)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        .opacity(clipCount == 0 ? 0.5 : 1)
        .disabled(clipCount == 0)
    }
}

private struct PlannedClipRowItem: Identifiable {
    let position: Int
    let rawIndex: Int
    let range: ClipRange

    // The range travels with its content when the user reorders rows. Using
    // the raw array index here makes SwiftUI reuse the old row in place.
    var id: String { range.savedRowID }
}

private struct ProjectPlannedClipPreviewItem: Identifiable {
    let id: String
    let sceneID: UUID
    let sceneName: String
    let clipIndex: Int
    let range: ClipRange
    let thumbnailID: UUID
    let sourceURL: URL?
    let isSourceAvailable: Bool
}

private extension ClipRange {
    var midpointSeconds: Double {
        (startSeconds + endSeconds) / 2
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
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .focused($isFocused)
            // Same keyboard-Done reliability fix as the
            // project title: `.onSubmit` on a TextField
            // doesn't always fire when the keyboard's green
            // Done button is tapped on iOS 26. The toolbar
            // Done explicitly releases focus, which the
            // onChange handler picks up to commit. No
            // `.submitLabel(.done)` here — the per-field
            // toolbar's Done is the single source of truth.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isFocused = false
                    }
                    .fontWeight(.semibold)
                }
            }
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

// MARK: - Export settings sheet

/// Per-project export quality sheet. Lets the user pick the
/// resolution + frame rate for the next export and persists the
/// choice on the project (round-trips through `.reelclip`).
/// Premium options are gated to Creator+: tapping a locked
/// option shows the paywall instead of committing the change.
private struct ExportSettingsSheet: View {
    @EnvironmentObject private var viewModel: VideoSplitterViewModel
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    /// Working copy so the user can fiddle with the pickers
    /// before saving. Resets to the project's current value
    /// each time the sheet appears.
    @State private var draft: ExportSettings = ExportSettings(resolution: .source, frameRate: .source)
    @State private var hasSeeded = false
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        heroCard
                        resolutionSection
                        frameRateSection
                        saveBar
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Export quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(AppPalette.primaryText)
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .environmentObject(subscriptionStore)
            }
        }
        .tint(AppPalette.accent)
        .onAppear {
            if !hasSeeded {
                draft = viewModel.projectExportSettings
                hasSeeded = true
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline.weight(.bold))
                Text("Export quality")
                    .font(.subheadline.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.8)
            }
            .foregroundStyle(AppPalette.accent)

            Text("Choose how your clips render. Settings save to this project and ship in the .reelclip file.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumSurface()
    }

    private var resolutionSection: some View {
        optionSection(
            title: "Resolution",
            systemImage: "ruler",
            options: ExportSettings.Resolution.allCases,
            current: draft.resolution,
            label: { $0.displayName },
            isLocked: { $0.isPremium && !subscriptionStore.hasAccess(to: .creator) },
            onPick: { picked in
                guard !picked.isPremium || subscriptionStore.hasAccess(to: .creator) else {
                    showPaywall = true
                    PolishKit.Haptics.tap(.light).play()
                    return
                }
                draft.resolution = picked
                PolishKit.Haptics.selection.play()
            }
        )
    }

    private var frameRateSection: some View {
        optionSection(
            title: "Frame rate",
            systemImage: "speedometer",
            options: ExportSettings.FrameRate.allCases,
            current: draft.frameRate,
            label: { $0.displayName },
            isLocked: { $0.isPremium && !subscriptionStore.hasAccess(to: .creator) },
            onPick: { picked in
                guard !picked.isPremium || subscriptionStore.hasAccess(to: .creator) else {
                    showPaywall = true
                    PolishKit.Haptics.tap(.light).play()
                    return
                }
                draft.frameRate = picked
                PolishKit.Haptics.selection.play()
            }
        )
    }

    private func optionSection<Option: Hashable & CaseIterable>(
        title: String,
        systemImage: String,
        options: [Option],
        current: Option,
        label: @escaping (Option) -> String,
        isLocked: @escaping (Option) -> Bool,
        onPick: @escaping (Option) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(.caption.weight(.black))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(AppPalette.mutedText)
            }

            VStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    Button {
                        onPick(option)
                    } label: {
                        ExportSettingsRow(
                            label: label(option),
                            isSelected: current == option,
                            isLocked: isLocked(option)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var saveBar: some View {
        let dirty = draft != viewModel.projectExportSettings
        return Button {
            viewModel.updateExportSettings(draft)
            PolishKit.Haptics.tap(.medium).play()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                if dirty {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.black))
                }
                Text(dirty ? "Save to project" : "Saved")
                    .font(.headline.weight(.black))
                    .lineLimit(1)
            }
            .foregroundStyle(AppPalette.background)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                dirty ? AppPalette.accent : AppPalette.disabledSurface,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!dirty)
        .polishPressFeedback()
    }
}

private struct ExportSettingsRow: View {
    let label: String
    let isSelected: Bool
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(isSelected ? AppPalette.accent : AppPalette.secondaryText.opacity(0.7), lineWidth: 2)
                    .frame(width: 22, height: 22)
                if isSelected {
                    Circle()
                        .fill(AppPalette.accent)
                        .frame(width: 12, height: 12)
                }
            }

            Text(label)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.primaryText)

            Spacer(minLength: 8)

            if isLocked {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.bold))
                    Text("Creator")
                        .font(.caption2.weight(.black))
                }
                .foregroundStyle(AppPalette.mutedText)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(AppPalette.controlSurface, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? AppPalette.accent : AppPalette.hairline, lineWidth: isSelected ? 1.8 : 1)
        }
    }
}

/// `DropDelegate` for the planned-clips reorder gesture. Each
/// row registers one of these against `.onDrop` so SwiftUI can
/// route the drag's "I'm over row N now" callback to the right
/// place. The delegate reads the source from
/// `viewModel.draggingClipIndex` (set by the source row's
/// `.onDrag` closure) and forwards the move to
/// `viewModel.reorderPlannedClips(from:to:)` on every enter. The
/// reorder is animated by the parent VStack's
/// `.animation(value: displayedClipIndices)` modifier, so as the
/// user drags across rows the current scene + current recipe list
/// slides into the new order continuously instead of snapping on
/// release.
private struct ClipRowDropDelegate: DropDelegate {
    let targetPosition: Int
    let viewModel: VideoSplitterViewModel

    func dropEntered(info: DropInfo) {
        guard let source = viewModel.draggingClipIndex,
              source != targetPosition else { return }
        // Update both the source pointer (it now lives at the
        // target's old position until the next move) and the
        // target pointer (so the row can render its highlight).
        viewModel.reorderPlannedClips(from: source, to: targetPosition)
        viewModel.draggingClipIndex = targetPosition
        viewModel.dragTargetIndex = targetPosition
    }

    func performDrop(info: DropInfo) -> Bool {
        viewModel.draggingClipIndex = nil
        viewModel.dragTargetIndex = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct ProjectExportTileDropDelegate: DropDelegate {
    let targetPosition: Int
    let viewModel: VideoSplitterViewModel

    func dropEntered(info: DropInfo) {
        guard let source = viewModel.draggingProjectExportIndex,
              source != targetPosition else { return }
        viewModel.reorderProjectExportClips(from: source, to: targetPosition)
        viewModel.draggingProjectExportIndex = targetPosition
        viewModel.projectExportDragTargetIndex = targetPosition
    }

    func performDrop(info: DropInfo) -> Bool {
        viewModel.draggingProjectExportIndex = nil
        viewModel.projectExportDragTargetIndex = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Video preview sizing

/// Bridges the `videoPreview` ZStack's rendered height back to
/// the parent view. SwiftUI's preference system is the
/// lowest-overhead way to mirror a single CGFloat up the tree
/// without a full GeometryReader per frame.

/// Discrete size levels for the main video preview. Replaces
/// a free-form drag-resize handle (which was buggy — the
/// gesture conflicted with the existing tap path, the
/// visual feedback was a thin pill that was hard to grab on
/// a phone-sized screen, and the free-form height had no
/// obvious meaning). The cycle is short on purpose: 4 levels
/// is fast to traverse with one hand, and each level has a
/// recognisable shape so the user can predict the result.
///
/// - `.auto` — fit the source aspect to the available width.
///   The default; same behaviour as the original release.
/// - `.small` — 180pt, suitable for skimming a 9:16 vertical
///   source while keeping the rest of the editor visible.
/// - `.medium` — 280pt, comfortable for reviewing a clip
///   you're about to commit without dominating the screen.
/// - `.large` — 400pt, almost full-screen for sources where
///   you need to read on-screen text (captions, slides, etc.).
///
/// `iconName` rotates with each level so the affordance
/// reads "more / less preview space" without an explicit
/// label. `shortLabel` shows the current level on the button
/// itself so the user knows where they are in the cycle.
private enum PreviewSizeLevel: CaseIterable, Hashable {
    case auto
    case small
    case medium
    case large

    /// Next level in the cycle. Wraps from `.large` back to
    /// `.auto` so the user can always reach the default with
    /// one more tap.
    var next: PreviewSizeLevel {
        let all = PreviewSizeLevel.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }

    var height: CGFloat? {
        switch self {
        case .auto: return nil
        case .small: return 180
        case .medium: return 280
        case .large: return 400
        }
    }

    var shortLabel: String {
        switch self {
        case .auto: return "Auto"
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }

    var iconName: String {
        switch self {
        case .auto: return "arrow.up.left.and.arrow.down.right"
        case .small: return "rectangle.compress.vertical"
        case .medium: return "rectangle"
        case .large: return "rectangle.expand.vertical"
        }
    }

    /// Verbose accessibility value. The icon alone is
    /// ambiguous to VoiceOver — the user needs to know the
    /// actual level (Auto / Small / Medium / Large), not just
    /// "a button that resizes the preview".
    var accessibilityValue: String {
        switch self {
        case .auto: return "Auto — fit to source aspect"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

/// Switches the preview's sizing between the auto (aspect-fit)
/// path and a fixed-height path. Kept as a small modifier
/// (rather than inline conditionals in `videoPreview`) so the
/// aspect-fit path can stay declarative — a `.frame(height:)`
/// after the aspectRatio would override the aspect, and
/// SwiftUI's view-builder doesn't have a clean way to express
/// "apply A or B based on a state value" without this kind of
/// helper.
private struct VideoPreviewSizingModifier: ViewModifier {
    let sizeLevel: PreviewSizeLevel
    let sourceAspectRatio: Double

    func body(content: Content) -> some View {
        if let height = sizeLevel.height {
            // User picked a discrete level. Width is whatever
            // the parent gives us (full-width in the editor
            // ScrollView). The AVPlayerLayer inside letterboxes
            // the video to maintain the source aspect.
            content.frame(height: height)
        } else {
            // `.auto` — fit the source aspect to the available
            // width. `contentMode: .fit` keeps the container
            // within the parent's available width — vertical
            // clips shrink the width rather than overflow.
            content
                .aspectRatio(sourceAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }
}


/// Carries the editor ScrollView's current scroll offset (the
/// `minY` of the top of its content in the "editor-scroll"
/// coordinate space) up to the parent view. Used to auto-collapse
/// the cut-recipe section when the user scrolls back near the
/// top — the recipe body takes 200+pt of vertical real estate,
/// and at the top of the editor the user wants that space back
/// for the video preview + scene row + mode tabs.
private struct EditorScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
