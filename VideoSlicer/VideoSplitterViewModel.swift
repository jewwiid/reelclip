import AVFoundation
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit

enum CutMode: String, CaseIterable, Identifiable, Codable {
    case fixed = "Fixed"
    case highlight = "Highlight"

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
final class VideoSplitterViewModel: ObservableObject, ReelClipProjectImportSink {
    @Published var selectedItem: PhotosPickerItem?
    @Published var sourceURL: URL?
    @Published var durationSeconds: Double?
    @Published var cutMode: CutMode = .fixed
    @Published var segmentLengthText = "30"
    @Published var sourceThumbnails: [MediaThumbnail] = []
    @Published var waveformSamples: [WaveformSample] = []
    @Published var scrubPositionSeconds = 0.0

    // MARK: - Highlight mode (manual timeline picker)
    //
    // Highlight mode is a fully-manual clip-picker. The user enters a
    // duration, drags the resulting translucent band along the timeline,
    // resizes its edges, then taps "Add to plan" to commit it to
    // `plannedRanges`. Each successive "Add" appends a new planned range;
    // the draft remains where the user left it so they can keep adding
    // neighbouring segments without re-positioning.
    @Published var highlightDraftStart: Double? = nil
    @Published var highlightDraftDuration: Double = 5.0
    @Published var timelineZoom: TimelineZoom = .fit
    @Published var frameDurationSeconds = 1.0 / 30.0
    @Published var sourceAspectRatio = 16.0 / 9.0
    @Published var plannedRanges: [ClipRange] = []
    @Published var clips: [SegmentOutput] = []
    @Published var projects: [MediaProject] = []
    @Published var isProjectBrowserVisible = true
    @Published private(set) var thumbnailCache: [UUID: UIImage] = [:]
    @Published var currentProjectID: UUID?
    @Published var pendingExportClips: [SegmentOutput]?
    @Published var isShowingExportPreview: Bool = false
    @Published var projectTitleDraft: String = ""
    /// PHAsset localIdentifier for the currently-loaded source video.
    /// Captured from `PhotosPickerItem.itemIdentifier` when the user
    /// picks a video, and written into `.reelclip` export files so
    /// the recipient can resolve the source video on their device.
    @Published var sourcePhotoLibraryIdentifier: String?

    // MARK: - Paywall state

    /// Subscription tier for the current run. Updated by `updateTier(_:)` whenever
    /// the SubscriptionStore's `@Published tier` changes. Drives every
    /// downstream limit check (source duration, export preset, watermark).
    @Published private(set) var currentTier: SubscriptionStore.Tier = .free

    @Published var defaultCutMode: CutMode {
        didSet { userDefaultsStore.defaultCutMode = defaultCutMode }
    }
    @Published var defaultSegmentLength: Int {
        didSet {
            userDefaultsStore.defaultSegmentLengthSeconds = defaultSegmentLength
        }
    }
    @Published var fixedModeQueryDraft: String = ""
    @Published var fixedModeInputStyle: FixedModeInputStyle = .buttons
    @Published var fixedModeButtonCount: Int = 4
    @Published var fixedModeButtonDuration: Int = 5
    @Published var fixedModeButtonInterval: Int = 10

    var parsedFixedQuery: ClipQuery? {
        ClipQueryParser.parse(fixedModeQueryDraft)
    }

    /// Two-way sync between text input and button input.
    ///
    /// Switching from .text to .buttons: pull the parsed values from
    /// the current text query (if any) so the button view reflects
    /// what the user already typed.
    ///
    /// Switching from .buttons to .text: write the current button
    /// values back into the text field so users see a phrase they
    /// can edit. We use a single canonical phrase to avoid drift.
    func syncFixedModeAcrossStyles(to newStyle: FixedModeInputStyle) {
        switch (fixedModeInputStyle, newStyle) {
        case (.text, .buttons):
            if let parsed = parsedFixedQuery, parsed.isValid {
                if let c = parsed.count { fixedModeButtonCount = c }
                if let d = parsed.durationSeconds {
                    fixedModeButtonDuration = max(1, Int(d.rounded()))
                }
                if let i = parsed.intervalSeconds {
                    fixedModeButtonInterval = max(1, Int(i.rounded()))
                }
            }
        case (.buttons, .text):
            fixedModeQueryDraft = FixedModeQueryFormatter.phrase(
                count: fixedModeButtonCount,
                duration: fixedModeButtonDuration,
                interval: fixedModeButtonInterval
            )
        case (_, _):
            break
        }
    }

    var effectiveFixedQuery: ClipQuery? {
        switch fixedModeInputStyle {
        case .text:
            return parsedFixedQuery
        case .buttons:
            return ClipQuery(
                count: fixedModeButtonCount,
                durationSeconds: Double(fixedModeButtonDuration),
                intervalSeconds: Double(fixedModeButtonInterval)
            )
        }
    }
    @Published var processingPhase: ProcessingPhase = .idle
    @Published var progress = 0.0
    @Published var statusMessage = "Choose a video to get started."
    @Published var errorMessage: String?

    private let segmenter = VideoSegmenter()
    private let previewGenerator = MediaPreviewGenerator()
    private let waveformAnalyzer = WaveformAnalyzer()
    private let mediaWorkspace: MediaWorkspace
    private let projectStore: MediaProjectStore
    private let exportNotifications: ExportNotificationScheduling
    private let exportBackgroundTasks: ExportBackgroundTaskManaging
    private var userDefaultsStore: UserDefaultsStore
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
        let defaults = UserDefaultsStore()
        self.userDefaultsStore = defaults
        self.defaultCutMode = defaults.defaultCutMode
        self.defaultSegmentLength = defaults.defaultSegmentLengthSeconds
        loadProjects()
        cleanupExpiredExports()
    }

    /// Sync the active subscription tier. The store calls this whenever its
    /// `tier` published value changes (purchase, refund, restore).
    func updateTier(_ tier: SubscriptionStore.Tier) {
        let previous = currentTier
        currentTier = tier
        if previous != tier {
            // Re-validate the loaded project under the new duration cap;
            // a project that was valid on Creator (15m) might fail under
            // Free (5m) if the user downgraded.
            refreshPlanForCurrentInputs()
        }
    }

    var isProcessing: Bool {
        processingPhase.isBusy
    }

    var canPrepare: Bool {
        sourceURL != nil &&
            parsedSegmentLength != nil &&
            !isProcessing
    }

    var canExportPreparedClips: Bool {
        sourceURL != nil && !plannedRanges.isEmpty && !isProcessing
    }

    var currentProjectTitle: String {
        // Draft wins while the user is editing — otherwise the header would
        // flicker back to the persisted title between keystrokes.
        let trimmed = projectTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }

        if let currentProjectID, let project = projects.first(where: { $0.id == currentProjectID }) {
            return project.title
        }

        guard let sourceURL else { return "New project" }
        return Self.defaultProjectTitle(for: sourceURL)
    }

    /// Default display title for a planned clip at the given index — used as
    /// the seed when rendering clips and when the user clears their custom
    /// name (so the fallback path is consistent everywhere).
    func clipDefaultTitle(for index: Int) -> String {
        let projectName = currentProjectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "Clip \(index + 1)"
        if projectName.isEmpty || projectName == "New project" {
            return suffix
        }
        return "\(projectName) — \(suffix)"
    }

    /// Titles aligned to the current `plannedRanges`. Used at export time so
    /// the on-disk filenames + Photos asset names carry the user's naming
    /// from the moment the clip is rendered.
    func clipTitlesForCurrentPlan() -> [String] {
        plannedRanges.indices.map { clipDefaultTitle(for: $0) }
    }

    /// Update the current project's title. Empty strings are coerced to the
    /// source filename fallback so we never persist a blank project row.
    func updateProjectTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if trimmed.isEmpty {
            resolved = sourceURL.map { Self.defaultProjectTitle(for: $0) } ?? "Untitled project"
        } else {
            resolved = trimmed
        }

        projectTitleDraft = resolved

        guard currentProjectID != nil else {
            // No project persisted yet — the next persistCurrentProject() call
            // will pick up `projectTitleDraft`.
            statusMessage = "Project renamed to \(resolved)."
            return
        }

        applyProjectTitleChange(resolved)
    }

    /// Rename a single saved clip. Updates the in-memory `clips` array and
    /// persists the project so the new title round-trips through JSON.
    func renameClip(_ clipID: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }

        // Pass the raw trimmed string through — SegmentOutput normalizes again
        // and `displayTitle` does the "Clip N" fallback at render time.
        clips[index] = clips[index].withTitle(trimmed)
        persistCurrentProject()
        PolishKit.Haptics.selection.play()
    }

    /// Return a URL that's safe to share via `UIActivityViewController` and
    /// carries the clip's display title as its filename. If the on-disk file
    /// already has the right name we just hand it back; otherwise we copy to
    /// a staging directory so AirDrop / Files / iMessage show the friendly
    /// name instead of the temp "clip-1.mov" the segmenter wrote.
    ///
    /// The staging file lives under the workspace so the standard cleanup
    /// passes (`cleanupExports`) can reap it later.
    func shareableURL(for clip: SegmentOutput) -> URL? {
        let desiredName = FilenameSanitizer.sanitizedFileName(
            from: clip.displayTitle,
            fallbackBase: "clip-\(clip.index + 1)",
            fileExtension: clip.url.pathExtension.isEmpty ? "mov" : clip.url.pathExtension
        )

        if clip.url.lastPathComponent == desiredName {
            return clip.url
        }

        do {
            try mediaWorkspace.prepareBaseDirectories()
            let staging = mediaWorkspace.exportsDirectory
                .appendingPathComponent("Share", isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let destination = FilenameSanitizer.uniqueURL(for: desiredName, in: staging)

            // Overwrite a stale staging file from a previous share of the
            // same clip — the new export will replace it.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: clip.url, to: destination)
            return destination
        } catch {
            // If staging fails for any reason, fall back to the live file so
            // the user can still share — they just lose the nice filename.
            return clip.url
        }
    }

    private func applyProjectTitleChange(_ resolved: String) {
        guard let projectID = currentProjectID,
              let index = projects.firstIndex(where: { $0.id == projectID }) else {
            return
        }

        var project = projects[index]
        guard project.title != resolved else { return }
        project.title = resolved
        project.updatedAt = Date()
        projects[index] = project

        do {
            projects = try projectStore.upsert(project)
            statusMessage = "Project renamed to \(resolved)."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not rename project."
        }
    }

    /// Coalesce the draft / existing title / source-filename fallback into a
    /// single string to write to disk. Draft wins when non-empty so the user's
    /// in-progress rename doesn't get clobbered by the next auto-persist.
    private func resolveProjectTitleForPersistence(existingTitle: String?, sourceURL: URL) -> String {
        let trimmedDraft = projectTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDraft.isEmpty { return trimmedDraft }
        if let existingTitle, !existingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existingTitle
        }
        return Self.defaultProjectTitle(for: sourceURL)
    }

    var latestProject: MediaProject? {
        projects.first
    }

    var durationLabel: String {
        guard let durationSeconds else { return "--" }
        return Self.formatDuration(durationSeconds)
    }

    /// Live feasibility snapshot for the current fixed-mode input. Read from
    /// the `Expected` panel so the `Expected` integer and the actual clip
    /// count never disagree.
    var liveRecipeFeasibility: ClipQuery.Feasibility? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return effectiveFixedQuery?.feasibility(forSourceDuration: durationSeconds)
    }

    /// True when the user's typed recipe cannot produce a single clip inside
    /// the current source (source shorter than the requested clip duration).
    /// Drives both the safety-strip badge and an early guard in `prepareCuts`.
    var recipeHasNoHeadroom: Bool {
        guard let feasibility = liveRecipeFeasibility else { return false }
        return feasibility.achievableCount == 0 && feasibility.requestedCount != nil
    }

    var expectedClipCount: Int? {
        guard let durationSeconds,
              durationSeconds.isFinite,
              durationSeconds > 0
        else { return nil }

        // Honour the user's explicit count first. The math function clamps to
        // what's actually achievable, so we don't need a separate "did the
        // user ask for too many?" check here — `liveRecipeFeasibility`
        // surfaces that discrepancy.
        if let query = effectiveFixedQuery,
           query.isValid,
           let requestedCount = query.count,
           requestedCount > 0 {
            return query.achievableCount(forSourceDuration: durationSeconds)
        }

        guard let parsedSegmentLength,
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

        if cutMode == .highlight {
            return "Auto"
        }

        guard let expectedClipCount else { return "--" }
        // Surface the truncation: when the achievable count is less than what
        // the user asked for, render "achievable of requested" so the panel
        // and the actual output can never disagree.
        if let feasibility = liveRecipeFeasibility,
           let requested = feasibility.requestedCount,
           requested > 0,
           feasibility.achievableCount < requested {
            return "\(feasibility.achievableCount) of \(requested)"
        }
        return "\(expectedClipCount)"
    }

    var parsedSegmentLength: Double? {
        // Try the per-project text first (set via the Clip recipe slider), then
        // fall back to the user-configured default from Settings. This way the
        // safe internal default still works even if `segmentLengthText` was
        // never set for this project.
        let cleaned = segmentLengthText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(cleaned), value.isFinite, value >= 1 {
            return value
        }
        let fallback = Double(defaultSegmentLength)
        return fallback.isFinite && fallback >= 1 ? fallback : nil
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
                frameDuration: frameDurationSeconds,
                tier: currentTier
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
        var updated = ClipRangeEditor.updatedRange(
            range,
            totalDuration: durationSeconds,
            frameDuration: frameDurationSeconds
        )
        // Prevent overlap with neighbors. Clamp the moved range so its
        // start doesn't cross the previous range's end, and its end
        // doesn't cross the next range's start. Keeps every range
        // independently selectable — without this, two overlapping
        // ranges stack their handle hit-zones on top of each other and
        // the later-rendered one swallows all taps.
        if index > 0 {
            let prevEnd = plannedRanges[index - 1].endSeconds
            updated = ClipRange(startSeconds: max(updated.startSeconds, prevEnd),
                                endSeconds: updated.endSeconds)
        }
        if index < plannedRanges.count - 1 {
            let nextStart = plannedRanges[index + 1].startSeconds
            updated = ClipRange(startSeconds: updated.startSeconds,
                                endSeconds: min(updated.endSeconds, nextStart))
        }
        // If clamping collapsed the range below minimum, skip the update
        // rather than emit an invalid range.
        guard updated.endSeconds - updated.startSeconds >= 0.05 else { return }
        plannedRanges[index] = updated
        clips = []
        statusMessage = "Review adjusted clip ranges."
        persistCurrentProject()
    }

    // MARK: Highlight mode (manual) — draft controls

    /// The current draft highlight as a `ClipRange`, or `nil` if the user
    /// hasn't placed one yet (or has just added it and cleared).
    var highlightDraft: ClipRange? {
        guard let start = highlightDraftStart,
              let total = durationSeconds,
              total > 0
        else { return nil }
        let clampedDuration = max(min(highlightDraftDuration, total - start), 0.1)
        return ClipRange(startSeconds: start, endSeconds: start + clampedDuration)
    }

    /// User typed a new clip duration. Does NOT seed `highlightDraftStart`
    /// — that happens when the user actually taps the timeline, so the
    /// band only appears once they've chosen a position.
    func setHighlightDuration(_ seconds: Double) {
        let cleaned = seconds.isFinite ? max(seconds, 0.5) : 0.5
        highlightDraftDuration = cleaned
    }

    /// Called once when Highlight mode is entered. Seeds the duration
    /// from the current "Seconds per clip" default.
    /// Does NOT seed `highlightDraftStart` — that should only happen
    /// when the user actually taps the timeline, so the band doesn't
    /// appear "pre-existing" the moment they enter Highlight mode.
    func enterHighlightMode() {
        highlightDraftDuration = Double(defaultSegmentLength)
        // Clear any leftover draft from the previous session so the
        // timeline reads as empty until the user takes action.
        highlightDraftStart = nil
    }

    /// Body-drag (slide the band along the timeline). Snaps to frame
    /// boundaries and clamps to source bounds.
    func moveHighlightDraft(toStart newStart: Double) {
        guard let draft = highlightDraft,
              let total = durationSeconds,
              total > 0
        else { return }
        let width = draft.endSeconds - draft.startSeconds
        let clamped = min(max(newStart, 0), max(0, total - width))
        highlightDraftStart = clamped
    }

    /// Edge-drag (resize by moving the left or right edge). `delta` is in
    /// seconds; positive widens, negative narrows.
    func resizeHighlightDraft(leftEdgeDelta delta: Double) {
        guard highlightDraftStart != nil,
              let total = durationSeconds,
              total > 0
        else { return }
        let current = highlightDraftDuration
        let proposed = current + delta
        let maxAllowed = total - (highlightDraftStart ?? 0)
        let minAllowed: Double = 0.5
        highlightDraftDuration = min(max(proposed, minAllowed), maxAllowed)
    }

    /// Set the draft's start time directly (left-edge drag). The end
    /// follows, keeping the current duration. Clamped so the band stays
    /// inside the source and at least 0.5s wide.
    func setHighlightStart(_ newStart: Double) {
        guard let total = durationSeconds, total > 0 else { return }
        let minStart: Double = 0
        let maxStart = max(0, total - highlightDraftDuration)
        let clamped = min(max(newStart, minStart), maxStart)
        highlightDraftStart = clamped
    }

    /// Set the draft's end time directly (right-edge drag). The start
    /// stays put, the duration follows. Clamped similarly.
    func setHighlightEnd(_ newEnd: Double) {
        guard let total = durationSeconds, total > 0,
              let start = highlightDraftStart
        else { return }
        let minEnd = start + 0.5
        let maxEnd = total
        let clampedEnd = min(max(newEnd, minEnd), maxEnd)
        highlightDraftDuration = clampedEnd - start
    }

    /// Append the current draft to `plannedRanges` as a new clip. Persists
    /// and auto-advances the draft start to the end of the just-added clip
    /// so the user can immediately grab the next segment without
    /// re-positioning (typical workflow: walk left-to-right slicing the
    /// video). Tapping "Add" again after the band reaches the end resets
    /// to 0.
    func addHighlightDraftToPlan() {
        guard let total = durationSeconds, total > 0 else {
            statusMessage = "Pick a video first."
            return
        }
        // No draft yet? Drop one at the current playhead so the user
        // doesn't have to position it before committing. This is the
        // happy path: scrub → set duration → add.
        if highlightDraft == nil {
            let pos = scrubPositionSeconds.isFinite ? scrubPositionSeconds : 0
            let width = highlightDraftDuration
            let start = min(max(pos, 0), max(0, total - width))
            highlightDraftStart = start
        }
        guard let draft = highlightDraft else {
            statusMessage = "Couldn't place a highlight there."
            return
        }
        let snapped = ClipRangeEditor.updatedRange(
            draft,
            totalDuration: total,
            frameDuration: frameDurationSeconds
        )
        // Reject the add if it overlaps an existing planned range —
        // overlapping ranges stack their handle hit-zones on top of each
        // other and one becomes unselectable.
        for existing in plannedRanges {
            if snapped.startSeconds < existing.endSeconds && snapped.endSeconds > existing.startSeconds {
                statusMessage = "That overlaps an existing clip — move the highlight to an empty part."
                return
            }
        }
        plannedRanges.append(snapped)
        clips = []
        let nextStart = snapped.endSeconds
        if nextStart < total - 0.5 {
            highlightDraftStart = nextStart
        } else {
            // Reached the end — clear the draft so the user explicitly
            // picks the next spot.
            highlightDraftStart = nil
        }
        statusMessage = "Added clip \(plannedRanges.count) to the plan."
        persistCurrentProject()
    }

    /// Discard the draft without adding to the plan.
    func clearHighlightDraft() {
        highlightDraftStart = nil
    }

    /// Reset the draft to start at 0 with the current duration. Used when
    /// switching between modes or when the source video changes.
    func resetHighlightDraft() {
        highlightDraftStart = scrubPositionSeconds > 0 ? scrubPositionSeconds : 0
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
            thumbnailCache.removeValue(forKey: project.id)

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

    /// Rename a project from the library list (Home screen context menu).
    /// Empty input falls back to the source filename so we never persist a
    /// blank title. If the project being renamed is also the currently open
    /// one, the live `projectTitleDraft` is kept in sync so the ClipView
    /// header text updates immediately.
    func renameStoredProject(id: UUID, to newTitle: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if trimmed.isEmpty {
            resolved = Self.defaultProjectTitle(for: projects[index].sourceURL)
        } else {
            resolved = trimmed
        }

        guard projects[index].title != resolved else { return }

        var project = projects[index]
        project.title = resolved
        project.updatedAt = Date()
        projects[index] = project

        do {
            projects = try projectStore.upsert(project)
            if currentProjectID == id {
                projectTitleDraft = resolved
            }
            statusMessage = "Project renamed to \(resolved)."
            PolishKit.Haptics.selection.play()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not rename project."
        }
    }

    func cachedThumbnail(for id: UUID) -> UIImage? {
        thumbnailCache[id]
    }

    @MainActor
    func loadThumbnail(id: UUID, url: URL, midpointSeconds: Double = 0, maximumSize: CGSize = CGSize(width: 320, height: 320)) async {
        guard thumbnailCache[id] == nil else { return }

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("⚠️ loadThumbnail: source file missing at \(url.path)")
            // Fall back to the source video's closest thumbnail so the
            // card shows a frame instead of a blank film icon.
            if let fallback = sourceThumbnails.min(by: { abs($0.timeSeconds - midpointSeconds) < abs($1.timeSeconds - midpointSeconds) }) {
                thumbnailCache[id] = fallback.image
            }
            return
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        let target = CMTime(seconds: midpointSeconds, preferredTimescale: 600)

        do {
            let (cgImage, _) = try await generator.image(at: target)
            let image = UIImage(cgImage: cgImage)
            thumbnailCache[id] = image
        } catch {
            print("⚠️ loadThumbnail: image extraction failed for \(id) — \(error.localizedDescription)")
            // Fall back to source thumbnail if extraction fails.
            if let fallback = sourceThumbnails.min(by: { abs($0.timeSeconds - midpointSeconds) < abs($1.timeSeconds - midpointSeconds) }) {
                thumbnailCache[id] = fallback.image
            }
            return
        }
    }

    func prepareCuts() {
        guard let sourceURL, let segmentLength = parsedSegmentLength else {
            errorMessage = "Enter a segment length of at least 1 second."
            return
        }

        // Headroom guard: a recipe with explicit count + duration on a source
        // shorter than one clip should fail loudly, not silently clamp to zero
        // ranges. Catch it before any work is dispatched.
        if cutMode == .fixed, recipeHasNoHeadroom,
           let durationSeconds, durationSeconds > 0 {
            errorMessage = "Source is shorter than one clip. Trim a clip ≤ \(Int(durationSeconds))s, shorten the source, or switch to Highlight."
            statusMessage = "Recipe needs more source than is available."
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
                    let queryRanges: [ClipRange]? = effectiveFixedQuery.map { q in
                        ClipQuery(
                            count: q.count,
                            durationSeconds: q.durationSeconds,
                            intervalSeconds: q.intervalSeconds
                        ).ranges(forSourceDuration: durationSeconds)
                    }
                    if let queryRanges, !queryRanges.isEmpty {
                        // Natural language parsed query takes precedence over the
                        // numeric stepper when it produces actual cuts.
                        ranges = queryRanges
                    } else {
                        ranges = try Self.fixedRanges(
                            totalDuration: durationSeconds,
                            segmentLength: segmentLength,
                            frameDuration: frameDurationSeconds,
                            tier: currentTier
                        )
                    }
                case .highlight:
                    // Highlight mode is fully manual — the user picks
                    // positions/durations on the timeline themselves. We do
                    // NOT auto-detect anything here; the planned ranges are
                    // whatever the user has already added via the "Add to
                    // plan" affordance. If they haven't added any yet, this
                    // is a no-op.
                    ranges = plannedRanges
                }

                try Task.checkCancellation()

                let duration: Double
                if let durationSeconds {
                    duration = durationSeconds
                } else {
                    duration = try await segmenter.duration(for: sourceURL)
                }
                try MediaProcessingLimits.validateSourceDuration(duration, for: currentTier)
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
        // Convenience: if clips are already rendered (re-opening a project), skip
        // the preview step and save straight to Photos. New exports go through
        // prepareExport() instead so the user can review first.
        guard !clips.isEmpty else {
            prepareExport()
            return
        }
        confirmPendingExport()
    }

    /// Step 1 of the save flow: render the planned ranges to a temp directory and
    /// surface the results in a preview sheet. The user must confirm before anything
    /// touches the photo library.
    func prepareExport() {
        guard let sourceURL else {
            errorMessage = "Choose a video first."
            return
        }
        guard !plannedRanges.isEmpty else {
            errorMessage = "Analyze cuts before exporting."
            return
        }

        processingTask?.cancel()
        // Studio priority: schedule the entire render-and-save flow at
        // `.background` QoS so the system runs us ahead of creator/free
        // renders, with an extra 30s of background-time grace.
        let exportPriority = ExportBackgroundTaskManager.exportQoS(for: currentTier)
        processingTask = Task(priority: exportPriority) { [weak self] in
            guard let self else { return }

            processingPhase = .exporting
            progress = 0
            errorMessage = nil
            statusMessage = "Rendering clips for preview..."
            let exportProjectTitle = currentProjectTitle
            await exportNotifications.prepareForExportNotifications()
            exportBackgroundTasks.beginExportTask(named: "ReelClip Preview") { [weak self] in
                self?.processingTask?.cancel()
                self?.statusMessage = "Preview stopped while the app was in the background."
            }
            defer {
                exportBackgroundTasks.endExportTask()
            }

            do {
                guard let durationSeconds else {
                    throw VideoSegmenterError.invalidDuration
                }
                try MediaProcessingLimits.validateSourceDuration(durationSeconds, for: currentTier)
                let safeRanges = try MediaProcessingLimits.validatedClipPlan(
                    plannedRanges,
                    totalDuration: durationSeconds,
                    frameDuration: frameDurationSeconds
                )
                let renderedClips = try await segmenter.segmentVideo(
                    sourceURL: sourceURL,
                    ranges: safeRanges,
                    clipTitles: clipTitlesForCurrentPlan(),
                    tier: currentTier
                ) { [weak self] value in
                    self?.progress = value
                }

                try Task.checkCancellation()

                pendingExportClips = renderedClips
                processingPhase = .idle
                statusMessage = "Review \(renderedClips.count) clip\(renderedClips.count == 1 ? "" : "s") before saving."
                isShowingExportPreview = true
            } catch is CancellationError {
                statusMessage = "Preview cancelled."
            } catch VideoSegmenterError.cancelled {
                statusMessage = "Preview cancelled."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Could not render clips."
                await exportNotifications.notifyExportFailed(
                    projectTitle: exportProjectTitle,
                    message: error.localizedDescription
                )
            }

            processingPhase = .idle
            processingTask = nil
        }
    }

    /// Step 2 of the save flow: commit the rendered clips to the photo library.
    func confirmPendingExport() {
        guard let pending = pendingExportClips, !pending.isEmpty else {
            isShowingExportPreview = false
            return
        }
        let exportProjectTitle = currentProjectTitle

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }

            processingPhase = .saving
            statusMessage = "Saving clips to Photos..."
            isShowingExportPreview = false

            do {
                let photoLibraryIdentifiers = try await segmenter.saveToPhotoLibrary(pending) { [weak self] value in
                    self?.progress = value
                }
                let saved = pending.map { clip in
                    clip.withPhotoLibraryLocalIdentifier(photoLibraryIdentifiers[clip.id])
                }
                clips = saved
                pendingExportClips = nil
                statusMessage = "Saved \(saved.count) clips to Photos. Tap a clip to share."
                await exportNotifications.notifyExportCompleted(
                    clipCount: saved.count,
                    projectTitle: exportProjectTitle
                )
                persistCurrentProject()
            } catch is CancellationError {
                statusMessage = "Save cancelled."
            } catch VideoSegmenterError.cancelled {
                statusMessage = "Save cancelled."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Could not save to Photos."
                await exportNotifications.notifyExportFailed(
                    projectTitle: exportProjectTitle,
                    message: error.localizedDescription
                )
            }

            processingPhase = .idle
            processingTask = nil
        }
    }

    /// Step 2 alt: discard the rendered clips without saving.
    func cancelPendingExport() {
        if let pending = pendingExportClips, !pending.isEmpty {
            // Reap the temp files the segmenter produced.
            mediaWorkspace.removeDirectories(for: pending)
        }
        pendingExportClips = nil
        isShowingExportPreview = false
        statusMessage = "Preview cancelled."
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

        // Apply the user's persisted clip defaults so a fresh project starts in the right state.
        cutMode = defaultCutMode
        segmentLengthText = "\(defaultSegmentLength)"
    }

    func resetClipDefaults() {
        userDefaultsStore.resetAll()
        defaultCutMode = userDefaultsStore.defaultCutMode
        defaultSegmentLength = userDefaultsStore.defaultSegmentLengthSeconds
        // Reset in-session cut recipe state too — mode, segment length,
        // highlight draft, fixed-mode buttons/prompt all back to their
        // defaults so the user gets a clean slate.
        cutMode = defaultCutMode
        segmentLengthText = "\(defaultSegmentLength)"
        highlightDraftStart = nil
        fixedModeQueryDraft = ""
        fixedModeInputStyle = .buttons
        fixedModeButtonCount = 4
        plannedRanges = []
        clips = []
        statusMessage = "Cut recipe reset to defaults."
        persistCurrentProject()
    }

    private func cancelPreviewLoading() {
        previewTask?.cancel()
        waveformTask?.cancel()
    }

    private var analysisStatusMessage: String {
        switch cutMode {
        case .fixed:
            return "Planning fixed clips..."
        case .highlight:
            return "Ready — drag the highlight on the timeline."
        }
    }

    private func loadVideo(from item: PhotosPickerItem) async {
        processingPhase = .loading
        progress = 0
        resetLoadedMediaState(keepSource: false)
        errorMessage = nil
        statusMessage = "Loading video..."

        // Capture the PHAsset localIdentifier before the transferable
        // load — this is the identifier we write into `.reelclip`
        // export files so the recipient can resolve the source video.
        let photoId = item.photoLibraryLocalIdentifier

        do {
            guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
                statusMessage = "Choose a valid video file."
                processingPhase = .idle
                return
            }

            // PhotosPicker hands us a temp file URL the system may purge at any time.
            // Copy into the persistent workspace so the project's sourcePath stays
            // valid across launches — otherwise thumbnails + waveform + preview all
            // break the next time the temp file is reaped.
            let copiedURL = try mediaWorkspace.importSourceCopy(from: video.url)
            try await setLoadedVideo(url: copiedURL)
            // Persist the PHAsset identifier so it's available when
            // the project is exported to a `.reelclip` file. Prefer
            // the identifier from the PhotosPickerItem (most reliable);
            // fall back to the one from PickedVideo (set by the
            // transferable import, currently always nil).
            sourcePhotoLibraryIdentifier = photoId ?? video.photoLibraryLocalIdentifier
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
            sourcePhotoLibraryIdentifier = nil
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
        // Seed the editable title with the source filename fallback the first
        // time a video is imported. The user can rename it inline; an empty
        // title is coerced to this same fallback at persist time.
        if projectTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            projectTitleDraft = Self.defaultProjectTitle(for: url)
        }
        let duration = try await segmenter.duration(for: url)
        try MediaProcessingLimits.validateSourceDuration(duration, for: currentTier)
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
            try MediaProcessingLimits.validateSourceDuration(project.durationSeconds, for: currentTier)
        } catch {
            processingPhase = .idle
            errorMessage = error.localizedDescription
            statusMessage = "Could not open project."
            return
        }

        resetLoadedMediaState(keepSource: false)
        currentProjectID = project.id
        projectTitleDraft = project.title
        sourceURL = project.sourceURL
        durationSeconds = project.durationSeconds
        cutMode = project.cutMode
        segmentLengthText = project.segmentLengthText
        // Restore the cached PHAsset identifier so the project
        // can be re-exported with the source reference intact.
        sourcePhotoLibraryIdentifier = project.sourcePhotoLibraryIdentifier
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

    func persistCurrentProject() {
        guard let sourceURL, let durationSeconds else { return }

        let now = Date()
        let projectID = currentProjectID ?? UUID()
        let existingProject = projects.first { $0.id == projectID }
        let project = MediaProject(
            id: projectID,
            title: resolveProjectTitleForPersistence(existingTitle: existingProject?.title, sourceURL: sourceURL),
            sourcePath: sourceURL.standardizedFileURL.path,
            sourceFileName: sourceURL.lastPathComponent,
            durationSeconds: durationSeconds,
            sourceAspectRatio: Self.safeAspectRatio(sourceAspectRatio),
            frameDurationSeconds: Self.safeFrameDuration(frameDurationSeconds),
            cutMode: cutMode,
            segmentLengthText: segmentLengthText,
            plannedRanges: plannedRanges,
            exportedClips: clips
                .filter { isClipShareable($0) }
                .map(StoredClipOutput.init(clip:)),
            scrubPositionSeconds: Self.clampedSeconds(scrubPositionSeconds, duration: durationSeconds),
            sourcePhotoLibraryIdentifier: sourcePhotoLibraryIdentifier,
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

    // MARK: - .reelclip project export / import
    //
    // Projects are persisted internally in `~/Library/Application Support/`
    // which iOS wipes on app uninstall. To make projects portable — across
    // reinstalls, devices, and other users — we expose Export/Import via
    // the `.reelclip` file type. The file is a small JSON snapshot; the
    // source video stays in Photos (referenced by PHAsset localIdentifier).
    //
    // Export writes to a temp URL the caller hands to UIDocumentPicker in
    // `.forExporting` mode. Import reads a URL the caller got from the
    // picker in `.forOpeningContentTypes: [.reelclip]` mode (or from the
    // Files app via ReelClipProjectURLRouter).

    /// Build a temp file URL containing the current project's `.reelclip`
    /// snapshot. Caller is expected to hand this URL to a document
    /// picker for export, then delete the temp file when done.
    /// Returns nil if there is no active project to export.
    func exportCurrentProjectToTemporaryFile() throws -> (url: URL, suggestedName: String) {
        guard let projectID = currentProjectID,
              let project = projects.first(where: { $0.id == projectID }) else {
            throw NSError(domain: "VideoSplitterViewModel", code: 100,
                          userInfo: [NSLocalizedDescriptionKey: "Open or create a project before exporting."])
        }
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"

        // Look up the PHAsset to populate sourceOriginalFilename +
        // sourceFileSize in the export file. The localIdentifier
        // is cached on the viewmodel when the user picks a video.
        var sourceAsset: PHAsset?
        var sourceFileSize: Int64?
        if let photoId = project.sourcePhotoLibraryIdentifier ?? sourcePhotoLibraryIdentifier {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil)
            if let asset = fetchResult.firstObject {
                sourceAsset = asset
                let pw = asset.pixelWidth
                let ph = asset.pixelHeight
                let dur = asset.duration.rounded(.up)
                if pw > 0 && ph > 0 && dur > 0 {
                    sourceFileSize = Int64(pw) * Int64(ph) * Int64(dur) * 15
                }
            }
        }

        let data = try ReelClipProjectCodec.encode(
            project,
            sourceAsset: sourceAsset,
            sourceFileSize: sourceFileSize,
            appVersion: appVersion
        )
        let safeName = FilenameSanitizer.sanitize(
            project.title.trimmingCharacters(in: .whitespacesAndNewlines),
            fallback: "Untitled"
        )
        let filename = "\(safeName).reelclip"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: tempURL, options: [.atomic])
        return (tempURL, filename)
    }

    /// Ingest a project produced by either the document-picker Import
    /// button or the URL router. Stores the project and (if the source
    /// was resolved) opens it for editing.
    func setStatusMessage(_ text: String) {
        statusMessage = text
    }

    func ingestImportedProject(_ result: ReelClipImportResult) {
        // Cache the source PHAsset identifier so subsequent exports
        // from this imported project still carry the source reference.
        sourcePhotoLibraryIdentifier = result.project.sourcePhotoLibraryIdentifier
        do {
            projects = try projectStore.upsert(result.project)
        } catch {
            errorMessage = "Couldn't save imported project: \(error.localizedDescription)"
            return
        }
        switch result.sourceResolution {
        case .resolvedViaPhotos(let url, _),
             .resolvedViaFilename(let url, _):
            // Source is ready — open it for editing.
            currentProjectID = result.project.id
            openProject(result.project)
            // The openProject flow expects `sourceURL`; the loadProject
            // async task re-reads it from `result.project.sourceURL`. We
            // also clear any leftover source so the UI doesn't double-
            // render the previous clip.
            _ = url
        case .missing:
            // Source missing — keep the project but don't auto-open.
            // UI shows a "source missing" banner from the statusMessage
            // set by the router. The user can re-pick a video to link
            // the planned ranges.
            statusMessage = "Imported \"\(result.project.title)\" — pick a replacement video to start editing."
            currentProjectID = result.project.id
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
        frameDuration: Double,
        tier: SubscriptionStore.Tier
    ) throws -> [ClipRange] {
        try MediaProcessingLimits.validateSourceDuration(totalDuration, for: tier)
        let minimumDuration = min(minimumFixedClipDuration(segmentLength: segmentLength), totalDuration)
        let ranges = ClipRangeEditor.equalRanges(
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
