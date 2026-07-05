import AVFoundation
import Foundation
import PhotosUI
import SwiftUI

enum CutMode: String, CaseIterable, Identifiable, Codable {
    case fixed = "Fixed"
    case smartPause = "Smart Pause"
    case highlight = "Highlight"
    case aiAssist = "AI Assist"

    var id: String { rawValue }
}

enum ProcessingPhase: Equatable {
    case idle
    case loading
    case analyzing
    case exporting
    case saving

    var isBusy: Bool {
        self != .idle
    }
}

@MainActor
final class VideoSplitterViewModel: ObservableObject {
    @Published var selectedItem: PhotosPickerItem?
    @Published var sourceURL: URL?
    @Published var durationSeconds: Double?
    @Published var cutMode: CutMode = .fixed
    @Published var segmentLengthText = "30"
    @Published var editPrompt = "Make a fast reel"
    @Published var sourceThumbnails: [MediaThumbnail] = []
    @Published var waveformSamples: [WaveformSample] = []
    @Published var scrubPositionSeconds = 0.0
    @Published var timelineZoom: TimelineZoom = .fit
    @Published var frameDurationSeconds = 1.0 / 30.0
    @Published var sourceAspectRatio = 16.0 / 9.0
    @Published var plannedRanges: [ClipRange] = []
    @Published var clips: [SegmentOutput] = []
    @Published var projects: [MediaProject] = []
    @Published var isProjectBrowserVisible = true
    @Published var currentProjectID: UUID?
    @Published var hasMiniMaxAPIKey = false
    @Published var processingPhase: ProcessingPhase = .idle
    @Published var progress = 0.0
    @Published var statusMessage = "Choose a video to get started."
    @Published var errorMessage: String?

    private let segmenter = VideoSegmenter()
    private let smartCutAnalyzer = SmartCutAnalyzer()
    private let highlightAnalyzer = HighlightAnalyzer()
    private let editIntentPlanner = EditIntentPlanner()
    private let previewGenerator = MediaPreviewGenerator()
    private let waveformAnalyzer = WaveformAnalyzer()
    private let tikTokShareService = TikTokDirectShareService()
    private let mediaWorkspace: MediaWorkspace
    private let projectStore: MediaProjectStore
    private let credentialStore = CredentialStore()
    private let exportNotifications: ExportNotificationScheduling
    private let exportBackgroundTasks: ExportBackgroundTaskManaging
    private let miniMaxAPIKeyAccount = "minimax-api-key"
    private let exportRetentionInterval: TimeInterval = 7 * 24 * 60 * 60
    private var processingTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var scrubPersistenceTask: Task<Void, Never>?

    init(
        mediaWorkspace: MediaWorkspace = MediaWorkspace(),
        exportNotifications: ExportNotificationScheduling = ExportNotificationManager.shared,
        exportBackgroundTasks: ExportBackgroundTaskManaging? = nil
    ) {
        self.mediaWorkspace = mediaWorkspace
        self.projectStore = MediaProjectStore(workspace: mediaWorkspace)
        self.exportNotifications = exportNotifications
        self.exportBackgroundTasks = exportBackgroundTasks ?? ExportBackgroundTaskManager.shared
        loadProjects()
        cleanupExpiredExports()
        refreshMiniMaxAPIKeyStatus()
    }

    var isProcessing: Bool {
        processingPhase.isBusy
    }

    var canPrepare: Bool {
        sourceURL != nil &&
            parsedSegmentLength != nil &&
            !isProcessing &&
            (cutMode != .aiAssist || hasMiniMaxAPIKey)
    }

    var canExportPreparedClips: Bool {
        sourceURL != nil && !plannedRanges.isEmpty && !isProcessing
    }

    var currentProjectTitle: String {
        if let currentProjectID, let project = projects.first(where: { $0.id == currentProjectID }) {
            return project.title
        }

        guard let sourceURL else { return "New project" }
        return Self.defaultProjectTitle(for: sourceURL)
    }

    var latestProject: MediaProject? {
        projects.first
    }

    var durationLabel: String {
        guard let durationSeconds else { return "--" }
        return Self.formatDuration(durationSeconds)
    }

    var expectedClipCount: Int? {
        guard let durationSeconds,
              durationSeconds.isFinite,
              durationSeconds > 0,
              let parsedSegmentLength,
              parsedSegmentLength.isFinite,
              parsedSegmentLength > 0
        else { return nil }

        let rawCount = ceil(durationSeconds / parsedSegmentLength)
        guard rawCount.isFinite, rawCount > 0 else { return nil }
        return max(Int(rawCount), 1)
    }

    var expectedClipCountLabel: String {
        if !plannedRanges.isEmpty {
            return "\(plannedRanges.count)"
        }

        if cutMode == .smartPause || cutMode == .highlight || cutMode == .aiAssist {
            return "Auto"
        }

        guard let expectedClipCount else { return "--" }
        return "\(expectedClipCount)"
    }

    var parsedSegmentLength: Double? {
        let cleaned = segmentLengthText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned), value.isFinite, value >= 1 else { return nil }
        return value
    }

    var hasUnsavedPlan: Bool {
        !plannedRanges.isEmpty && clips.isEmpty
    }

    var scrubPositionLabel: String {
        Self.formatDuration(scrubPositionSeconds)
    }

    var frameSnapLabel: String {
        guard frameDurationSeconds.isFinite, frameDurationSeconds > 0 else { return "frame snap" }
        let rawFrameRate = (1.0 / frameDurationSeconds).rounded()
        guard rawFrameRate.isFinite, rawFrameRate > 0 else { return "frame snap" }
        let frameRate = Int(min(rawFrameRate, 240))
        return "\(frameRate) fps snap"
    }

    var mediaLimitLabel: String {
        "Max \(MediaProcessingLimits.maximumSourceDurationLabel) source, \(MediaProcessingLimits.maximumPlannedClips) clips"
    }

    var isTikTokDirectShareConfigured: Bool {
        TikTokDirectShareService.isConfigured
    }

    func importSelectedVideo() {
        guard let selectedItem else { return }

        cancelProcessing(updateStatus: false)
        previewTask?.cancel()
        waveformTask?.cancel()

        Task {
            await loadVideo(from: selectedItem)
        }
    }

    func importVideoFile(from url: URL) {
        cancelProcessing(updateStatus: false)
        previewTask?.cancel()
        waveformTask?.cancel()

        Task {
            await loadVideoFile(from: url)
        }
    }

    func invalidatePlan() {
        plannedRanges = []
        clips = []
        progress = 0
        persistCurrentProject()
    }

    func refreshPlanForCurrentInputs() {
        clips = []
        progress = 0
        errorMessage = nil

        guard cutMode == .fixed else {
            plannedRanges = []
            persistCurrentProject()
            return
        }

        guard let durationSeconds,
              let segmentLength = parsedSegmentLength
        else {
            plannedRanges = []
            persistCurrentProject()
            return
        }

        do {
            plannedRanges = try Self.fixedRanges(
                totalDuration: durationSeconds,
                segmentLength: segmentLength,
                frameDuration: frameDurationSeconds
            )
            statusMessage = "Previewing \(plannedRanges.count) fixed clips."
        } catch {
            plannedRanges = []
            errorMessage = error.localizedDescription
            statusMessage = "Adjust seconds per clip."
        }

        persistCurrentProject()
    }

    func updateScrubPosition(_ value: Double) {
        guard value.isFinite, let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else {
            scrubPositionSeconds = 0
            return
        }

        scrubPositionSeconds = min(max(value, 0), durationSeconds)
        scheduleScrubPositionPersistence()
    }

    func updatePlannedRange(at index: Int, to range: ClipRange) {
        guard plannedRanges.indices.contains(index), let durationSeconds else { return }
        plannedRanges[index] = ClipRangeEditor.updatedRange(
            range,
            totalDuration: durationSeconds,
            frameDuration: frameDurationSeconds
        )
        clips = []
        statusMessage = "Review adjusted clip ranges."
        persistCurrentProject()
    }

    func movePlannedRange(at index: Int, direction: Int) {
        let updated = ClipRangeEditor.movedRanges(plannedRanges, from: index, direction: direction)
        guard updated != plannedRanges else { return }
        plannedRanges = updated
        clips = []
        statusMessage = "Review reordered clip ranges."
        persistCurrentProject()
    }

    func isClipShareable(_ clip: SegmentOutput) -> Bool {
        mediaWorkspace.fileManager.fileExists(atPath: clip.url.path)
    }

    func isClipReadyForTikTokShare(_ clip: SegmentOutput) -> Bool {
        isClipShareable(clip) && clip.photoLibraryLocalIdentifier != nil
    }

    func shareClipToTikTok(_ clip: SegmentOutput) {
        guard isClipShareable(clip) else {
            errorMessage = "This clip file is no longer available. Export the planned clips again to share it."
            return
        }

        Task { [weak self] in
            guard let self else { return }

            do {
                let message = try await tikTokShareService.shareVideoClip(clip)
                statusMessage = message
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "TikTok share was not started."
            }
        }
    }

    func startNewProject() {
        beginNewProject(clearSelectedItem: true)
    }

    func startNewProjectFromCurrentSelection() {
        beginNewProject(clearSelectedItem: false)
    }

    func showProjectBrowser() {
        cancelProcessing(updateStatus: false)
        cancelPreviewLoading()
        isProjectBrowserVisible = true
        statusMessage = projects.isEmpty ? "Start a new project." : "Choose a project to continue."
    }

    func continueLatestProject() {
        guard let latestProject else {
            startNewProject()
            return
        }

        openProject(latestProject)
    }

    func openProject(_ project: MediaProject) {
        cancelProcessing(updateStatus: false)
        previewTask?.cancel()
        waveformTask?.cancel()

        Task {
            await loadProject(project)
        }
    }

    func deleteProject(_ project: MediaProject) {
        do {
            projects = try projectStore.deleteProject(id: project.id)

            if currentProjectID == project.id {
                currentProjectID = nil
                resetLoadedMediaState(keepSource: false)
                isProjectBrowserVisible = true
            }

            statusMessage = projects.isEmpty ? "Start a new project." : "Project removed."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not remove project."
        }
    }

    func saveMiniMaxAPIKey(_ apiKey: String) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedKey.isEmpty else {
            errorMessage = "Enter a MiniMax API key first."
            return
        }

        do {
            try credentialStore.save(trimmedKey, account: miniMaxAPIKeyAccount)
            hasMiniMaxAPIKey = true
            statusMessage = "MiniMax key saved."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not save MiniMax key."
        }
    }

    func removeMiniMaxAPIKey() {
        do {
            try credentialStore.delete(account: miniMaxAPIKeyAccount)
            hasMiniMaxAPIKey = false
            statusMessage = "MiniMax key removed."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not remove MiniMax key."
        }
    }

    func prepareCuts() {
        guard let sourceURL, let segmentLength = parsedSegmentLength else {
            errorMessage = "Enter a segment length of at least 1 second."
            return
        }

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }

            processingPhase = .analyzing
            progress = 0
            plannedRanges = []
            clips = []
            errorMessage = nil
            statusMessage = analysisStatusMessage

            do {
                let ranges: [ClipRange]

                switch cutMode {
                case .fixed:
                    guard let durationSeconds else {
                        throw VideoSegmenterError.invalidDuration
                    }
                    ranges = try Self.fixedRanges(
                        totalDuration: durationSeconds,
                        segmentLength: segmentLength,
                        frameDuration: frameDurationSeconds
                    )
                case .smartPause:
                    ranges = try await smartCutAnalyzer.ranges(
                        for: sourceURL,
                        fallbackSegmentLength: segmentLength
                    )
                case .highlight:
                    let intent = editIntentPlanner.intent(from: editPrompt)
                    let settings = HighlightAnalyzer.settings(from: intent)
                    ranges = try await highlightAnalyzer.ranges(
                        for: sourceURL,
                        fallbackSegmentLength: segmentLength,
                        settings: settings
                    )
                case .aiAssist:
                    ranges = try await miniMaxRanges(
                        for: sourceURL,
                        fallbackSegmentLength: segmentLength
                    )
                }

                try Task.checkCancellation()

                let duration: Double
                if let durationSeconds {
                    duration = durationSeconds
                } else {
                    duration = try await segmenter.duration(for: sourceURL)
                }
                try MediaProcessingLimits.validateSourceDuration(duration)
                plannedRanges = try MediaProcessingLimits.validatedClipPlan(
                    ranges,
                    totalDuration: duration,
                    frameDuration: frameDurationSeconds,
                    minimumDuration: cutMode == .fixed ? min(Self.minimumFixedClipDuration(segmentLength: segmentLength), duration) : MediaProcessingLimits.minimumAIClipDuration
                )

                guard !plannedRanges.isEmpty else {
                    throw VideoSegmenterError.invalidDuration
                }

                progress = 1
                statusMessage = "Review \(plannedRanges.count) planned clips."
                persistCurrentProject()
            } catch is CancellationError {
                statusMessage = "Processing cancelled."
            } catch VideoSegmenterError.cancelled {
                statusMessage = "Processing cancelled."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Analysis stopped."
            }

            processingPhase = .idle
            processingTask = nil
        }
    }

    func exportPreparedClips() {
        guard let sourceURL else {
            errorMessage = "Choose a video first."
            return
        }

        guard !plannedRanges.isEmpty else {
            errorMessage = "Analyze cuts before exporting."
            return
        }

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }

            processingPhase = .exporting
            progress = 0
            clips = []
            errorMessage = nil
            statusMessage = "Exporting clips..."
            let exportProjectTitle = currentProjectTitle
            await exportNotifications.prepareForExportNotifications()
            exportBackgroundTasks.beginExportTask(named: "ReelClip Export") { [weak self] in
                self?.processingTask?.cancel()
                self?.statusMessage = "Export stopped while the app was in the background."
            }
            defer {
                exportBackgroundTasks.endExportTask()
            }

            do {
                guard let durationSeconds else {
                    throw VideoSegmenterError.invalidDuration
                }
                try MediaProcessingLimits.validateSourceDuration(durationSeconds)
                let safeRanges = try MediaProcessingLimits.validatedClipPlan(
                    plannedRanges,
                    totalDuration: durationSeconds,
                    frameDuration: frameDurationSeconds
                )
                let exportedClips = try await segmenter.segmentVideo(
                    sourceURL: sourceURL,
                    ranges: safeRanges
                ) { [weak self] value in
                    self?.progress = value
                }

                try Task.checkCancellation()

                clips = exportedClips
                processingPhase = .saving
                statusMessage = "Saving clips to Photos..."
                let photoLibraryIdentifiers = try await segmenter.saveToPhotoLibrary(exportedClips)
                clips = exportedClips.map { clip in
                    clip.withPhotoLibraryLocalIdentifier(photoLibraryIdentifiers[clip.id])
                }
                statusMessage = "Saved \(exportedClips.count) clips to Photos. Tap a clip to share."
                await exportNotifications.notifyExportCompleted(
                    clipCount: exportedClips.count,
                    projectTitle: exportProjectTitle
                )
                persistCurrentProject()
            } catch is CancellationError {
                statusMessage = "Processing cancelled."
            } catch VideoSegmenterError.cancelled {
                statusMessage = "Processing cancelled."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Export stopped."
                await exportNotifications.notifyExportFailed(
                    projectTitle: exportProjectTitle,
                    message: error.localizedDescription
                )
            }

            processingPhase = .idle
            processingTask = nil
        }
    }

    func cancelProcessing() {
        cancelProcessing(updateStatus: true)
    }

    func clearError() {
        errorMessage = nil
    }

    private func cancelProcessing(updateStatus: Bool) {
        processingTask?.cancel()
        processingTask = nil
        processingPhase = .idle
        progress = 0

        if updateStatus {
            statusMessage = "Processing cancelled."
        }
    }

    private func loadProjects() {
        do {
            projects = try projectStore.loadProjects()
            statusMessage = projects.isEmpty ? "Start a new project." : "Choose a project to continue."
        } catch {
            projects = []
            statusMessage = "Start a new project."
            errorMessage = error.localizedDescription
        }
    }

    private func cleanupExpiredExports() {
        let cutoffDate = Date().addingTimeInterval(-exportRetentionInterval)
        let projectClipURLs = projects.flatMap(\.exportedClips).map(\.url)

        do {
            try mediaWorkspace.cleanupExports(olderThan: cutoffDate, preserving: projectClipURLs)
        } catch {
            statusMessage = "Could not clean old exports."
        }
    }

    private func beginNewProject(clearSelectedItem: Bool) {
        cancelProcessing(updateStatus: false)
        previewTask?.cancel()
        waveformTask?.cancel()
        scrubPersistenceTask?.cancel()

        if clearSelectedItem {
            selectedItem = nil
        }

        currentProjectID = nil
        resetLoadedMediaState(keepSource: false)
        errorMessage = nil
        isProjectBrowserVisible = false
        statusMessage = "Import source footage."
    }

    private func cancelPreviewLoading() {
        previewTask?.cancel()
        waveformTask?.cancel()
    }

    private var analysisStatusMessage: String {
        switch cutMode {
        case .fixed:
            return "Planning fixed clips..."
        case .smartPause:
            return "Analyzing audio..."
        case .highlight:
            return "Scoring highlights..."
        case .aiAssist:
            return "Asking MiniMax..."
        }
    }

    private func loadVideo(from item: PhotosPickerItem) async {
        processingPhase = .loading
        progress = 0
        resetLoadedMediaState(keepSource: false)
        errorMessage = nil
        statusMessage = "Loading video..."

        do {
            guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
                statusMessage = "Choose a valid video file."
                processingPhase = .idle
                return
            }

            try await setLoadedVideo(url: video.url)
            isProjectBrowserVisible = false
            statusMessage = "Ready to analyze cuts."
        } catch {
            sourceURL = nil
            durationSeconds = nil
            sourceThumbnails = []
            waveformSamples = []
            scrubPositionSeconds = 0
            errorMessage = error.localizedDescription
            statusMessage = "Could not load video."
        }

        processingPhase = .idle
    }

    private func loadVideoFile(from url: URL) async {
        processingPhase = .loading
        progress = 0
        resetLoadedMediaState(keepSource: false)
        errorMessage = nil
        statusMessage = "Importing file..."

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let copiedURL = try mediaWorkspace.importSourceCopy(from: url)
            try await setLoadedVideo(url: copiedURL)
            isProjectBrowserVisible = false
            statusMessage = "Ready to analyze cuts."
        } catch {
            sourceURL = nil
            durationSeconds = nil
            sourceThumbnails = []
            waveformSamples = []
            scrubPositionSeconds = 0
            errorMessage = error.localizedDescription
            statusMessage = "Could not import file."
        }

        processingPhase = .idle
    }

    private func resetLoadedMediaState(keepSource: Bool) {
        if !keepSource {
            sourceURL = nil
            durationSeconds = nil
        }
        plannedRanges = []
        sourceThumbnails = []
        waveformSamples = []
        scrubPositionSeconds = 0
        frameDurationSeconds = 1.0 / 30.0
        sourceAspectRatio = 16.0 / 9.0
        clips = []
    }

    private func setLoadedVideo(url: URL) async throws {
        sourceURL = url
        let duration = try await segmenter.duration(for: url)
        try MediaProcessingLimits.validateSourceDuration(duration)
        durationSeconds = duration
        frameDurationSeconds = try await frameDuration(for: url)
        sourceAspectRatio = try await aspectRatio(for: url)
        loadPreviews(for: url, durationSeconds: duration)
        loadWaveform(for: url, durationSeconds: duration)
        refreshPlanForCurrentInputs()
        persistCurrentProject()
    }

    private func loadProject(_ project: MediaProject) async {
        processingPhase = .loading
        progress = 0
        errorMessage = nil
        statusMessage = "Opening project..."

        guard FileManager.default.fileExists(atPath: project.sourceURL.path) else {
            processingPhase = .idle
            errorMessage = "The original imported video for this project is missing."
            statusMessage = "Could not open project."
            return
        }

        do {
            try MediaProcessingLimits.validateSourceDuration(project.durationSeconds)
        } catch {
            processingPhase = .idle
            errorMessage = error.localizedDescription
            statusMessage = "Could not open project."
            return
        }

        resetLoadedMediaState(keepSource: false)
        currentProjectID = project.id
        sourceURL = project.sourceURL
        durationSeconds = project.durationSeconds
        cutMode = project.cutMode
        segmentLengthText = project.segmentLengthText
        editPrompt = project.editPrompt
        frameDurationSeconds = Self.safeFrameDuration(project.frameDurationSeconds)
        sourceAspectRatio = Self.safeAspectRatio(project.sourceAspectRatio)
        plannedRanges = VideoSegmenter.normalizedRanges(project.plannedRanges, totalDuration: project.durationSeconds)
        clips = project.exportedClips
            .map(\.segmentOutput)
            .filter { isClipShareable($0) }
        scrubPositionSeconds = Self.clampedSeconds(project.scrubPositionSeconds, duration: project.durationSeconds)
        isProjectBrowserVisible = false

        loadPreviews(for: project.sourceURL, durationSeconds: project.durationSeconds)
        loadWaveform(for: project.sourceURL, durationSeconds: project.durationSeconds)

        statusMessage = "Continue editing \(project.title)."
        processingPhase = .idle
    }

    private func persistCurrentProject() {
        guard let sourceURL, let durationSeconds else { return }

        let now = Date()
        let projectID = currentProjectID ?? UUID()
        let existingProject = projects.first { $0.id == projectID }
        let project = MediaProject(
            id: projectID,
            title: existingProject?.title ?? Self.defaultProjectTitle(for: sourceURL),
            sourcePath: sourceURL.standardizedFileURL.path,
            sourceFileName: sourceURL.lastPathComponent,
            durationSeconds: durationSeconds,
            sourceAspectRatio: Self.safeAspectRatio(sourceAspectRatio),
            frameDurationSeconds: Self.safeFrameDuration(frameDurationSeconds),
            cutMode: cutMode,
            segmentLengthText: segmentLengthText,
            editPrompt: editPrompt,
            plannedRanges: plannedRanges,
            exportedClips: clips
                .filter { isClipShareable($0) }
                .map(StoredClipOutput.init(clip:)),
            scrubPositionSeconds: Self.clampedSeconds(scrubPositionSeconds, duration: durationSeconds),
            createdAt: existingProject?.createdAt ?? now,
            updatedAt: now
        )

        do {
            projects = try projectStore.upsert(project)
            currentProjectID = projectID
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not save project state."
        }
    }

    private func scheduleScrubPositionPersistence() {
        scrubPersistenceTask?.cancel()
        scrubPersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled, let self else { return }
            self.persistCurrentProject()
            self.scrubPersistenceTask = nil
        }
    }

    private func refreshMiniMaxAPIKeyStatus() {
        do {
            hasMiniMaxAPIKey = try credentialStore.read(account: miniMaxAPIKeyAccount) != nil
        } catch {
            hasMiniMaxAPIKey = false
        }
    }

    private func miniMaxRanges(for sourceURL: URL, fallbackSegmentLength: Double) async throws -> [ClipRange] {
        guard let apiKey = try credentialStore.read(account: miniMaxAPIKeyAccount),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            hasMiniMaxAPIKey = false
            throw MiniMaxEditPlannerError.missingAPIKey
        }

        guard let durationSeconds else {
            throw VideoSegmenterError.invalidDuration
        }

        try MediaProcessingLimits.validateSourceDuration(durationSeconds)
        let features = try await timelineFeaturePack(
            for: sourceURL,
            durationSeconds: durationSeconds,
            fallbackSegmentLength: fallbackSegmentLength
        )
        let planner = MiniMaxEditPlanner(apiKey: apiKey)
        return try await planner.planCuts(prompt: editPrompt, features: features)
    }

    private func timelineFeaturePack(
        for sourceURL: URL,
        durationSeconds: Double,
        fallbackSegmentLength: Double
    ) async throws -> TimelineFeaturePack {
        let samples: [WaveformSample]

        if waveformSamples.isEmpty {
            samples = (try? await waveformAnalyzer.samples(
                for: sourceURL,
                durationSeconds: durationSeconds,
                targetSampleCount: MediaProcessingLimits.maximumAIAnalysisPoints
            )) ?? []
        } else {
            samples = Array(waveformSamples.prefix(MediaProcessingLimits.maximumAIAnalysisPoints))
        }

        let points = timelineFeaturePoints(
            samples: samples,
            durationSeconds: durationSeconds
        )
        let requestedMaxClips = min(
            editIntentPlanner.intent(from: editPrompt).maxClips,
            MediaProcessingLimits.maximumPlannedClips
        )
        let fallbackRanges = Array(
            SmartCutAnalyzer.equalRanges(
                totalDuration: durationSeconds,
                segmentLength: fallbackSegmentLength
            )
            .prefix(MediaProcessingLimits.maximumPlannedClips)
        )

        return TimelineFeaturePack(
            sourceDurationSeconds: durationSeconds,
            fallbackSegmentLengthSeconds: fallbackSegmentLength,
            requestedMaxClips: requestedMaxClips,
            targetPlatform: "Reels/TikTok",
            analysisPoints: points,
            fallbackRanges: fallbackRanges
        )
    }

    private func timelineFeaturePoints(
        samples: [WaveformSample],
        durationSeconds: Double
    ) -> [TimelineFeaturePoint] {
        if !samples.isEmpty {
            return samples.map { sample in
                let audioLevel = sample.level.isFinite ? min(max(sample.level, 0), 1) : 0
                return TimelineFeaturePoint(
                    startSeconds: Self.clampedSeconds(sample.startSeconds, duration: durationSeconds),
                    endSeconds: Self.clampedSeconds(sample.endSeconds, duration: durationSeconds),
                    audioLevel: audioLevel,
                    isQuiet: audioLevel <= 0.16
                )
            }
        }

        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }
        let pointCount = min(
            max(Int(ceil(durationSeconds / 5.0)), 1),
            MediaProcessingLimits.maximumAIAnalysisPoints
        )
        let windowDuration = durationSeconds / Double(pointCount)

        return (0..<pointCount).map { index in
            let start = Double(index) * windowDuration
            return TimelineFeaturePoint(
                startSeconds: start,
                endSeconds: min(start + windowDuration, durationSeconds),
                audioLevel: 0,
                isQuiet: false
            )
        }
    }

    private func loadPreviews(for sourceURL: URL, durationSeconds: Double) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }

            do {
                let thumbnails = try await previewGenerator.thumbnails(
                    for: sourceURL,
                    durationSeconds: durationSeconds,
                    targetCount: 12
                )
                try Task.checkCancellation()
                sourceThumbnails = thumbnails
            } catch is CancellationError {
            } catch {
                sourceThumbnails = []
            }

            previewTask = nil
        }
    }

    private func loadWaveform(for sourceURL: URL, durationSeconds: Double) {
        waveformTask?.cancel()
        waveformTask = Task { [weak self] in
            guard let self else { return }

            do {
                let samples = try await waveformAnalyzer.samples(
                    for: sourceURL,
                    durationSeconds: durationSeconds,
                    targetSampleCount: 84
                )
                try Task.checkCancellation()
                waveformSamples = samples
            } catch is CancellationError {
            } catch {
                waveformSamples = []
            }

            waveformTask = nil
        }
    }

    private func frameDuration(for sourceURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { return 1.0 / 30.0 }

        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        guard nominalFrameRate.isFinite, nominalFrameRate > 0 else { return 1.0 / 30.0 }
        return 1.0 / Double(nominalFrameRate)
    }

    private func aspectRatio(for sourceURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { return 16.0 / 9.0 }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        return MediaPreviewGenerator.displayAspectRatio(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        ) ?? 16.0 / 9.0
    }

    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let rounded = Int(seconds.rounded())
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let remainingSeconds = rounded % 60

        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remainingSeconds))"
        }

        return "\(minutes):\(String(format: "%02d", remainingSeconds))"
    }

    private static func safeFrameDuration(_ frameDuration: Double) -> Double {
        guard frameDuration.isFinite, frameDuration > 0 else { return 1.0 / 30.0 }
        return min(max(frameDuration, 1.0 / 240.0), 1.0)
    }

    private static func safeAspectRatio(_ aspectRatio: Double) -> Double {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return 16.0 / 9.0 }
        return min(max(aspectRatio, 0.1), 10.0)
    }

    private static func clampedSeconds(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(seconds, 0), duration)
    }

    private static func defaultProjectTitle(for url: URL) -> String {
        var title = url.deletingPathExtension().lastPathComponent
        let components = title.components(separatedBy: "-")

        if components.count > 7,
           components[0].count == 8,
           components[1].count == 6 {
            let uuidCandidate = components[2...6].joined(separator: "-")
            if UUID(uuidString: uuidCandidate) != nil {
                title = components[7...].joined(separator: "-")
            }
        }

        return title.isEmpty ? "Untitled project" : title
    }

    private static func fixedRanges(
        totalDuration: Double,
        segmentLength: Double,
        frameDuration: Double
    ) throws -> [ClipRange] {
        try MediaProcessingLimits.validateSourceDuration(totalDuration)
        let minimumDuration = min(minimumFixedClipDuration(segmentLength: segmentLength), totalDuration)
        let ranges = SmartCutAnalyzer.equalRanges(
            totalDuration: totalDuration,
            segmentLength: segmentLength,
            minimumFinalSegmentLength: minimumDuration
        )
        return try MediaProcessingLimits.validatedClipPlan(
            ranges,
            totalDuration: totalDuration,
            frameDuration: frameDuration,
            minimumDuration: minimumDuration
        )
    }

    private static func minimumFixedClipDuration(segmentLength: Double) -> Double {
        guard segmentLength.isFinite, segmentLength > 0 else { return 1.0 }
        return min(max(segmentLength * 0.5, 0.10), 1.0)
    }
}
