import AVKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum CollapsibleSection: Hashable {
    case cutRecipe
    case plannedClips
    case savedClips
}

struct ContentView: View {
    @StateObject private var viewModel = VideoSplitterViewModel()
    @State private var previewPlayer = AVPlayer()
    @State private var isPreviewPlaying = false
    @State private var isFileImporterPresented = false
    @State private var isSettingsPresented = false
    @State private var miniMaxAPIKeyDraft = ""
    @State private var collapsedSections: Set<CollapsibleSection> = []
    @State private var clipToShare: SegmentOutput?
    @FocusState private var isSegmentFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                if viewModel.isProjectBrowserVisible {
                    projectHub
                } else {
                    editorWorkspace
                }
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
            ShareSheet(activityItems: [clip.url]) { _, completed, _, error in
                DispatchQueue.main.async {
                    if let error {
                        viewModel.errorMessage = error.localizedDescription
                    } else if completed {
                        viewModel.statusMessage = "Shared \(clip.title)."
                    }
                }
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            AppSettingsSheet(
                miniMaxAPIKeyDraft: $miniMaxAPIKeyDraft,
                hasMiniMaxAPIKey: viewModel.hasMiniMaxAPIKey,
                isTikTokDirectShareConfigured: viewModel.isTikTokDirectShareConfigured,
                onSaveMiniMaxAPIKey: { apiKey in
                    viewModel.saveMiniMaxAPIKey(apiKey)
                    miniMaxAPIKeyDraft = ""
                },
                onRemoveMiniMaxAPIKey: {
                    viewModel.removeMiniMaxAPIKey()
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var shouldShowActionDock: Bool {
        !viewModel.isProjectBrowserVisible &&
            (viewModel.sourceURL != nil || viewModel.isProcessing || !viewModel.plannedRanges.isEmpty)
    }

    private var editorWorkspace: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerSection
                mediaStage
                cutComposer
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

    private var projectHub: some View {
        ScrollView {
            VStack(spacing: 18) {
                projectHero
                projectLibrary
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private var projectHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13, weight: .bold))
                        Text("Creator workspace")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1.1)
                    }
                    .foregroundStyle(AppPalette.accent)

                    Text("Projects")
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .foregroundStyle(AppPalette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text("Continue a saved cut plan or start fresh from Photos, Files, or a connected drive.")
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                settingsButton
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.startNewProject()
                    isFileImporterPresented = true
                } label: {
                    Label("Files", systemImage: "externaldrive")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.primaryText)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }
                .accessibilityLabel("Create a new project from Files or connected drive")

                PhotosPicker(
                    selection: $viewModel.selectedItem,
                    matching: .videos,
                    photoLibrary: .shared()
                ) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.background)
                .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onChange(of: viewModel.selectedItem) { _, newItem in
                    guard newItem != nil else { return }
                    viewModel.startNewProjectFromCurrentSelection()
                    viewModel.importSelectedVideo()
                }
            }

            if viewModel.latestProject != nil {
                Button {
                    viewModel.continueLatestProject()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.black))
                            .foregroundStyle(AppPalette.background)
                            .frame(width: 30, height: 30)
                            .background(AppPalette.accent, in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Continue latest")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AppPalette.primaryText)
                            Text(viewModel.latestProject?.title ?? "Draft")
                                .font(.caption)
                                .foregroundStyle(AppPalette.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                    .padding(13)
                    .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .premiumSurface()
    }

    @ViewBuilder
    private var projectLibrary: some View {
        if viewModel.projects.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(AppPalette.accent)

                VStack(spacing: 7) {
                    Text("No saved projects yet")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)

                    Text("Create one project per source video. Your clip plan, mode, prompt, and trim handles will be saved here.")
                        .font(.subheadline)
                        .foregroundStyle(AppPalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .premiumSurface()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle(
                    "Recent projects",
                    detail: viewModel.projects.count == 1
                        ? "1 saved draft"
                        : "\(viewModel.projects.count) saved drafts"
                )

                VStack(spacing: 10) {
                    ForEach(viewModel.projects) { project in
                        projectRow(project)
                    }
                }
            }
            .premiumSurface()
        }
    }

    private func projectRow(_ project: MediaProject) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.openProject(project)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: project.cutMode.symbolName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                        .frame(width: 38, height: 38)
                        .background(AppPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(project.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppPalette.primaryText)
                            .lineLimit(1)

                        Text(project.sourceFileName)
                            .font(.caption)
                            .foregroundStyle(AppPalette.secondaryText)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            projectChip(project.cutMode.shortTitle)
                            projectChip(project.plannedRanges.isEmpty ? "No plan" : "\(project.plannedRanges.count) clips")
                            projectChip(ClipRangeFormatter.formatTime(project.durationSeconds))
                        }
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                viewModel.deleteProject(project)
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.secondaryText)
            .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("Delete project \(project.title)")
        }
        .padding(12)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private func projectChip(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(AppPalette.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(AppPalette.raisedSurface, in: Capsule())
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

                Text("ReelClip")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 8) {
                    settingsButton

                    Button {
                        viewModel.showProjectBrowser()
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

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Image(systemName: "gearshape")
                .font(.caption.weight(.black))
                .foregroundStyle(AppPalette.primaryText)
                .frame(width: 34, height: 34)
                .background(AppPalette.raisedSurface, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open settings")
    }

    private var statusCapsule: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(viewModel.durationLabel)
                .font(.system(.title3, design: .rounded).monospacedDigit().weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
            Text(viewModel.expectedClipCountLabel == "Auto" ? "auto clips" : "\(viewModel.expectedClipCountLabel) clips")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(AppPalette.raisedSurface, in: Capsule())
        .overlay {
            Capsule().stroke(AppPalette.hairline, lineWidth: 1)
        }
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
                            .foregroundStyle(AppPalette.background)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(AppPalette.accent, in: Capsule())
                    }
                    .onChange(of: viewModel.selectedItem) { _, _ in
                        viewModel.importSelectedVideo()
                    }
                }
            }

            if let sourceURL = viewModel.sourceURL {
                VideoPlayer(player: previewPlayer)
                    .aspectRatio(viewModel.sourceAspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        previewPlaybackButton
                            .padding(12)
                    }
                    .task(id: sourceURL) {
                        previewPlayer.replaceCurrentItem(with: AVPlayerItem(url: sourceURL))
                    }

                sourceTimelineScrubber
            } else {
                emptyVideoState
            }
        }
        .premiumSurface()
    }

    private var previewPlaybackButton: some View {
        Button {
            if isPreviewPlaying {
                previewPlayer.pause()
                isPreviewPlaying = false
            } else {
                previewPlayer.play()
                isPreviewPlaying = true
            }
        } label: {
            Label(isPreviewPlaying ? "Pause" : "Play", systemImage: isPreviewPlaying ? "pause.fill" : "play.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPreviewPlaying ? "Pause preview" : "Play preview")
    }

    private var emptyVideoState: some View {
        VStack(spacing: 18) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(AppPalette.accent)

            VStack(spacing: 8) {
                Text("Import source footage")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)

                Text("Analyze a cut plan, review the beats, then export clips for Reels or TikTok.")
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 22)
                    .fixedSize(horizontal: false, vertical: true)
            }

            timelinePreview
                .padding(.horizontal, 22)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 250)
        .padding(.vertical, 28)
        .background(AppPalette.mediaWell, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var timelinePreview: some View {
        HStack(spacing: 8) {
            ForEach(0..<7, id: \.self) { index in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(index == 3 ? AppPalette.accent : AppPalette.timelineBlock)
                    .frame(height: index == 3 ? 34 : 24)
            }
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
                plannedRanges: viewModel.plannedRanges,
                duration: viewModel.durationSeconds ?? 0,
                scrubPosition: viewModel.scrubPositionSeconds
            ) { seconds in
                viewModel.updateScrubPosition(seconds)
                seekPreview(to: seconds)
            }
            .frame(height: 40)

            if let duration = viewModel.durationSeconds, duration > 0 {
                Slider(
                    value: scrubBinding,
                    in: 0...duration
                )
                .tint(AppPalette.accent)
            }
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
        let isInPlannedRange = viewModel.plannedRanges.contains { range in
            thumbnail.timeSeconds >= range.startSeconds && thumbnail.timeSeconds <= range.endSeconds
        }
        let isNearScrubPosition = abs(thumbnail.timeSeconds - viewModel.scrubPositionSeconds) < max((viewModel.durationSeconds ?? 1) / 24, 0.5)
        let size = timelineThumbnailSize

        return Button {
            viewModel.updateScrubPosition(thumbnail.timeSeconds)
            seekPreview(to: thumbnail.timeSeconds)
        } label: {
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: thumbnail.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .background(AppPalette.mediaWell)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

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
                    .stroke(isNearScrubPosition ? AppPalette.accent : (isInPlannedRange ? AppPalette.accent.opacity(0.55) : AppPalette.hairline), lineWidth: isNearScrubPosition ? 3 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isInPlannedRange {
                    Circle()
                        .fill(AppPalette.accent)
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
        let width = max(height * safeAspectRatio, 44)
        return CGSize(width: width, height: height)
    }

    private var cutComposer: some View {
        VStack(alignment: .leading, spacing: 18) {
            collapsibleSectionTitle(
                "Cut recipe",
                detail: modeDescription,
                section: .cutRecipe,
                systemImage: viewModel.cutMode.symbolName
            )

            if !isSectionCollapsed(.cutRecipe) {
                modeSelector

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    metricTile(title: "Duration", value: viewModel.durationLabel, systemImage: "timer")
                    metricTile(title: "Output", value: viewModel.expectedClipCountLabel, systemImage: "rectangle.stack")
                }

                safetyStrip

                secondsControl

                if viewModel.cutMode == .highlight || viewModel.cutMode == .aiAssist {
                    promptControl
                }

                if viewModel.cutMode == .aiAssist {
                    miniMaxPanel
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: isSectionCollapsed(.cutRecipe))
        .premiumSurface()
    }

    private var modeSelector: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(CutMode.allCases) { mode in
                Button {
                    viewModel.cutMode = mode
                    viewModel.refreshPlanForCurrentInputs()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: 16, weight: .bold))
                        Text(mode.shortTitle)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(viewModel.cutMode == mode ? AppPalette.background : AppPalette.primaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(viewModel.cutMode == mode ? AppPalette.accent : AppPalette.controlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(viewModel.cutMode == mode ? Color.clear : AppPalette.hairline, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var safetyStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.checkered")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 30, height: 30)
                .background(AppPalette.accent.opacity(0.12), in: Circle())

            Text(viewModel.mediaLimitLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryText)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var secondsControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(secondsFieldTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.primaryText)

            HStack(spacing: 12) {
                TextField("30", text: $viewModel.segmentLengthText)
                    .keyboardType(.decimalPad)
                    .focused($isSegmentFieldFocused)
                    .font(.system(.largeTitle, design: .rounded).monospacedDigit().weight(.black))
                    .foregroundStyle(AppPalette.primaryText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .frame(height: 62)
                    .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .trailing) {
                        Text("sec")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.mutedText)
                            .padding(.trailing, 16)
                    }
                    .onChange(of: viewModel.segmentLengthText) { _, _ in
                        viewModel.refreshPlanForCurrentInputs()
                    }

                Stepper(value: segmentStepperBinding, in: 1...3600, step: 5) {
                    EmptyView()
                }
                .labelsHidden()
                .padding(.horizontal, 10)
                .frame(height: 62)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var promptControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.cutMode == .aiAssist ? "AI instruction" : "Prompt")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.primaryText)

            TextField("Make a fast reel", text: $viewModel.editPrompt, axis: .vertical)
                .lineLimit(2...4)
                .font(.subheadline)
                .foregroundStyle(AppPalette.primaryText)
                .textFieldStyle(.plain)
                .padding(14)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }
                .onChange(of: viewModel.editPrompt) { _, _ in
                    viewModel.invalidatePlan()
                }
        }
    }

    private var miniMaxPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "key.horizontal")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(viewModel.hasMiniMaxAPIKey ? AppPalette.accent : AppPalette.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(AppPalette.raisedSurface, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("MiniMax M3")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text(viewModel.hasMiniMaxAPIKey ? "API key stored in Keychain" : "API key required for AI Assist")
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondaryText)
                }

                Spacer(minLength: 0)

                if viewModel.hasMiniMaxAPIKey {
                    Button {
                        viewModel.removeMiniMaxAPIKey()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption.weight(.black))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.secondaryText)
                    .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityLabel("Remove MiniMax API key")
                }
            }

            HStack(spacing: 10) {
                SecureField("MiniMax API key", text: $miniMaxAPIKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline.monospaced())
                    .foregroundStyle(AppPalette.primaryText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                    .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    viewModel.saveMiniMaxAPIKey(miniMaxAPIKeyDraft)
                    miniMaxAPIKeyDraft = ""
                } label: {
                    Text("Save")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 76, height: 46)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.background)
                .background(miniMaxAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppPalette.disabledSurface : AppPalette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(miniMaxAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.caption.weight(.bold))
                Text("AI Assist sends compact timeline data to MiniMax, not the source video file.")
                    .font(.caption)
                    .lineLimit(3)
            }
            .foregroundStyle(AppPalette.mutedText)
        }
        .padding(12)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var plannedClipsSection: some View {
        if viewModel.sourceURL != nil || !viewModel.plannedRanges.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
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
                            ForEach(Array(viewModel.plannedRanges.enumerated()), id: \.offset) { index, range in
                                clipRangeRow(index: index, range: range)
                            }
                        }
                    }
                }
            }
            .animation(.snappy(duration: 0.22), value: isSectionCollapsed(.plannedClips))
            .premiumSurface()
        }
    }

    private func clipRangeRow(index: Int, range: ClipRange) -> some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", index + 1))
                .font(.caption.monospacedDigit().weight(.black))
                .foregroundStyle(AppPalette.background)
                .frame(width: 36, height: 36)
                .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(ClipRangeFormatter.title(for: range))
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                EditableClipRangeBar(
                    range: range,
                    duration: viewModel.durationSeconds ?? range.endSeconds,
                    frameDuration: viewModel.frameDurationSeconds
                ) { editedRange in
                    viewModel.updatePlannedRange(at: index, to: editedRange)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text(ClipRangeFormatter.durationLabel(for: range))
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)

                HStack(spacing: 6) {
                    Button {
                        viewModel.movePlannedRange(at: index, direction: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.black))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == 0 ? AppPalette.mutedText : AppPalette.primaryText)
                    .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .disabled(index == 0)
                    .accessibilityLabel("Move clip earlier")

                    Button {
                        viewModel.movePlannedRange(at: index, direction: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.black))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == viewModel.plannedRanges.count - 1 ? AppPalette.mutedText : AppPalette.primaryText)
                    .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .disabled(index == viewModel.plannedRanges.count - 1)
                    .accessibilityLabel("Move clip later")
                }
            }
        }
        .padding(12)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var savedClipsSection: some View {
        if !viewModel.clips.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                collapsibleSectionTitle(
                    "Saved clips",
                    detail: "\(viewModel.clips.count) in Photos",
                    section: .savedClips,
                    systemImage: "checkmark.circle"
                )

                if !isSectionCollapsed(.savedClips) {
                    ForEach(viewModel.clips) { clip in
                        savedClipRow(clip)
                    }
                }
            }
            .animation(.snappy(duration: 0.22), value: isSectionCollapsed(.savedClips))
            .premiumSurface()
        }
    }

    private func savedClipRow(_ clip: SegmentOutput) -> some View {
        let isShareable = viewModel.isClipShareable(clip)
        let isTikTokReady = viewModel.isClipReadyForTikTokShare(clip)

        return HStack(spacing: 10) {
            Button {
                presentShareSheet(for: clip)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.black))
                        .foregroundStyle(AppPalette.background)
                        .frame(width: 28, height: 28)
                        .background(AppPalette.success, in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(clip.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppPalette.primaryText)
                        Text(clip.timeRangeLabel)
                            .font(.caption)
                            .foregroundStyle(AppPalette.secondaryText)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.primaryText)
            .accessibilityLabel("Share \(clip.title), \(clip.timeRangeLabel)")

            Button {
                viewModel.shareClipToTikTok(clip)
            } label: {
                Label("TikTok", systemImage: "music.note")
                    .font(.caption.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(width: 76, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isTikTokReady ? AppPalette.background : AppPalette.mutedText)
            .background(isTikTokReady ? AppPalette.accent : AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityLabel("Share \(clip.title) directly to TikTok")

            Button {
                presentShareSheet(for: clip)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isShareable ? AppPalette.primaryText : AppPalette.mutedText)
                    .frame(width: 36, height: 36)
                    .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
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

                Text("\(progressPercent)% complete")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)
            }

            HStack(spacing: 10) {
                Button {
                    isSegmentFieldFocused = false
                    viewModel.prepareCuts()
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

                if viewModel.isProcessing {
                    Button {
                        viewModel.cancelProcessing()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.black))
                            .frame(width: 54, height: 54)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.primaryText)
                    .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityLabel("Cancel processing")
                }
            }

            if !viewModel.plannedRanges.isEmpty {
                Button {
                    isSegmentFieldFocused = false
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

    private var scrubBinding: Binding<Double> {
        Binding(
            get: {
                viewModel.scrubPositionSeconds
            },
            set: { newValue in
                viewModel.updateScrubPosition(newValue)
                seekPreview(to: newValue)
            }
        )
    }

    private var progressPercent: Int {
        guard viewModel.progress.isFinite else { return 0 }
        return Int((min(max(viewModel.progress, 0), 1) * 100).rounded())
    }

    private func seekPreview(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        previewPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
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
        switch viewModel.cutMode {
        case .fixed:
            return "Seconds per clip"
        case .smartPause, .highlight, .aiAssist:
            return "Fallback seconds per clip"
        }
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

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(AppPalette.primaryText)
            Spacer()
            Text(detail)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppPalette.secondaryText)
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

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var completion: UIActivityViewController.CompletionWithItemsHandler?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = completion
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct AppSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var miniMaxAPIKeyDraft: String
    let hasMiniMaxAPIKey: Bool
    let isTikTokDirectShareConfigured: Bool
    let onSaveMiniMaxAPIKey: (String) -> Void
    let onRemoveMiniMaxAPIKey: () -> Void

    private var trimmedMiniMaxKey: String {
        miniMaxAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        settingsHeader
                        miniMaxCredentialsCard
                        socialIntegrationsCard
                    }
                    .padding(18)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.black))
                            .foregroundStyle(AppPalette.primaryText)
                            .frame(width: 34, height: 34)
                            .background(AppPalette.raisedSurface, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close settings")
                }
            }
        }
        .tint(AppPalette.accent)
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .bold))
                Text("Secure credentials")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.1)
            }
            .foregroundStyle(AppPalette.accent)

            Text("API Keys")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(AppPalette.primaryText)

            Text("User-owned AI keys are saved in the iOS Keychain and kept on this device.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.secondaryText)
                .lineLimit(3)
        }
        .premiumSurface()
    }

    private var miniMaxCredentialsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "brain.head.profile")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 32, height: 32)
                    .background(AppPalette.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("MiniMax M3")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text(hasMiniMaxAPIKey ? "Keychain credential saved" : "No API key saved")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                }

                Spacer(minLength: 0)

                settingsStatusPill(hasMiniMaxAPIKey ? "Stored" : "Missing", isActive: hasMiniMaxAPIKey)
            }

            SecureField("Paste MiniMax API key", text: $miniMaxAPIKeyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.monospaced())
                .foregroundStyle(AppPalette.primaryText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppPalette.hairline, lineWidth: 1)
                }

            HStack(spacing: 10) {
                Button {
                    onSaveMiniMaxAPIKey(trimmedMiniMaxKey)
                } label: {
                    Label("Save Key", systemImage: "key.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(trimmedMiniMaxKey.isEmpty ? AppPalette.mutedText : AppPalette.background)
                .background(trimmedMiniMaxKey.isEmpty ? AppPalette.disabledSurface : AppPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(trimmedMiniMaxKey.isEmpty)

                Button {
                    onRemoveMiniMaxAPIKey()
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasMiniMaxAPIKey ? AppPalette.primaryText : AppPalette.mutedText)
                .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .disabled(!hasMiniMaxAPIKey)
                .accessibilityLabel("Remove MiniMax API key")
            }
        }
        .premiumSurface()
    }

    private var socialIntegrationsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "music.note")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 32, height: 32)
                    .background(AppPalette.accent.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("TikTok Share Kit")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.primaryText)
                    Text("Developer app configuration")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.secondaryText)
                }

                Spacer(minLength: 0)

                settingsStatusPill(isTikTokDirectShareConfigured ? "Ready" : "Setup", isActive: isTikTokDirectShareConfigured)
            }

            Text("TikTok direct share uses the app's registered client key and universal-link redirect, not a user API key.")
                .font(.caption)
                .foregroundStyle(AppPalette.mutedText)
                .lineLimit(3)
        }
        .premiumSurface()
    }

    private func settingsStatusPill(_ title: String, isActive: Bool) -> some View {
        Text(title)
            .font(.caption2.weight(.black))
            .foregroundStyle(isActive ? AppPalette.background : AppPalette.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(isActive ? AppPalette.accent : AppPalette.raisedSurface, in: Capsule())
    }
}

private struct WaveformStrip: View {
    let samples: [WaveformSample]
    let plannedRanges: [ClipRange]
    let duration: Double
    let scrubPosition: Double
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard let timeline = TimelineGeometry(size: size, duration: duration) else {
                    return
                }

                let baseline = size.height / 2
                let displaySampleCount = samples.isEmpty ? 42 : samples.count
                let barWidth = max(timeline.width / CGFloat(max(displaySampleCount, 1)) * 0.58, 1.2)

                for range in plannedRanges {
                    let startX = timeline.xPosition(for: range.startSeconds)
                    let endX = timeline.xPosition(for: range.endSeconds)
                    let rect = CGRect(x: startX, y: 0, width: max(endX - startX, 1), height: size.height)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 6),
                        with: .color(AppPalette.accent.opacity(0.16))
                    )
                }

                if samples.isEmpty {
                    for index in 0..<displaySampleCount {
                        let x = CGFloat(index) * timeline.width / CGFloat(displaySampleCount)
                        let height = CGFloat((index % 5) + 2) / 7.0 * size.height * 0.42
                        let rect = CGRect(x: x, y: baseline - height / 2, width: barWidth, height: max(height, 2))
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 2),
                            with: .color(AppPalette.timelineBlock)
                        )
                    }
                } else {
                    for (index, sample) in samples.enumerated() {
                        let x = CGFloat(index) * timeline.width / CGFloat(max(samples.count, 1))
                        let level = sample.level.isFinite ? min(max(sample.level, 0), 1) : 0
                        let height = max(CGFloat(level) * size.height * 0.92, 2)
                        let rect = CGRect(x: x, y: baseline - height / 2, width: barWidth, height: height)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 2),
                            with: .color(AppPalette.primaryText.opacity(0.42))
                        )
                    }
                }

                let scrubX = timeline.xPosition(for: scrubPosition)
                var path = Path()
                path.move(to: CGPoint(x: scrubX, y: 0))
                path.addLine(to: CGPoint(x: scrubX, y: size.height))
                context.stroke(path, with: .color(AppPalette.accent), lineWidth: 2)

                context.fill(
                    Path(ellipseIn: CGRect(x: scrubX - 4, y: size.height / 2 - 4, width: 8, height: 8)),
                    with: .color(AppPalette.accent)
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrub(at: value.location.x, width: proxy.size.width)
                    }
            )
        }
        .background(AppPalette.mediaWell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(samples.isEmpty ? "Timeline scrubber" : "Audio waveform scrubber")
        .accessibilityValue("\(ClipRangeFormatter.formatTime(scrubPosition)) of \(ClipRangeFormatter.formatTime(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onScrub(min(scrubPosition + 1, duration))
            case .decrement:
                onScrub(max(scrubPosition - 1, 0))
            @unknown default:
                break
            }
        }
    }

    private func scrub(at xPosition: CGFloat, width: CGFloat) {
        guard duration.isFinite, duration > 0, width.isFinite, width > 0 else { return }
        let ratio = min(max(Double(xPosition / width), 0), 1)
        onScrub(duration * ratio)
    }
}

private struct TimelineGeometry {
    let width: CGFloat
    let duration: Double

    init?(size: CGSize, duration: Double) {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              duration.isFinite,
              duration > 0
        else {
            return nil
        }

        self.width = size.width
        self.duration = duration
    }

    func xPosition(for seconds: Double) -> CGFloat {
        guard seconds.isFinite else { return 0 }
        let ratio = min(max(seconds / duration, 0), 1)
        return width * CGFloat(ratio)
    }
}

private struct EditableClipRangeBar: View {
    let range: ClipRange
    let duration: Double
    let frameDuration: Double
    let onChange: (ClipRange) -> Void

    @State private var startDragBase: ClipRange?
    @State private var endDragBase: ClipRange?

    var body: some View {
        GeometryReader { proxy in
            let totalDuration = duration.isFinite && duration > 0 ? duration : 0.05
            let width = proxy.size.width.isFinite && proxy.size.width > 0 ? proxy.size.width : 1
            let startRatio = min(max(range.startSeconds / totalDuration, 0), 1)
            let endRatio = min(max(range.endSeconds / totalDuration, 0), 1)
            let startX = width * startRatio
            let endX = width * endRatio
            let selectedWidth = max(endX - startX, 10)
            let handleSize: CGFloat = 24

            ZStack(alignment: .leading) {
                Capsule().fill(AppPalette.timelineBlock)

                Capsule()
                    .fill(AppPalette.accent)
                    .frame(width: selectedWidth)
                    .offset(x: startX)

                handle
                    .offset(x: min(max(startX - handleSize / 2, 0), width - handleSize))
                    .gesture(startHandleDrag(totalDuration: totalDuration, width: width))

                handle
                    .offset(x: min(max(endX - handleSize / 2, 0), width - handleSize))
                    .gesture(endHandleDrag(totalDuration: totalDuration, width: width))
            }
        }
        .frame(height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trim range \(ClipRangeFormatter.title(for: range))")
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(AppPalette.primaryText)
            .frame(width: 24, height: 24)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppPalette.background.opacity(0.45), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.24), radius: 6, y: 3)
    }

    private func startHandleDrag(totalDuration: Double, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard totalDuration.isFinite, totalDuration > 0, width.isFinite, width > 0 else { return }
                let base = startDragBase ?? range
                startDragBase = base
                let delta = Double(value.translation.width / width) * totalDuration
                let edited = ClipRangeEditor.updatedRange(
                    base,
                    totalDuration: totalDuration,
                    frameDuration: frameDuration,
                    startSeconds: base.startSeconds + delta
                )
                onChange(edited)
            }
            .onEnded { _ in
                startDragBase = nil
            }
    }

    private func endHandleDrag(totalDuration: Double, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard totalDuration.isFinite, totalDuration > 0, width.isFinite, width > 0 else { return }
                let base = endDragBase ?? range
                endDragBase = base
                let delta = Double(value.translation.width / width) * totalDuration
                let edited = ClipRangeEditor.updatedRange(
                    base,
                    totalDuration: totalDuration,
                    frameDuration: frameDuration,
                    endSeconds: base.endSeconds + delta
                )
                onChange(edited)
            }
            .onEnded { _ in
                endDragBase = nil
            }
    }
}

private enum AppPalette {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.066)
    static let surface = Color(red: 0.093, green: 0.098, blue: 0.109)
    static let raisedSurface = Color(red: 0.128, green: 0.134, blue: 0.148)
    static let controlSurface = Color(red: 0.155, green: 0.162, blue: 0.178)
    static let disabledSurface = Color(red: 0.19, green: 0.195, blue: 0.207).opacity(0.58)
    static let mediaWell = Color(red: 0.033, green: 0.036, blue: 0.043)
    static let primaryText = Color(red: 0.94, green: 0.945, blue: 0.93)
    static let secondaryText = Color(red: 0.65, green: 0.67, blue: 0.67)
    static let mutedText = Color(red: 0.43, green: 0.45, blue: 0.45)
    static let accent = Color(red: 0.77, green: 0.94, blue: 0.20)
    static let success = Color(red: 0.33, green: 0.78, blue: 0.47)
    static let hairline = Color.white.opacity(0.08)
    static let timelineBlock = Color.white.opacity(0.14)
}

private enum ClipRangeFormatter {
    static func title(for range: ClipRange) -> String {
        "\(formatTime(range.startSeconds)) - \(formatTime(range.endSeconds))"
    }

    static func durationLabel(for range: ClipRange) -> String {
        guard range.duration.isFinite, range.duration >= 0 else { return "-- sec" }
        return "\(String(format: "%.1f", range.duration)) sec"
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let totalTenths = Int((seconds * 10).rounded())
        let minutes = totalTenths / 600
        let tenthsWithinMinute = totalTenths % 600
        let wholeSeconds = tenthsWithinMinute / 10
        let tenths = tenthsWithinMinute % 10

        if tenths == 0 {
            return "\(minutes):\(String(format: "%02d", wholeSeconds))"
        }

        return "\(minutes):\(String(format: "%02d.%d", wholeSeconds, tenths))"
    }
}

private extension CutMode {
    var symbolName: String {
        switch self {
        case .fixed:
            return "scissors"
        case .smartPause:
            return "waveform"
        case .highlight:
            return "sparkles.tv"
        case .aiAssist:
            return "brain.head.profile"
        }
    }

    var shortTitle: String {
        switch self {
        case .fixed:
            return "Fixed"
        case .smartPause:
            return "Pause"
        case .highlight:
            return "Highlight"
        case .aiAssist:
            return "AI"
        }
    }
}

private extension View {
    func premiumSurface() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(AppPalette.hairline, lineWidth: 1)
            }
    }
}

#Preview {
    ContentView()
}
