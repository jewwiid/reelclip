import AVFoundation
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit

enum CutMode: String, CaseIterable, Identifiable, Codable {
    case highlight = "Highlight"
    case fixed = "Fixed"
    case smartPause = "Smart Pause"
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

/// What to render when the user taps Export. The chooser surfaces
/// these as a confirmation dialog before kicking off the render.
/// The default is `.activeScene` (preserves the pre-Phase-5 flow:
/// render the active scene's full planned range list). `.activeRecipe`
/// renders only the active scene's ranges for the current cut mode. `.allScenes`
/// iterates every scene in the project and renders each one with
/// its own source (skipping scenes whose source file is missing),
/// then concatenates the resulting clip lists into a single
/// preview sheet so the user can review them all together.
enum ExportTarget: Hashable {
    case activeRecipe
    case activeScene
    case specificScene(UUID)
    case allScenes
}

enum SceneSourceReplacementPlanAction {
    case keep
    case clamp
    case clear
}

struct SkippedSceneExport: Identifiable, Equatable, Hashable {
    var id: String { "\(sceneName)|\(reason)" }
    let sceneName: String
    let reason: String

    var displayText: String {
        "\(sceneName): \(reason)"
    }
}

@MainActor
final class VideoSplitterViewModel: ObservableObject, ReelClipProjectImportSink {
    @Published var selectedItem: PhotosPickerItem?
    @Published private(set) var isImportingMedia = false
    @Published var sourceURL: URL? {
        didSet {
            if sourceURL == nil, oldValue != nil {
                resetPlaybackMedia()
            }
        }
    }
    @Published private(set) var playbackURL: URL?
    @Published private(set) var isGeneratingProxy = false
    @Published private(set) var proxyGenerationProgress = 0.0
    @Published var durationSeconds: Double?
    @Published var cutMode: CutMode = .highlight {
        willSet { invalidateShuffle() }
    }
    @Published var segmentLengthText = "30"
    @Published var editPrompt = "Make a fast reel"
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
    @Published var plannedRanges: [ClipRange] = [] {
        willSet { invalidateShuffle() }
    }
    @Published var scenes: [MediaProjectScene] = [] {
        willSet { invalidateShuffle() }
    }

    /// User-controlled permutation of the planned-clips list for the
    /// CURRENT flat export. Indices map into the canonical flat list
    /// built by `orderedFlatExportClips`; `nil` means "no shuffle" —
    /// render in scene order. In-memory only (not persisted to the
    /// project file): the user's shuffled order is a per-session
    /// experiment; reopening the project always starts in canonical
    /// order. Adding / removing a clip, or switching cut mode, clears
    /// the shuffle because the canonical indices shift.
    @Published var shuffledOrder: [Int]? = nil
    @Published var draggingProjectExportIndex: Int? = nil
    @Published var projectExportDragTargetIndex: Int? = nil

    /// The subset of `plannedRanges` that match the current `cutMode`.
    /// This is the single source of truth for "what's the user working on
    /// right now": the timeline preview, the planned-clips list, the
    /// header count, and the export flow all use this. Ranges planned
    /// in other modes are still in `plannedRanges` (preserved for
    /// mode-switch round trips) but invisible until the user switches
    /// back to the mode they were planned in.
    ///
    /// Fixed mode is special: when there's a valid natural-language
    /// query the user is editing, the query ranges take precedence
    /// over the stored fixed ranges — the timeline reads as "what
    /// would the cut be if I tap Plan now". Mirrors `liveTimelineRanges`
    /// in ClipView so the two never disagree.
    var visiblePlannedRanges: [ClipRange] {
        switch cutMode {
        case .fixed:
            if let duration = durationSeconds {
                let ranges = fixedModeRanges(forSourceDuration: duration)
                if !ranges.isEmpty { return ranges }
            }
            return plannedRanges.filter { $0.cutMode == .fixed }
        case .highlight:
            return plannedRanges.filter { $0.cutMode == .highlight }
        case .smartPause:
            return plannedRanges.filter { $0.cutMode == .smartPause }
        case .aiAssist:
            return plannedRanges.filter { $0.cutMode == .aiAssist }
        }
    }

    var plannedRangesForCurrentMode: [ClipRange] {
        plannedRanges.filter { $0.cutMode == cutMode }
    }

    /// The explicit scope for an audio or Apple Intelligence pass. Curated
    /// ranges win over the live highlight draft; with neither present, the
    /// analyzer is intentionally allowed to inspect the full source.
    var selectedAnalysisRanges: [ClipRange] {
        let curated = plannedRangesForCurrentMode
        if !curated.isEmpty {
            return curated
        }
        if let highlightDraft {
            return [highlightDraft]
        }
        return []
    }

    /// Human-readable scope for the next Silence or AI pass. Keeping this
    /// beside `selectedAnalysisRanges` prevents the recipe UI from implying
    /// that a stale highlight or a previous mode's plan is being ignored.
    var analysisScopeLabel: String {
        let ranges = selectedAnalysisRanges
        guard !ranges.isEmpty else { return "Whole source" }
        return ranges.count == 1
            ? "Highlighted range"
            : "\(ranges.count) selected clips"
    }

    var smartPauseRecipeDetail: String {
        switch transcriptState {
        case .ready:
            return "Uses transcript timing to keep spoken sections and remove silent gaps."
        case .processing:
            return "Transcript is processing. Audio detection is ready as a fallback."
        case .failed, .idle:
            return "Detects voice and audible sections, then removes silent gaps."
        }
    }

    // MARK: - Shuffle (per-session, in-memory only)

    typealias FlatExportClip = (sceneIndex: Int, clipIndex: Int, scene: MediaProjectScene, range: ClipRange, sourceURL: URL?)

    /// Flat list of clips across all scenes and all recipes, in
    /// canonical (scene-then-clip) order. Used
    /// both for the planned-clips section display and the export
    /// loop when the user has chosen a shuffle order. Each entry
    /// knows its source scene + index in the scene, so the export
    /// loop can render it using that scene's source URL even when
    /// the order is cross-scene.
    ///
    /// Single-scene case: identical to the active scene's full
    /// `plannedRanges` mapped to a flat list (one scene, N clips).
    /// Multi-scene case:
    /// one entry per clip, ordered by scene then by plannedRanges
    /// order within the scene.
    var flatExportClips: [FlatExportClip] {
        var result: [FlatExportClip] = []
        for (sceneIndex, scene) in scenes.enumerated() {
            for (clipIndex, range) in scene.plannedRanges.enumerated() {
                result.append((sceneIndex, clipIndex, scene, range, scene.sourceURL ?? sourceURL))
            }
        }
        return result
    }

    /// Same as `flatExportClips` but in the user-chosen shuffled order
    /// when `shuffledOrder != nil`. When shuffled, this can interleave
    /// clips from different scenes — the export loop iterates this and
    /// renders each clip using its own scene's source URL.
    var orderedFlatExportClips: [FlatExportClip] {
        let flat = flatExportClips
        guard let order = shuffledOrder, order.count == flat.count else {
            return flat
        }
        // Validate indices — if any are out of bounds, fall back to canonical
        let valid = order.allSatisfy { $0 >= 0 && $0 < flat.count }
        guard valid else { return flat }
        return order.map { flat[$0] }
    }

    /// True when the user has explicitly chosen a shuffled order
    /// (separate from `shuffledOrder != nil` so the UI can ignore
    /// an in-flight empty shuffle).
    var isShuffled: Bool {
        guard let order = shuffledOrder else { return false }
        return order.count == flatExportClips.count && !order.isEmpty
    }

    /// Reshuffle. Each call gives a different order (SystemRandomNumberGenerator
    /// is unseeded per call). No-op when there's 0 or 1 clips — nothing
    /// to reshuffle.
    func shufflePlannedClips() {
        let flat = flatExportClips
        guard flat.count > 1 else { return }
        let indices = Array(0..<flat.count)
        shuffledOrder = indices.shuffled()
    }

    /// Reset to canonical scene order.
    func resetShuffle() {
        shuffledOrder = nil
    }

    func reorderProjectExportClips(from source: Int, to destination: Int) {
        let flat = flatExportClips
        guard flat.indices.contains(source),
              flat.indices.contains(destination),
              source != destination else { return }

        var order: [Int]
        if let current = shuffledOrder,
           current.count == flat.count,
           current.allSatisfy({ flat.indices.contains($0) }) {
            order = current
        } else {
            order = Array(flat.indices)
        }

        let moving = order.remove(at: source)
        order.insert(moving, at: min(destination, order.count))
        shuffledOrder = order
    }

    func flatExportClips(for target: ExportTarget) -> [FlatExportClip] {
        switch target {
        case .activeRecipe:
            guard let activeIndex = activeSceneIndex else { return [] }
            let scene = scenes[activeIndex]
            return scene.plannedRanges.enumerated().compactMap { clipIndex, range in
                guard range.cutMode == cutMode else { return nil }
                return (activeIndex, clipIndex, scene, range, scene.sourceURL ?? sourceURL)
            }
        case .activeScene:
            guard let activeIndex = activeSceneIndex else { return [] }
            let scene = scenes[activeIndex]
            return scene.plannedRanges.enumerated().map { clipIndex, range in
                (activeIndex, clipIndex, scene, range, scene.sourceURL ?? sourceURL)
            }
        case .specificScene(let id):
            guard let sceneIndex = scenes.firstIndex(where: { $0.id == id }) else { return [] }
            let scene = scenes[sceneIndex]
            return scene.plannedRanges.enumerated().map { clipIndex, range in
                (sceneIndex, clipIndex, scene, range, scene.sourceURL ?? sourceURL)
            }
        case .allScenes:
            return orderedFlatExportClips
        }
    }

    private var activeSceneIndex: Int? {
        let activeId = activeSceneId ?? scenes.first?.id
        guard let activeId else { return nil }
        return scenes.firstIndex { $0.id == activeId }
    }

    /// Called whenever clips are added / removed / mode-changed.
    /// Indices into the canonical list would shift, so a stored
    /// shuffle becomes meaningless. Centralised so the viewModel
    /// doesn't have to remember to clear in every mutation path.
    func invalidateShuffle() {
        guard shuffledOrder != nil else { return }
        shuffledOrder = nil
    }

    // MARK: - Per-clip edit (delete / replace) during ongoing edits

    /// Index into `plannedRanges` that the next "Add" should
    /// overwrite instead of appending. Set by the per-clip row's
    /// "Replace with…" context menu, cleared when the user picks
    /// a recipe to run, picks Cancel, or commits another non-replace
    /// action (long-press / batch clear). Persisted only as long as
    /// the session — replacing a clip doesn't survive app
    /// restarts, since reopening the project lands the user on the
    /// canonical list.
    @Published var replacingPlannedRangeIndex: Int? = nil

    /// Drop a single planned range. Indices come from the same
    /// `clipRangeRow(index:)` callback that hands them to the
    /// `EditableClipRangeBar`, so the global index lines up with
    /// what the user sees on screen. Re-uses `invalidateShuffle`
    /// so any in-progress planned-clips reshuffle gets reset on
    /// mutation — same contract as the existing recipe Add.
    func removePlannedRange(atIndex index: Int) {
        guard plannedRanges.indices.contains(index) else { return }
        plannedRanges.remove(at: index)
        if replacingPlannedRangeIndex == index { replacingPlannedRangeIndex = nil }
        clips = []
        invalidateShuffle()
        persistCurrentProject()
    }

    func clearPlannedRangesForCurrentMode() {
        let before = plannedRanges.count
        plannedRanges.removeAll { $0.cutMode == cutMode }
        guard plannedRanges.count != before else { return }
        replacingPlannedRangeIndex = nil
        clips = []
        invalidateShuffle()
        statusMessage = "Cleared \(cutMode.rawValue.lowercased()) planned clips."
        persistCurrentProject()
    }

    func removeProjectExportClip(sceneID: UUID, clipIndex: Int) {
        let activeId = activeSceneId ?? scenes.first?.id

        if sceneID == activeId {
            guard plannedRanges.indices.contains(clipIndex) else { return }
            plannedRanges.remove(at: clipIndex)
            if replacingPlannedRangeIndex == clipIndex {
                replacingPlannedRangeIndex = nil
            } else if let replacingPlannedRangeIndex, replacingPlannedRangeIndex > clipIndex {
                self.replacingPlannedRangeIndex = replacingPlannedRangeIndex - 1
            }
        } else if let sceneIndex = scenes.firstIndex(where: { $0.id == sceneID }) {
            guard scenes[sceneIndex].plannedRanges.indices.contains(clipIndex) else { return }
            scenes[sceneIndex].plannedRanges.remove(at: clipIndex)
        } else {
            guard plannedRanges.indices.contains(clipIndex) else { return }
            plannedRanges.remove(at: clipIndex)
        }

        clips = []
        invalidateShuffle()
        statusMessage = "Removed clip from project export."
        persistCurrentProject()
    }

    func clearProjectExportPlan() {
        let hasProjectClips = !plannedRanges.isEmpty || scenes.contains { !$0.plannedRanges.isEmpty }
        guard hasProjectClips else { return }

        plannedRanges = []
        for index in scenes.indices {
            scenes[index].plannedRanges = []
        }
        replacingPlannedRangeIndex = nil
        clips = []
        invalidateShuffle()
        statusMessage = "Cleared project export preview."
        persistCurrentProject()
    }

    /// Begin a "replace this clip" flow. Doesn't mutate the
    /// planned list yet — the actual swap happens inside
    /// `addRecipeToPlannedAndReset()` once the recipe run completes,
    /// so the user can change their mind mid-recipe by tapping Cancel.
    /// Setting `replacingPlannedRangeIndex` is what flips the
    /// preview banner on.
    func beginReplacingPlannedRange(atIndex index: Int) {
        guard plannedRanges.indices.contains(index) else { return }
        guard plannedRanges[index].cutMode == cutMode else {
            // Replacing a Fixed clip from Silence mode would be
            // confusing (the row in the planned list belongs to a
            // different tab). The current-mode guard makes the
            // UX match the row the user just tapped. Cross-mode
            // replace would need its own picker sheet.
            return
        }
        replacingPlannedRangeIndex = index
    }

    /// User changed their mind on the replace flow. Clears the
    /// pending index without touching `plannedRanges`.
    func cancelReplace() {
        replacingPlannedRangeIndex = nil
    }

    /// Swap a planned range in place. Used by the recipe Add path
    /// when `replacingPlannedRangeIndex` is set, and also exposed
    /// to the view layer for any future single-row edit surfaces.
    /// Bounds-checked so out-of-range indices are no-ops rather
    /// than crashes.
    func replacePlannedRange(atIndex index: Int, with replacement: ClipRange) {
        guard plannedRanges.indices.contains(index) else { return }
        let stamped = ClipRange(
            startSeconds: replacement.startSeconds,
            endSeconds: replacement.endSeconds,
            reason: replacement.reason,
            isLocked: false,
            cutMode: cutMode
        )
        plannedRanges[index] = stamped
        invalidateShuffle()
        persistCurrentProject()
    }

    /// User-controlled permutation of the saved-clips list.
    /// Indices map into `savedClips`; `nil` means "no shuffle" —
    /// render in commit order. In-memory only (not persisted):
    /// the user re-saves to reset, or clears saved entirely. Kept
    /// separate from `shuffledOrder` so the planned-clips shuffle
    /// and the saved-clips shuffle are independent — committing
    /// the planned list to saved doesn't carry the planned-side
    /// order into the saved side.
    @Published var shuffledSavedClipsOrder: [Int]? = nil

    /// True when the user has explicitly chosen a shuffled order
    /// for the saved row. Mirrors the planned-side `isShuffled`
    /// contract so the saved section's shuffle button can render
    /// the same visual state.
    var isSavedClipsShuffled: Bool {
        guard let order = shuffledSavedClipsOrder else { return false }
        return order.count == savedClips.count && !order.isEmpty
    }

    /// Reshuffle the saved row. Each call gives a different order
    /// (`SystemRandomNumberGenerator` is unseeded per call). No-op
    /// when there's 0 or 1 saved clips.
    func shuffleSavedClips() {
        guard savedClips.count > 1 else { return }
        shuffledSavedClipsOrder = Array(0..<savedClips.count).shuffled()
    }

    /// Reset the saved row to the order it was committed in.
    func resetSavedClipsShuffle() {
        shuffledSavedClipsOrder = nil
    }

    /// Display-order for the saved-clips section. When the user
    /// has shuffled, walks the canonical `savedClips` via
    /// `shuffledSavedClipsOrder`; otherwise returns the canonical
    /// order as-is. The committed list itself is never mutated
    /// — shuffle is a per-session view transformation only, so
    /// re-saving always starts from the canonical commit order.
    var displayedSavedClips: [ClipRange] {
        guard let order = shuffledSavedClipsOrder, order.count == savedClips.count else {
            return savedClips
        }
        return order.compactMap { savedClips.indices.contains($0) ? savedClips[$0] : nil }
    }

    /// Called when the saved row is cleared via the trash button
    /// — the cached permutation would point past the end of the
    /// (now empty) list, so drop it. Re-saves overwrite the
    /// canonical list, so a stale shuffle from a previous save
    /// is also dropped on commit.
    func invalidateSavedClipsShuffle() {
        guard shuffledSavedClipsOrder != nil else { return }
        shuffledSavedClipsOrder = nil
    }

    /// Source row of an in-flight drag-reorder gesture within the
    /// active scene's planned-clips list. `nil` when no drag is
    /// happening. Survives row re-renders so the DropDelegate can
    /// read it on every `dropEntered` callback. Cleared by
    /// `performDrop` once the gesture commits.
    @Published var draggingClipIndex: Int? = nil

    /// Position the dragged row is currently hovering over.
    /// Updated by `dropEntered` as the user moves across rows, and
    /// cleared when the drop commits. Lets the destination row
    /// render a "drop here" highlight. Kept separate from
    /// `draggingClipIndex` (the source) so the lift and target
    /// effects don't fight each other mid-gesture.
    @Published var dragTargetIndex: Int? = nil

    /// Reorders the active recipe's planned clips. `source` and
    /// `destination` are positions in the current scene + current
    /// mode list — the same list `ClipView.displayedClipIndices`
    /// renders. Other modes remain in `plannedRanges` but keep
    /// their relative slots; only ranges whose `cutMode == cutMode`
    /// are permuted.
    func reorderPlannedClips(from source: Int, to destination: Int) {
        let visibleRawIndices = plannedRanges.indices.filter { plannedRanges[$0].cutMode == cutMode }
        guard visibleRawIndices.indices.contains(source),
              visibleRawIndices.indices.contains(destination),
              source != destination else { return }

        var currentModeRanges = visibleRawIndices.map { plannedRanges[$0] }
        let moving = currentModeRanges.remove(at: source)
        let insertionIndex = min(destination, currentModeRanges.count)
        currentModeRanges.insert(moving, at: insertionIndex)

        for (rawIndex, range) in zip(visibleRawIndices, currentModeRanges) {
            plannedRanges[rawIndex] = range
        }
        clips = []
        invalidateShuffle()
        persistCurrentProject()
    }

    /// Randomize only the active scene's current recipe list. This is
    /// intentionally separate from the project-wide export shuffle.
    func randomizePlannedClipsForCurrentMode() {
        let visibleRawIndices = plannedRanges.indices.filter { plannedRanges[$0].cutMode == cutMode }
        guard visibleRawIndices.count > 1 else {
            statusMessage = "Add at least two clips to randomize their order."
            return
        }

        var randomized = visibleRawIndices.map { plannedRanges[$0] }
        randomized.shuffle()
        for (rawIndex, range) in zip(visibleRawIndices, randomized) {
            plannedRanges[rawIndex] = range
        }

        clips = []
        replacingPlannedRangeIndex = nil
        invalidateShuffle()
        statusMessage = "Randomized \(randomized.count) planned clips."
        persistCurrentProject()
    }

    @Published var activeSceneId: UUID?
    /// Committed planned ranges. Snapshotted from the active
    /// scene's `plannedRanges` by the project-level "Save"
    /// action, and persisted into the project (and `.reelclip`
    /// files). Mirrors the post-render `clips: [SegmentOutput]`
    /// in spirit but stores un-rendered `ClipRange`s, so the
    /// saved row reflects what the user committed, not what
    /// the renderer produced. New in v2.0 — projects that
    /// predate the Save button decode with an empty array.
    @Published var savedClips: [ClipRange] = []
    @Published var clips: [SegmentOutput] = []
    @Published var projects: [MediaProject] = []
    @Published var isProjectBrowserVisible = true
    @Published private(set) var thumbnailCache: [UUID: UIImage] = [:]
    @Published var currentProjectID: UUID?
    /// User-picked export settings for the current project.
    /// Mirrors `currentProject?.exportSettings` (or a tier-appropriate
    /// default when no project is open or the project predates the
    /// settings feature). Mutating this updates the project on save.
    @Published var currentProjectExportSettings: ExportSettings = ExportSettings.defaults(for: .free)
    @Published var selectedAIProvider: AIProvider = .appleIntelligence
    @Published var pendingExportClips: [SegmentOutput]?
    @Published var pendingExportSceneLabels: [UUID: String] = [:]
    @Published var pendingExportMissingScenes: [SkippedSceneExport] = []
    @Published var exportTarget: ExportTarget = .activeScene
    @Published var transcript: Transcript?
    @Published var transcriptState: TranscriptState = .idle
    /// Output of the transcript-pane "Process" action. When non-nil,
    /// the export-preview sheet shows this single concatenated MP4
    /// instead of the planned-clip segmenter output. Cleared on
    /// dismiss + on every new source.
    @Published var tightenedClips: [SegmentOutput] = []
    @Published var tightenedKeptRanges: [ClipRange] = []
    @Published var tightenedSourceDuration: Double = 0
    @Published var tightenedTier: SubscriptionStore.Tier = .free
    @Published var tightenedFrameDuration: Double?
    @Published var showTightenedPreview: Bool = false
    private var transcriptTask: Task<Void, Never>?
    private var mediaImportTask: Task<Void, Never>?
    private var activeMediaImportID: UUID?
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
    /// downstream limit check (source duration, export preset, watermark,
    /// AI quota, transcript export).
    @Published private(set) var currentTier: SubscriptionStore.Tier = .free

    /// Free-tier AI plan usage this calendar month. Resets when
    /// `currentAITierPeriodStart` rolls into a new month.
    @Published private(set) var aiPlansThisMonth: Int = 0
    @Published private(set) var currentAITierPeriodStart: Date = AIUsagePeriodStore.startOfCurrentMonth()
    /// True after the user has used their free-tier quota this month.
    @Published private(set) var hasReachedFreeAIQuota: Bool = false
    @Published var defaultCutMode: CutMode {
        didSet { userDefaultsStore.defaultCutMode = defaultCutMode }
    }
    /// Per-mode default for Silence ("Smart Pause") clip length.
    /// Decoupled from `defaultAiClipDuration` so the user can set
    /// a short silence gap and a long AI run independently.
    @Published var defaultSilenceClipDuration: Int {
        didSet {
            userDefaultsStore.defaultSilenceClipDurationSeconds = defaultSilenceClipDuration
        }
    }
    /// Per-mode default for AI ("Apple Intelligence") clip
    /// length. Decoupled from `defaultSilenceClipDuration` for
    /// the same reason.
    @Published var defaultAiClipDuration: Int {
        didSet {
            userDefaultsStore.defaultAiClipDurationSeconds = defaultAiClipDuration
        }
    }
    @Published var defaultHighlightDuration: Int {
        didSet { userDefaultsStore.defaultHighlightDurationSeconds = defaultHighlightDuration }
    }
    @Published var defaultEditPrompt: String {
        didSet { userDefaultsStore.defaultEditPrompt = defaultEditPrompt }
    }
    @Published var defaultFixedModeInputStyle: FixedModeInputStyle {
        didSet { userDefaultsStore.defaultFixedModeInputStyle = defaultFixedModeInputStyle }
    }
    @Published var defaultFixedModeQueryDraft: String {
        didSet { userDefaultsStore.defaultFixedModeQueryDraft = defaultFixedModeQueryDraft }
    }
    @Published var defaultFixedModeButtonCount: Int {
        didSet { userDefaultsStore.defaultFixedModeButtonCount = defaultFixedModeButtonCount }
    }
    @Published var defaultFixedModeButtonDuration: Int {
        didSet { userDefaultsStore.defaultFixedModeButtonDuration = defaultFixedModeButtonDuration }
    }
    @Published var defaultFixedModeButtonInterval: Int {
        didSet { userDefaultsStore.defaultFixedModeButtonInterval = defaultFixedModeButtonInterval }
    }

    /// Per-mode default for the clip-length field that
    /// `segmentLengthText` represents. Picks AI vs Silence based
    /// on the requested mode. Fixed and Highlight modes don't
    /// use `segmentLengthText` and get the Silence value as a
    /// safe fallthrough — they'll never read it because their
    /// own controls ignore this property.
    func defaultSegmentLengthForMode(_ mode: CutMode) -> Int {
        switch mode {
        case .aiAssist:
            return defaultAiClipDuration
        case .fixed, .smartPause, .highlight:
            return defaultSilenceClipDuration
        }
    }
    /// True after the user has touched the Highlight "Clip length"
    /// control. Used to distinguish a deliberate highlight-duration
    /// edit from default seeding when entering Highlight mode.
    @Published private(set) var hasManualHighlightDuration: Bool = false
    @Published var fixedModeQueryDraft: String = ""
    @Published var fixedModeInputStyle: FixedModeInputStyle = .buttons
    @Published var fixedModeButtonCount: Int = 4
    @Published var fixedModeButtonDuration: Int = 5
    @Published var fixedModeButtonInterval: Int = 10
    @Published private(set) var fixedModeRandomDuration = false
    @Published private(set) var fixedModeRandomInterval = false
    @Published private(set) var fixedModeRandomDurationMinimum: Int = 1
    @Published private(set) var fixedModeRandomDurationMaximum: Int = 5
    @Published private(set) var fixedModeRandomIntervalMinimum: Int = 1
    @Published private(set) var fixedModeRandomIntervalMaximum: Int = 10
    @Published private var fixedModeRandomSeed: UInt64 = 0x9E3779B97F4A7C15

    var parsedFixedQuery: ClipQuery? {
        ClipQueryParser.parse(fixedModeQueryDraft)
    }

    /// State for the "Repair with Apple Intelligence" affordance in the
    /// Fixed-mode text input. `.idle` = show button. `.running` = spinner.
    /// `.repaired(String)` = show "Apply suggestion" CTA. `.failed(String)`
    /// = show error toast. Read by `ClipView.fixedModeTextInput`.
    enum RepairState: Equatable {
        case idle
        case running
        case repaired(String)
        case failed(String)
    }

    @Published var fixedModeRepairState: RepairState = .idle

    /// Returns true when the Apple Intelligence framework is available
    /// (iOS 26+). The actual call may still fail at runtime if the user
    /// hasn't enabled Apple Intelligence or the device isn't eligible —
    /// we surface that via `RepairState.failed`.
    var isAppleIntelligenceRepairAvailable: Bool {
        if #available(iOS 26, *) {
            return true
        }
        return false
    }

    /// Call `FixedModeQueryRepairer` on the current draft and surface the
    /// result via `fixedModeRepairState`. Runs on a background-friendly
    /// task (the repairer is async) and hops back to the main actor to
    /// publish. No-ops on pre-iOS 26 hardware.
    func repairFixedModeQuery() {
        guard #available(iOS 26, *) else {
            fixedModeRepairState = .failed("Requires iOS 26 or later.")
            return
        }
        let raw = fixedModeQueryDraft
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fixedModeRepairState = .failed("Type a recipe first.")
            return
        }
        fixedModeRepairState = .running
        Task { [weak self] in
            do {
                let repairer = FixedModeQueryRepairer()
                guard let repaired = try await repairer.repair(raw) else {
                    await MainActor.run {
                        self?.fixedModeRepairState = .failed(
                            "Couldn't repair that recipe. Try Buttons."
                        )
                    }
                    return
                }
                // Sanity: make sure the repair actually parses. If not,
                // surface a failure rather than letting a broken phrase
                // sit in the field.
                if ClipQueryParser.parse(repaired)?.isValid == true {
                    await MainActor.run {
                        self?.fixedModeRepairState = .repaired(repaired)
                    }
                } else {
                    await MainActor.run {
                        self?.fixedModeRepairState = .failed(
                            "Repaired recipe still doesn't parse."
                        )
                    }
                }
            } catch {
                let description = error.localizedDescription
                let message = description.localizedCaseInsensitiveContains("context window")
                    ? "That repair request was too large for Apple Intelligence. Shorten the recipe and try again."
                    : description
                await MainActor.run {
                    self?.fixedModeRepairState = .failed(
                        message
                    )
                }
            }
        }
    }

    /// Apply the AI-repaired text into the draft (so the parser runs
    /// against it and the chips light up). Idempotent.
    func applyRepairedFixedModeQuery(_ text: String) {
        fixedModeQueryDraft = text
        fixedModeRepairState = .idle
        PolishKit.Haptics.tap(.medium).play()
    }

    /// Discard the AI suggestion and return to idle.
    func dismissRepairedFixedModeQuery() {
        fixedModeRepairState = .idle
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
        let styleWillChange = fixedModeInputStyle != newStyle
        switch (fixedModeInputStyle, newStyle) {
        case (.text, .buttons):
            if let parsed = parsedFixedQuery, parsed.isValid {
                if let c = parsed.count { fixedModeButtonCount = max(1, c) }
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

        if styleWillChange {
            invalidateRecipePreview(status: "Previewing fixed clip recipe.")
        }
    }

    func updateFixedModeQueryDraft(_ text: String) {
        guard fixedModeQueryDraft != text else { return }
        fixedModeQueryDraft = text
        defaultFixedModeQueryDraft = text
        invalidateRecipePreview(status: "Previewing fixed clip recipe.")
    }

    func setFixedModeInputStyle(_ style: FixedModeInputStyle) {
        guard fixedModeInputStyle != style else { return }
        syncFixedModeAcrossStyles(to: style)
        fixedModeInputStyle = style
        defaultFixedModeInputStyle = style
        defaultFixedModeButtonCount = fixedModeButtonCount
        defaultFixedModeButtonDuration = fixedModeButtonDuration
        defaultFixedModeButtonInterval = fixedModeButtonInterval
        if style == .text {
            defaultFixedModeQueryDraft = resolvedDefaultFixedModeQueryDraft
        }
        persistCurrentProject()
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

    func fixedModeRanges(forSourceDuration totalDuration: Double) -> [ClipRange] {
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }
        switch fixedModeInputStyle {
        case .text:
            return Self.stampedFixedRanges(parsedFixedQuery?.ranges(forSourceDuration: totalDuration) ?? [])
        case .buttons:
            if fixedModeRandomDuration || fixedModeRandomInterval {
                return Self.randomizedFixedRanges(
                    totalDuration: totalDuration,
                    requestedCount: fixedModeButtonCount,
                    baseDuration: fixedModeButtonDuration,
                    baseInterval: fixedModeButtonInterval,
                    durationRange: fixedModeRandomDurationRange,
                    intervalRange: fixedModeRandomIntervalRange,
                    randomizeDuration: fixedModeRandomDuration,
                    randomizeInterval: fixedModeRandomInterval,
                    seed: fixedModeRandomSeed
                )
            }
            let ranges = ClipQuery(
                count: fixedModeButtonCount,
                durationSeconds: Double(fixedModeButtonDuration),
                intervalSeconds: Double(fixedModeButtonInterval)
            )
            .ranges(forSourceDuration: totalDuration)
            return Self.stampedFixedRanges(ranges)
        }
    }

    func setFixedModeRandomDuration(_ enabled: Bool) {
        guard fixedModeRandomDuration != enabled else { return }
        fixedModeRandomDuration = enabled
        if enabled {
            normalizeFixedModeRandomDurationBounds(anchor: fixedModeButtonDuration)
        }
        rerollFixedModeRandomSeed()
        invalidateRecipePreview(status: enabled ? "Randomizing clip duration." : "Previewing fixed clip recipe.")
    }

    func setFixedModeRandomInterval(_ enabled: Bool) {
        guard fixedModeRandomInterval != enabled else { return }
        fixedModeRandomInterval = enabled
        if enabled {
            normalizeFixedModeRandomIntervalBounds(anchor: fixedModeButtonInterval)
        }
        rerollFixedModeRandomSeed()
        invalidateRecipePreview(status: enabled ? "Randomizing spacing." : "Previewing fixed clip recipe.")
    }

    func setFixedModeRandomDurationMinimum(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let cleaned = clampedFixedModeRandomBound(seconds)
        guard fixedModeRandomDurationMinimum != cleaned else { return }

        fixedModeRandomDurationMinimum = min(cleaned, fixedModeRandomDurationMaximum)
        rerollFixedModeRandomSeed()
        invalidateRecipePreview(status: "Randomizing clip duration.")
        persistCurrentProject()
    }

    func setFixedModeRandomDurationMaximum(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let cleaned = clampedFixedModeRandomBound(seconds)
        guard fixedModeRandomDurationMaximum != cleaned else { return }

        fixedModeRandomDurationMaximum = max(cleaned, fixedModeRandomDurationMinimum)
        fixedModeButtonDuration = fixedModeRandomDurationMaximum
        defaultFixedModeButtonDuration = fixedModeButtonDuration
        rerollFixedModeRandomSeed()
        invalidateRecipePreview(status: "Randomizing clip duration.")
        persistCurrentProject()
    }

    func setFixedModeRandomIntervalMinimum(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let cleaned = clampedFixedModeRandomBound(seconds)
        guard fixedModeRandomIntervalMinimum != cleaned else { return }

        fixedModeRandomIntervalMinimum = min(cleaned, fixedModeRandomIntervalMaximum)
        rerollFixedModeRandomSeed()
        invalidateRecipePreview(status: "Randomizing spacing.")
        persistCurrentProject()
    }

    func setFixedModeRandomIntervalMaximum(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let cleaned = clampedFixedModeRandomBound(seconds)
        guard fixedModeRandomIntervalMaximum != cleaned else { return }

        fixedModeRandomIntervalMaximum = max(cleaned, fixedModeRandomIntervalMinimum)
        fixedModeButtonInterval = fixedModeRandomIntervalMaximum
        defaultFixedModeButtonInterval = fixedModeButtonInterval
        rerollFixedModeRandomSeed()
        invalidateRecipePreview(status: "Randomizing spacing.")
        persistCurrentProject()
    }

    private var fixedModeRandomDurationRange: ClosedRange<Double> {
        Double(min(fixedModeRandomDurationMinimum, fixedModeRandomDurationMaximum))...Double(max(fixedModeRandomDurationMinimum, fixedModeRandomDurationMaximum))
    }

    private var fixedModeRandomIntervalRange: ClosedRange<Double> {
        Double(min(fixedModeRandomIntervalMinimum, fixedModeRandomIntervalMaximum))...Double(max(fixedModeRandomIntervalMinimum, fixedModeRandomIntervalMaximum))
    }

    private func clampedFixedModeRandomBound(_ seconds: Double) -> Int {
        let upperBound: Double
        if let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 {
            upperBound = min(max(durationSeconds, 1), 300)
        } else {
            upperBound = 300
        }
        return Int(min(max(seconds.rounded(), 1), upperBound))
    }

    private func normalizeFixedModeRandomDurationBounds(anchor: Int) {
        let cleanedAnchor = clampedFixedModeRandomBound(Double(anchor))
        fixedModeRandomDurationMaximum = max(cleanedAnchor, fixedModeRandomDurationMinimum)
        fixedModeRandomDurationMinimum = min(fixedModeRandomDurationMinimum, fixedModeRandomDurationMaximum)
    }

    private func normalizeFixedModeRandomIntervalBounds(anchor: Int) {
        let cleanedAnchor = clampedFixedModeRandomBound(Double(anchor))
        fixedModeRandomIntervalMaximum = max(cleanedAnchor, fixedModeRandomIntervalMinimum)
        fixedModeRandomIntervalMinimum = min(fixedModeRandomIntervalMinimum, fixedModeRandomIntervalMaximum)
    }

    private func rerollFixedModeRandomSeed() {
        fixedModeRandomSeed = UInt64.random(in: 1...UInt64.max)
    }
    @Published var processingPhase: ProcessingPhase = .idle
    @Published var progress = 0.0
    @Published var statusMessage = "Choose a video to get started."
    @Published var errorMessage: String?

    private let segmenter = VideoSegmenter()
    private let smartCutAnalyzer = SmartCutAnalyzer()
    private let previewGenerator = MediaPreviewGenerator()
    private let waveformAnalyzer = WaveformAnalyzer()
    private let mediaWorkspace: MediaWorkspace
    private let proxyGenerator: MediaProxyGenerator
    private let projectStore: MediaProjectStore
    private let exportNotifications: ExportNotificationScheduling
    private let exportBackgroundTasks: ExportBackgroundTaskManaging
    private var userDefaultsStore: UserDefaultsStore
    private let exportRetentionInterval: TimeInterval = 7 * 24 * 60 * 60
    private var processingTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var scrubPersistenceTask: Task<Void, Never>?
    private var proxyTask: Task<Void, Never>?
    private var proxyGenerationID: UUID?
    private var playbackOriginalURL: URL?

    var importWorkspaceRoot: URL {
        mediaWorkspace.rootDirectory
    }

    init(
        mediaWorkspace: MediaWorkspace = MediaWorkspace(),
        exportNotifications: ExportNotificationScheduling = ExportNotificationManager.shared,
        exportBackgroundTasks: ExportBackgroundTaskManaging? = nil
    ) {
        self.mediaWorkspace = mediaWorkspace
        self.proxyGenerator = MediaProxyGenerator(workspace: mediaWorkspace)
        self.projectStore = MediaProjectStore(workspace: mediaWorkspace)
        self.exportNotifications = exportNotifications
        self.exportBackgroundTasks = exportBackgroundTasks ?? ExportBackgroundTaskManager.shared
        let defaults = UserDefaultsStore()
        self.userDefaultsStore = defaults
        self.defaultCutMode = defaults.defaultCutMode
        self.defaultSilenceClipDuration = defaults.defaultSilenceClipDurationSeconds
        self.defaultAiClipDuration = defaults.defaultAiClipDurationSeconds
        self.defaultHighlightDuration = defaults.defaultHighlightDurationSeconds
        self.defaultEditPrompt = defaults.defaultEditPrompt
        self.defaultFixedModeInputStyle = defaults.defaultFixedModeInputStyle
        self.defaultFixedModeQueryDraft = defaults.defaultFixedModeQueryDraft
        self.defaultFixedModeButtonCount = defaults.defaultFixedModeButtonCount
        self.defaultFixedModeButtonDuration = defaults.defaultFixedModeButtonDuration
        self.defaultFixedModeButtonInterval = defaults.defaultFixedModeButtonInterval
        loadProjects()
        cleanupExpiredExports()
        refreshAIUsagePeriod()
    }

    var isUsingProxy: Bool {
        guard let sourceURL, let playbackURL else { return false }
        return playbackOriginalURL?.standardizedFileURL == sourceURL.standardizedFileURL
            && sourceURL.standardizedFileURL != playbackURL.standardizedFileURL
    }

    /// Resolves preview media only. Planning, analysis, and export continue to
    /// use the original scene URL stored in `sourceURL` / `MediaProjectScene`.
    func resolvedPlaybackURL(for originalURL: URL?) -> URL? {
        guard let originalURL else { return nil }
        if sourceMatches(originalURL),
           playbackOriginalURL?.standardizedFileURL == originalURL.standardizedFileURL {
            return playbackURL ?? originalURL
        }
        return mediaWorkspace.cachedProxyURL(for: originalURL) ?? originalURL
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

    /// True when a free-tier user has hit the monthly AI plan cap. Paid
    /// tiers always return false.
    var canRunAnotherFreeAIPlan: Bool {
        if currentTier != .free { return true }
        refreshAIUsagePeriodIfRollover()
        return aiPlansThisMonth < MediaProcessingLimits.monthlyFreeAIQuota
    }

    private func refreshAIUsagePeriod() {
        let (count, periodStart) = AIUsagePeriodStore.read()
        aiPlansThisMonth = count
        currentAITierPeriodStart = periodStart
        hasReachedFreeAIQuota = count >= MediaProcessingLimits.monthlyFreeAIQuota
    }

    private func refreshAIUsagePeriodIfRollover() {
        let startOfMonth = AIUsagePeriodStore.startOfCurrentMonth()
        if startOfMonth != currentAITierPeriodStart {
            // New month — reset the counter atomically.
            AIUsagePeriodStore.write(count: 0, periodStart: startOfMonth)
            aiPlansThisMonth = 0
            currentAITierPeriodStart = startOfMonth
            hasReachedFreeAIQuota = false
        }
    }

    /// Increments the AI plan counter and persists it. Call only when an AI
    /// plan was actually dispatched (not when the user opens the paywall).
    func recordAIPlanInvocation() {
        refreshAIUsagePeriodIfRollover()
        let next = aiPlansThisMonth + 1
        aiPlansThisMonth = next
        hasReachedFreeAIQuota = next >= MediaProcessingLimits.monthlyFreeAIQuota
        AIUsagePeriodStore.write(count: next, periodStart: currentAITierPeriodStart)
    }

    var isProcessing: Bool {
        processingPhase.isBusy
    }

    /// Effective settings for the current project. Reads the
    /// project's saved `exportSettings` if present, else falls
    /// back to a tier-appropriate default. Used by the render
    /// pipeline and by the header pill UI.
    var projectExportSettings: ExportSettings {
        if let currentProjectID,
           let project = projects.first(where: { $0.id == currentProjectID }),
           let saved = project.exportSettings {
            return saved
        }
        return ExportSettings.defaults(for: currentTier)
    }

    /// Apply new export settings to the current project and
    /// persist. Idempotent — calling with the same value is a
    /// no-op save.
    func updateExportSettings(_ settings: ExportSettings) {
        currentProjectExportSettings = settings
        guard let currentProjectID,
              let projectIndex = projects.firstIndex(where: { $0.id == currentProjectID }) else {
            return
        }
        projects[projectIndex].exportSettings = settings
        projects[projectIndex].updatedAt = Date()
        do {
            try projectStore.saveProjects(projects)
        } catch {
            errorMessage = "Couldn't save export settings: \(error.localizedDescription)"
        }
    }

    var canPrepare: Bool {
        // AI Assist now runs on-device via Apple Intelligence —
        // no API key required, so the `.aiAssist` gate is just
        // the runtime check (handled separately when invoking
        // the planner; if Apple Intelligence is unavailable,
        // the planner surfaces its own "requires iPhone 15
        // Pro or later" error).
        sourceURL.map { FileManager.default.fileExists(atPath: $0.path) } == true &&
            durationSeconds.map { $0.isFinite && $0 > 0 } == true &&
            parsedSegmentLength.map { $0.isFinite && $0 > 0 } == true &&
            !isProcessing
    }

    var canExportPreparedClips: Bool {
        sourceURL != nil && !plannedRangesForCurrentMode.isEmpty && !isProcessing
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

    var activeSceneName: String {
        activeScene?.name ?? "Scene 1"
    }

    var activeScene: MediaProjectScene? {
        if let activeSceneId,
           let scene = scenes.first(where: { $0.id == activeSceneId }) {
            return scene
        }

        return scenes.first
    }

    var hasOpenProjectContext: Bool {
        activeSceneId != nil || currentProjectID != nil || !scenes.isEmpty
    }

    /// True when the active scene contains anything the scene reset should
    /// remove. The project title and scene identity are deliberately excluded
    /// from this check because Reset keeps both of them.
    var hasActiveSceneContent: Bool {
        sourceURL != nil ||
            durationSeconds != nil ||
            !plannedRanges.isEmpty ||
            !savedClips.isEmpty ||
            !clips.isEmpty ||
            !tightenedClips.isEmpty ||
            transcript != nil
    }

    /// Default display title for a planned clip at the given index — used as
    /// the seed when rendering clips and when the user clears their custom
    /// name (so the fallback path is consistent everywhere).
    func clipDefaultTitle(for index: Int, totalCount: Int? = nil) -> String {
        let projectName = currentProjectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = SegmentOutput.defaultTitle(for: index, totalCount: totalCount)
        if projectName.isEmpty || projectName == "New project" {
            return suffix
        }
        return "\(projectName) - \(suffix)"
    }

    /// Titles aligned to the current `plannedRanges`. Used at export time so
    /// the on-disk filenames + Photos asset names carry the user's naming
    /// from the moment the clip is rendered.
    func clipTitlesForCurrentPlan() -> [String] {
        let totalCount = plannedRanges.count
        return plannedRanges.indices.map { clipDefaultTitle(for: $0, totalCount: totalCount) }
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

    /// Add a new blank scene. The current scene's state is saved
    /// first (so the user can switch back to it without losing
    /// edits), then a brand-new scene is created with no source,
    /// no planned ranges, and default editor settings. The
    /// project-level state is reset to match the new scene so the
    /// source stage shows the empty state, ready for the user to
    /// import a new clip and start editing.
    ///
    /// This replaced the old `createSceneSnapshot` behavior
    /// (which copied the current source + state into the new
    /// scene). The "snapshot" use case is now served by
    /// `duplicateScene`, which copies a specific existing scene.
    /// The new-scene button is for adding a fresh cut to work on.
    func addBlankScene() {
        let now = Date()
        // Save the current scene's state FIRST. Without this the
        // user's in-progress edits in the current scene would be
        // lost when we reset the project-level state below — the
        // project-level cache is the only place edits live until
        // they're written into a scene. (loadProject / openProject
        // would reload from disk, but here we're in-app.)
        saveCurrentStateIntoSceneList(updatedAt: now)

        let blank = MediaProjectScene(
            id: UUID(),
            name: nextSceneName(),
            // No source — the user picks one for this scene via
            // the existing Files / Photos buttons (or via the
            // scene menu's "Change source…"). sourcePath /
            // sourcePhotoLibraryIdentifier nil means the scene's
            // hasSource returns false; applySourceForScene
            // leaves the project-level source alone until the
            // user picks one.
            sourcePath: nil,
            sourceFileName: nil,
            sourcePhotoLibraryIdentifier: nil,
            sourceOriginalFilename: nil,
            durationSeconds: nil,
            sourceAspectRatio: nil,
            frameDurationSeconds: nil,
            cutMode: .highlight,
            segmentLengthText: "\(defaultSegmentLengthForMode(.highlight))",
            editPrompt: defaultEditPrompt,
            plannedRanges: [],
            highlightDraftStart: nil,
            highlightDraftDuration: Double(defaultHighlightDuration),
            scrubPositionSeconds: 0,
            createdAt: now,
            updatedAt: now
        )
        scenes.append(blank)
        activeSceneId = blank.id

        // Reset the project-level state to match the new blank
        // scene so the editor immediately shows the empty
        // source stage + a clean cut recipe. The user can then
        // import a clip via the existing Files / Photos buttons.
        resetPlaybackMedia()
        sourceURL = nil
        durationSeconds = nil
        sourcePhotoLibraryIdentifier = nil
        sourceThumbnails = []
        waveformSamples = []
        sourceAspectRatio = 16.0 / 9.0
        frameDurationSeconds = 1.0 / 30.0
        applyFreshSpliceDefaults(clearPlannedState: true)
        plannedRanges = []
        clips = []
        pendingExportClips = nil
        pendingExportSceneLabels = [:]
        pendingExportMissingScenes = []
        // Drop any in-flight tightened output — its file lives on disk
        // and would be orphaned if we kept it across source changes.
        cancelTightenedExport()
        // NB: per-view state (`userSelectedRangeIndex`,
        // `previewPlayer`) is owned by ClipView and gets reset
        // there when the source URL changes. We can't touch it
        // from here without a reverse binding.

        statusMessage = "\(blank.name) ready — import a clip to start."
        persistCurrentProject()
    }

    /// Clear the active scene without deleting the project or the scene.
    /// This is intentionally stronger than the recipe reset: it removes the
    /// source, all planned/saved/rendered clips, transcript state, and draft
    /// recipe inputs, then leaves the same scene id and name ready for a new
    /// import.
    func resetActiveSceneToEmpty() {
        guard let activeSceneId,
              let sceneIndex = scenes.firstIndex(where: { $0.id == activeSceneId }) else {
            return
        }

        cancelProcessing(updateStatus: false)
        previewTask?.cancel()
        waveformTask?.cancel()
        scrubPersistenceTask?.cancel()
        transcriptTask?.cancel()
        transcriptTask = nil

        if let pendingExportClips, !pendingExportClips.isEmpty {
            mediaWorkspace.removeDirectories(for: pendingExportClips)
        }
        if !clips.isEmpty {
            mediaWorkspace.removeDirectories(for: clips)
        }
        cancelTightenedExport()

        let scene = scenes[sceneIndex]
        let sourceToRemove = sourceURL?.standardizedFileURL
        let now = Date()
        let preservedID = scene.id
        let preservedName = scene.name
        let preservedCreatedAt = scene.createdAt

        resetPlaybackMedia()
        sourceURL = nil
        durationSeconds = nil
        sourcePhotoLibraryIdentifier = nil
        sourceThumbnails = []
        waveformSamples = []
        timelineZoom = .fit
        sourceAspectRatio = 16.0 / 9.0
        frameDurationSeconds = 1.0 / 30.0
        scrubPositionSeconds = 0
        savedClips = []
        clips = []
        pendingExportClips = nil
        pendingExportSceneLabels = [:]
        pendingExportMissingScenes = []
        replacingPlannedRangeIndex = nil
        transcript = nil
        transcriptState = .idle
        fixedModeRepairState = .idle
        errorMessage = nil
        progress = 0
        draggingProjectExportIndex = nil
        projectExportDragTargetIndex = nil
        isShowingExportPreview = false
        selectedItem = nil

        applyFreshSpliceDefaults(clearPlannedState: true)

        scenes[sceneIndex] = MediaProjectScene(
            id: preservedID,
            name: preservedName,
            cutMode: cutMode,
            segmentLengthText: segmentLengthText,
            editPrompt: editPrompt,
            plannedRanges: [],
            highlightDraftStart: nil,
            highlightDraftDuration: Double(defaultHighlightDuration),
            scrubPositionSeconds: 0,
            createdAt: preservedCreatedAt,
            updatedAt: now
        )

        if let sourceToRemove,
           sourceToRemove.path.hasPrefix(mediaWorkspace.importsDirectory.standardizedFileURL.path + "/"),
           !scenes.contains(where: { $0.id != preservedID && $0.sourcePath == sourceToRemove.path }) {
            try? mediaWorkspace.fileManager.removeItem(at: sourceToRemove)
        }

        statusMessage = "\(preservedName) reset — import a clip to start."
        persistCurrentProject()
    }

    func switchToScene(_ id: UUID) {
        guard id != activeSceneId,
              let scene = scenes.first(where: { $0.id == id }) else { return }

        saveCurrentStateIntoSceneList(updatedAt: Date())
        activeSceneId = id
        applyScene(scene)
        statusMessage = "Restored \(scene.name)."
        persistCurrentProject()
    }

    func renameActiveScene(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let activeSceneId,
              let index = scenes.firstIndex(where: { $0.id == activeSceneId }) else { return }

        let resolvedName = uniqueSceneName(trimmed, excluding: activeSceneId)
        scenes[index].name = resolvedName
        scenes[index].updatedAt = Date()
        statusMessage = "Scene renamed to \(resolvedName)."
        persistCurrentProject()
    }

    /// Delete a scene by id. If the deleted scene was the active one,
    /// the active scene falls back to the first remaining scene (or nil
    /// if the project now has no scenes). The editor state is NOT
    /// preserved when the active scene is removed — the user has
    /// already been warned at the confirmation prompt that this
    /// will lose any unsaved-into-active-scene changes.
    ///
    /// After deletion, the remaining scenes are renumbered so the
    /// "Scene N" defaults stay sequential: deleting "Scene 1" of
    /// ("Scene 1", "Scene 2") leaves a single scene that's now
    /// called "Scene 1" instead of "Scene 2". Custom-named scenes
    /// ("Birthday", "Highlight reel") are NEVER renumbered — we
    /// only touch names that still match the "Scene <number>" pattern
    /// produced by `nextSceneName()`.
    func deleteScene(id: UUID) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = (id == activeSceneId)
        let deletedName = scenes[index].name
        scenes.remove(at: index)

        // Renumber default-named scenes. Iterate by position so the
        // new index drives the new name. The "Scene N" regex is the
        // only pattern we touch — anything else (user renames,
        // translated names, future scene types) is preserved.
        let defaultNamePattern = try? NSRegularExpression(
            pattern: #"^Scene\s+(\d+)$"#
        )
        for newIndex in scenes.indices {
            let current = scenes[newIndex].name
            guard let regex = defaultNamePattern,
                  let match = regex.firstMatch(
                    in: current,
                    range: NSRange(current.startIndex..., in: current)
                  ),
                  match.numberOfRanges > 1
            else { continue }
            let position = newIndex + 1
            let newName = "Scene \(position)"
            if current != newName {
                scenes[newIndex].name = newName
                scenes[newIndex].updatedAt = Date()
            }
        }

        if wasActive {
            // Apply the new active scene (or reset to "no scene" state).
            let nextActive = scenes.first
            if let next = nextActive {
                activeSceneId = next.id
                applyScene(next)
            } else {
                activeSceneId = nil
                resetEditorForEmptyScenes()
            }
        }
        // If the deleted scene wasn't active, the in-memory editor
        // state is untouched — no apply needed.
        statusMessage = "Deleted \(deletedName)."
        persistCurrentProject()
    }

    /// Duplicate a scene by id. The copy is a deep clone of the source
    /// scene's cut state, with a fresh UUID, " Copy" suffix on the name,
    /// and `createdAt`/`updatedAt` reset to now. The duplicate is
    /// inserted immediately after the source in the list and made the
    /// active scene so the user starts editing it.
    func duplicateScene(id: UUID) {
        guard let sourceIndex = scenes.firstIndex(where: { $0.id == id }) else { return }
        let source = scenes[sourceIndex]
        let now = Date()
        let copyName = uniqueSceneName(source.name + " Copy")
        let copy = MediaProjectScene(
            name: copyName,
            sourcePath: source.sourcePath,
            sourceFileName: source.sourceFileName,
            sourcePhotoLibraryIdentifier: source.sourcePhotoLibraryIdentifier,
            sourceOriginalFilename: source.sourceOriginalFilename,
            durationSeconds: source.durationSeconds,
            sourceAspectRatio: source.sourceAspectRatio,
            frameDurationSeconds: source.frameDurationSeconds,
            cutMode: source.cutMode,
            segmentLengthText: source.segmentLengthText,
            editPrompt: source.editPrompt,
            plannedRanges: source.plannedRanges,
            highlightDraftStart: source.highlightDraftStart,
            highlightDraftDuration: source.highlightDraftDuration,
            scrubPositionSeconds: source.scrubPositionSeconds,
            createdAt: now,
            updatedAt: now
        )
        // Insert immediately after the source so the new scene is
        // visually adjacent to its origin in the switcher.
        let insertIndex = min(sourceIndex + 1, scenes.count)
        scenes.insert(copy, at: insertIndex)
        activeSceneId = copy.id
        applyScene(copy)
        statusMessage = "Duplicated \(source.name) → \(copy.name)."
        persistCurrentProject()
    }

    /// Reset the in-memory cut state to "no active scene" — clears the
    /// planned ranges, the highlight draft, the mode-specific controls,
    /// and the scrub position. Called when the last scene of a project
    /// is deleted so the UI can fall back to a clean slate instead of
    /// showing the deleted scene's stale state.
    private func resetEditorForEmptyScenes() {
        applyFreshSpliceDefaults(clearPlannedState: true)
        updateScrubPosition(0)
    }

    /// Rename a single saved clip. Updates the in-memory `clips` array and
    /// persists the project so the new title round-trips through JSON.
    func renameClip(_ clipID: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }

        // Pass the raw trimmed string through — SegmentOutput normalizes again
        // and `displayTitle` does the generated fallback at render time.
        clips[index] = clips[index].withTitle(trimmed)
        persistCurrentProject()
        PolishKit.Haptics.selection.play()
    }

    /// Return a URL that's safe to share via `UIActivityViewController` and
    /// carries the clip's display title as its filename. If the on-disk file
    /// already has the right name we just hand it back; otherwise we copy to
    /// a staging directory so AirDrop / Files / iMessage show the friendly
    /// name instead of the generated fallback name the segmenter wrote.
    ///
    /// The staging file lives under the workspace so the standard cleanup
    /// passes (`cleanupExports`) can reap it later.
    func shareableURL(for clip: SegmentOutput) -> URL? {
        let desiredName = FilenameSanitizer.sanitizedFileName(
            from: clip.displayTitle,
            fallbackBase: SegmentOutput.defaultFileBase(for: clip.index),
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
        // Per-mode total: combined duration of every planned clip
        // in the currently-active cut mode. Lets the user see at a
        // glance "if I export Cut-mode right now, I'll get N
        // seconds of footage" — without having to sum the per-clip
        // rows in the Planned clips section below. Falls back to
        // "--" when the user hasn't planned anything in this mode
        // yet, so the tile reads cleanly before any work is done.
        let currentModeRanges = plannedRangesForCurrentMode
        guard !currentModeRanges.isEmpty else { return "--" }
        let total = currentModeRanges.reduce(0.0) { partial, range in
            partial + max(0, range.endSeconds - range.startSeconds)
        }
        return Self.formatDuration(total)
    }

    /// Live feasibility snapshot for the current fixed-mode input. Read from
    /// the `Expected` panel so the `Expected` integer and the actual clip
    /// count never disagree.
    var liveRecipeFeasibility: ClipQuery.Feasibility? {
        // Feasibility belongs to the Fixed recipe only. Other modes use
        // analysis to discover ranges, so a query left over from another
        // mode must never produce a misleading "source is shorter" error.
        guard cutMode == .fixed else { return nil }
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        if fixedModeInputStyle == .buttons,
           fixedModeRandomDuration || fixedModeRandomInterval {
            let ranges = fixedModeRanges(forSourceDuration: durationSeconds)
            let lastEnd = ranges.last?.endSeconds ?? 0
            let actualClipSpan = ranges.first.map { $0.endSeconds - $0.startSeconds } ?? 0
            return ClipQuery.Feasibility(
                achievableCount: ranges.count,
                requestedCount: fixedModeButtonCount,
                actualClipSpan: actualClipSpan,
                leftoverSeconds: max(0, durationSeconds - lastEnd)
            )
        }
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
        if fixedModeInputStyle == .buttons,
           fixedModeRandomDuration || fixedModeRandomInterval {
            return fixedModeRanges(forSourceDuration: durationSeconds).count
        }

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
        if cutMode == .fixed {
            guard let expectedClipCount else { return "--" }
            // Fixed mode is actively editable. Show the live recipe's output,
            // not an older set of already-planned clips from this mode.
            if let feasibility = liveRecipeFeasibility,
               let requested = feasibility.requestedCount,
               requested > 0,
               feasibility.achievableCount < requested {
                return "\(feasibility.achievableCount) of \(requested)"
            }
            return "\(expectedClipCount)"
        }

        let currentModeCount = plannedRangesForCurrentMode.count
        if currentModeCount > 0 {
            return "\(currentModeCount)"
        }

        if cutMode == .smartPause || cutMode == .highlight || cutMode == .aiAssist {
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
        // fall back to the user-configured default for the current
        // cut mode from Settings. This way the safe internal
        // default still works even if `segmentLengthText` was
        // never set for this project. Picks Silence vs AI's own
        // default so each mode honours its own stored value.
        let cleaned = segmentLengthText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(cleaned), value.isFinite, value >= 1 {
            return value
        }
        let fallback: Int
        switch cutMode {
        case .aiAssist:
            fallback = defaultAiClipDuration
        case .fixed, .smartPause, .highlight:
            // SmartPause is the canonical user of this fallback;
            // Fixed + Highlight use different fields and won't
            // hit this path.
            fallback = defaultSilenceClipDuration
        }
        let value = Double(fallback)
        return value.isFinite && value >= 1 ? value : nil
    }

    var hasUnsavedPlan: Bool {
        !plannedRangesForCurrentMode.isEmpty && clips.isEmpty
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
        let sourceLimit = MediaProcessingLimits.maximumSourceDurationLabel(for: currentTier)
        return "Max \(sourceLimit) source, \(MediaProcessingLimits.maximumPlannedClips) clips"
    }

    func importSelectedVideo() {
        guard let selectedItem else { return }
        if hasOpenProjectContext {
            replaceActiveSceneSource(from: selectedItem)
            self.selectedItem = nil
            return
        }

        importSelectedVideo(from: selectedItem)
    }

    func importSelectedVideo(from item: PhotosPickerItem) {
        guard let importID = beginMediaImport(status: "Loading video...") else {
            selectedItem = nil
            return
        }

        cancelProcessing(updateStatus: false)
        previewTask?.cancel()
        waveformTask?.cancel()
        selectedItem = nil
        applyFreshSpliceDefaults(clearPlannedState: true)

        mediaImportTask = Task {
            await loadVideo(from: item, importID: importID)
        }
    }

    func importVideoFile(from url: URL) {
        if hasOpenProjectContext {
            replaceActiveSceneSource(from: url)
            return
        }

        guard let importID = beginMediaImport(status: "Importing file...") else { return }

        cancelProcessing(updateStatus: false)
        previewTask?.cancel()
        waveformTask?.cancel()
        applyFreshSpliceDefaults(clearPlannedState: true)

        mediaImportTask = Task {
            await loadVideoFile(from: url, importID: importID)
        }
    }

    /// Copies a new-project file import into the private workspace so it can
    /// remain available while the user chooses full-clip or pre-import trim.
    /// The original security-scoped file is never modified.
    func prepareImportCopy(
        from url: URL,
        progress: MediaImportProgressHandler? = nil
    ) async throws -> ImportedSourceCopy {
        // A large Files copy must not run on the main actor while the source
        // chooser is visible. Recreate the workspace from its stable root so
        // the detached task only captures Sendable values.
        let workspaceRoot = mediaWorkspace.rootDirectory
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let copiedURL = try MediaWorkspace(rootDirectory: workspaceRoot).importSourceCopyResult(
                from: url,
                progress: progress
            )
            try Task.checkCancellation()
            return copiedURL
        }.value
    }

    /// Starts a new-project import after the optional pre-import trim sheet
    /// has been confirmed. Existing scene replacement continues to use its
    /// separate path and never receives this trim choice accidentally.
    func importPreparedVideo(
        from url: URL,
        photoLibraryIdentifier: String?,
        sourceName: String,
        canDiscardPreparedSource: Bool,
        trimRange: ClipRange?
    ) {
        guard !hasOpenProjectContext else {
            errorMessage = "Finish or reset the current project before importing a new source."
            return
        }
        guard let importID = beginMediaImport(status: trimRange == nil ? "Loading video..." : "Trimming selected section...") else {
            return
        }

        cancelProcessing(updateStatus: false)
        previewTask?.cancel()
        waveformTask?.cancel()
        applyFreshSpliceDefaults(clearPlannedState: true)

        mediaImportTask = Task {
            await loadPreparedVideoFile(
                from: url,
                photoLibraryIdentifier: photoLibraryIdentifier,
                sourceName: sourceName,
                canDiscardPreparedSource: canDiscardPreparedSource,
                trimRange: trimRange,
                importID: importID
            )
        }
    }

    /// Discards a new candidate prepared for the optional trim sheet. The
    /// caller owns the `wasCreated` decision so a shared deduplicated import
    /// can never be removed by canceling a new-project flow.
    func discardPreparedImport(at url: URL) {
        mediaWorkspace.removeImportedSource(at: url)
    }

    /// Per-scene source replacement (Photos imports). Copies the
    /// picked file into the workspace, then updates ONLY the active
    /// scene's source fields and swaps the project-level cache to
    /// match. Other scenes keep their existing source. Called from
    /// the "Change source for this scene" sheet in ClipView.
    func replaceActiveSceneSource(
        from item: PhotosPickerItem,
        planAction: SceneSourceReplacementPlanAction = .keep
    ) {
        guard let importID = beginMediaImport(status: "Loading scene source...") else { return }

        cancelProcessing(updateStatus: false)
        previewTask?.cancel()
        waveformTask?.cancel()

        mediaImportTask = Task {
            await loadReplacementSceneSource(from: item, planAction: planAction, importID: importID)
        }
    }

    /// Per-scene source replacement (file imports). Mirrors
    /// `replaceActiveSceneSource(from: PhotosPickerItem)` but takes
    /// a `URL` from the file importer.
    func replaceActiveSceneSource(
        from url: URL,
        planAction: SceneSourceReplacementPlanAction = .keep
    ) {
        guard let importID = beginMediaImport(status: "Loading scene source...") else { return }

        cancelProcessing(updateStatus: false)
        previewTask?.cancel()
        waveformTask?.cancel()

        mediaImportTask = Task {
            await loadReplacementSceneSourceFile(from: url, planAction: planAction, importID: importID)
        }
    }

    private func loadReplacementSceneSource(
        from item: PhotosPickerItem,
        planAction: SceneSourceReplacementPlanAction,
        importID: UUID
    ) async {
        defer { finishMediaImport(importID) }

        processingPhase = .loading
        progress = 0
        errorMessage = nil
        statusMessage = "Loading scene source..."

        let photoId = item.photoLibraryLocalIdentifier

        var materializedVideo: PickedVideo?
        var sourceInstalled = false
        defer {
            if let materializedVideo,
               materializedVideo.isWorkspaceCopyNew,
               !sourceInstalled {
                mediaWorkspace.removeImportedSource(at: materializedVideo.url)
            }
        }

        do {
            guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
                statusMessage = "Choose a valid video file."
                processingPhase = .idle
                return
            }

            guard !Task.isCancelled else {
                statusMessage = "Scene source import cancelled."
                processingPhase = .idle
                return
            }
            materializedVideo = video

            guard FileManager.default.fileExists(atPath: video.url.path) else {
                throw PickedVideoImportError.photosDownloadUnavailable
            }
            try await installSourceForActiveScene(
                url: video.url,
                photoLibraryIdentifier: photoId ?? video.photoLibraryLocalIdentifier,
                planAction: planAction
            )
            sourceInstalled = true
            statusMessage = "Scene source updated."
        } catch is CancellationError {
            statusMessage = "Scene source import cancelled."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not update scene source."
        }

        processingPhase = .idle
    }

    private func loadReplacementSceneSourceFile(
        from url: URL,
        planAction: SceneSourceReplacementPlanAction,
        importID: UUID
    ) async {
        defer { finishMediaImport(importID) }

        processingPhase = .loading
        progress = 0
        errorMessage = nil
        statusMessage = "Loading scene source..."

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            guard !Task.isCancelled else {
                statusMessage = "Scene source import cancelled."
                processingPhase = .idle
                return
            }

            // iCloud Drive placeholders: force the download before the
            // workspace copy step tries to read the file.
            try await MediaImportPreparation.ensureFileIsLocal(url) { [weak self] fraction in
                Task { @MainActor in
                    self?.progress = fraction
                }
            }

            let copiedURL = try mediaWorkspace.importSourceCopy(from: url)
            try await installSourceForActiveScene(
                url: copiedURL,
                photoLibraryIdentifier: nil,
                planAction: planAction
            )
            statusMessage = "Scene source updated."
        } catch is CancellationError {
            statusMessage = "Scene source import cancelled."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not update scene source."
        }

        processingPhase = .idle
    }

    /// Set the source for the active scene — updates the scene's
    /// own source fields, the project-level cache, and regenerates
    /// thumbnails / waveform for the new source. Used by both
    /// `replaceActiveSceneSource(from:)` overloads and by
    /// `swapSource` (the scene-switch path).
    private func installSourceForActiveScene(
        url: URL,
        photoLibraryIdentifier: String?,
        planAction: SceneSourceReplacementPlanAction
    ) async throws {
        let duration = try await segmenter.duration(for: url)
        try MediaProcessingLimits.validateSourceDuration(duration, for: currentTier)
        let aspect = try await aspectRatio(for: url)
        let frameDur = try await frameDuration(for: url)

        switch planAction {
        case .keep:
            break
        case .clear:
            plannedRanges = []
            clips = []
            highlightDraftStart = nil
        case .clamp:
            let clamped = Self.clampedPlannedRanges(
                plannedRanges,
                totalDuration: duration,
                frameDuration: frameDur
            )
            plannedRanges = clamped
            clips = []
            if let draftStart = highlightDraftStart {
                highlightDraftStart = min(max(draftStart, 0), max(0, duration - highlightDraftDuration))
            }
        }

        sourceURL = url
        preparePlaybackMedia(for: url)
        durationSeconds = duration
        sourceAspectRatio = aspect
        frameDurationSeconds = frameDur
        sourcePhotoLibraryIdentifier = photoLibraryIdentifier

        // Tear down stale previews and regenerate for the new source.
        sourceThumbnails = []
        waveformSamples = []
        loadPreviews(for: url, durationSeconds: duration)
        loadWaveform(for: url, durationSeconds: duration)

        // Stamp the source onto the active scene so switching
        // scenes doesn't lose the binding.
        if let activeSceneId,
           let index = scenes.firstIndex(where: { $0.id == activeSceneId }) {
            scenes[index].sourcePath = url.standardizedFileURL.path
            scenes[index].sourceFileName = url.lastPathComponent
            scenes[index].sourcePhotoLibraryIdentifier = photoLibraryIdentifier
            scenes[index].sourceOriginalFilename = url.lastPathComponent
            scenes[index].durationSeconds = duration
            scenes[index].sourceAspectRatio = aspect
            scenes[index].frameDurationSeconds = frameDur
            scenes[index].plannedRanges = plannedRanges
            scenes[index].highlightDraftStart = highlightDraftStart
            scenes[index].highlightDraftDuration = highlightDraftDuration
            scenes[index].updatedAt = Date()
        }

        seedHighlightDraftIfNeeded(totalDuration: duration)

        persistCurrentProject()
    }

    private static func clampedPlannedRanges(
        _ ranges: [ClipRange],
        totalDuration: Double,
        frameDuration: Double
    ) -> [ClipRange] {
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }
        let minimum = min(max(frameDuration, 0.05), totalDuration)

        return ranges.compactMap { range in
            let start = min(max(range.startSeconds, 0), totalDuration)
            let end = min(max(range.endSeconds, 0), totalDuration)
            guard end - start >= 0.05 else { return nil }

            return ClipRangeEditor.updatedRange(
                range,
                totalDuration: totalDuration,
                frameDuration: frameDuration,
                startSeconds: start,
                endSeconds: end,
                minimumDuration: minimum
            )
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
            persistCurrentProject()
            return
        }

        guard let durationSeconds else {
            persistCurrentProject()
            return
        }

        guard plannedRanges.isEmpty else {
            statusMessage = "Review \(plannedRanges.count) accrued clip\(plannedRanges.count == 1 ? "" : "s")."
            persistCurrentProject()
            return
        }

        plannedRanges = fixedModeRanges(forSourceDuration: durationSeconds)
        statusMessage = "Previewing \(plannedRanges.count) fixed clips."

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

    func syncScrubPositionFromPlayback(_ value: Double) {
        guard value.isFinite, let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else {
            scrubPositionSeconds = 0
            return
        }

        scrubPositionSeconds = min(max(value, 0), durationSeconds)
    }

    private func invalidateRecipePreview(status: String? = nil) {
        if !clips.isEmpty {
            clips = []
        }
        pendingExportClips = nil
        pendingExportSceneLabels = [:]
        pendingExportMissingScenes = []
        progress = 0
        if let status {
            statusMessage = status
        }
    }

    func setSegmentDuration(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let upperBound: Double
        if let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 {
            upperBound = min(max(durationSeconds, 1), 300)
        } else {
            upperBound = 300
        }
        let cleaned = Int(min(max(seconds.rounded(), 1), upperBound))
        guard segmentLengthText != "\(cleaned)" else { return }

        segmentLengthText = "\(cleaned)"
        // Persist the change to the per-mode default for the
        // current cut mode — Silence and AI keep their own
        // values, so editing one never crosses over into the
        // other.
        switch cutMode {
        case .aiAssist:
            defaultAiClipDuration = cleaned
        case .fixed, .smartPause, .highlight:
            defaultSilenceClipDuration = cleaned
        }
        invalidateRecipePreview()
        statusMessage = "Clip length set to \(cleaned)s."
        persistCurrentProject()
    }

    func setDefaultCutMode(_ mode: CutMode) {
        defaultCutMode = mode
        applyDefaultsToBlankEditorIfNeeded()
    }

    func setDefaultSilenceClipDuration(_ seconds: Int) {
        defaultSilenceClipDuration = min(max(seconds, 5), 120)
        applyDefaultsToBlankEditorIfNeeded()
    }

    func setDefaultAiClipDuration(_ seconds: Int) {
        defaultAiClipDuration = min(max(seconds, 5), 120)
        applyDefaultsToBlankEditorIfNeeded()
    }

    /// Kept for legacy callers — routes the value to the per-mode
    /// slot for the current default mode. Settings UI calls
    /// the per-mode variants directly now.
    func setDefaultSegmentLength(_ seconds: Int) {
        let cleaned = min(max(seconds, 5), 120)
        switch defaultCutMode {
        case .aiAssist:
            defaultAiClipDuration = cleaned
        case .fixed, .smartPause, .highlight:
            defaultSilenceClipDuration = cleaned
        }
        applyDefaultsToBlankEditorIfNeeded()
    }

    func setDefaultHighlightDuration(_ seconds: Int) {
        defaultHighlightDuration = min(max(seconds, 1), 120)
        applyDefaultsToBlankEditorIfNeeded()
    }

    func setDefaultEditPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        defaultEditPrompt = trimmed.isEmpty ? UserDefaultsStore.fallbackEditPrompt : trimmed
        applyDefaultsToBlankEditorIfNeeded()
    }

    func setDefaultFixedModeInputStyle(_ style: FixedModeInputStyle) {
        defaultFixedModeInputStyle = style
        if style == .text,
           defaultFixedModeQueryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaultFixedModeQueryDraft = resolvedDefaultFixedModeQueryDraft
        } else if style == .buttons,
                  let parsed = ClipQueryParser.parse(defaultFixedModeQueryDraft),
                  parsed.isValid {
            if let count = parsed.count {
                defaultFixedModeButtonCount = min(max(count, 1), 50)
            }
            if let duration = parsed.durationSeconds {
                defaultFixedModeButtonDuration = min(max(Int(duration.rounded()), 1), 120)
            }
            if let interval = parsed.intervalSeconds {
                defaultFixedModeButtonInterval = min(max(Int(interval.rounded()), 1), 120)
            }
        }
        applyDefaultsToBlankEditorIfNeeded()
    }

    func setDefaultFixedModeQueryDraft(_ text: String) {
        defaultFixedModeQueryDraft = text
        guard let parsed = ClipQueryParser.parse(text), parsed.isValid else {
            applyDefaultsToBlankEditorIfNeeded()
            return
        }
        if let count = parsed.count {
            defaultFixedModeButtonCount = min(max(count, 1), 50)
        }
        if let duration = parsed.durationSeconds {
            defaultFixedModeButtonDuration = min(max(Int(duration.rounded()), 1), 120)
        }
        if let interval = parsed.intervalSeconds {
            defaultFixedModeButtonInterval = min(max(Int(interval.rounded()), 1), 120)
        }
        applyDefaultsToBlankEditorIfNeeded()
    }

    func setDefaultFixedModeButtonCount(_ count: Int) {
        defaultFixedModeButtonCount = min(max(count, 1), 50)
        if defaultFixedModeInputStyle == .text {
            defaultFixedModeQueryDraft = FixedModeQueryFormatter.phrase(
                count: defaultFixedModeButtonCount,
                duration: defaultFixedModeButtonDuration,
                interval: defaultFixedModeButtonInterval
            )
        }
        applyDefaultsToBlankEditorIfNeeded()
    }

    func setDefaultFixedModeButtonDuration(_ seconds: Int) {
        defaultFixedModeButtonDuration = min(max(seconds, 1), 120)
        if defaultFixedModeInputStyle == .text {
            defaultFixedModeQueryDraft = FixedModeQueryFormatter.phrase(
                count: defaultFixedModeButtonCount,
                duration: defaultFixedModeButtonDuration,
                interval: defaultFixedModeButtonInterval
            )
        }
        applyDefaultsToBlankEditorIfNeeded()
    }

    func setDefaultFixedModeButtonInterval(_ seconds: Int) {
        defaultFixedModeButtonInterval = min(max(seconds, 1), 120)
        if defaultFixedModeInputStyle == .text {
            defaultFixedModeQueryDraft = FixedModeQueryFormatter.phrase(
                count: defaultFixedModeButtonCount,
                duration: defaultFixedModeButtonDuration,
                interval: defaultFixedModeButtonInterval
            )
        }
        applyDefaultsToBlankEditorIfNeeded()
    }

    func setFixedModeButtonCount(_ count: Int) {
        let cleaned = min(max(count, 1), 50)
        guard fixedModeButtonCount != cleaned else { return }

        fixedModeButtonCount = cleaned
        defaultFixedModeButtonCount = cleaned
        rerollFixedModeRandomSeed()
        invalidateRecipePreview(status: "Previewing fixed clip recipe.")
        persistCurrentProject()
    }

    func setFixedModeButtonDuration(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let upperBound: Double
        if let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 {
            upperBound = min(max(durationSeconds, 1), 300)
        } else {
            upperBound = 300
        }
        let cleaned = Int(min(max(seconds.rounded(), 1), upperBound))
        guard fixedModeButtonDuration != cleaned else { return }

        fixedModeButtonDuration = cleaned
        fixedModeRandomDurationMaximum = cleaned
        fixedModeRandomDurationMinimum = min(fixedModeRandomDurationMinimum, fixedModeRandomDurationMaximum)
        defaultFixedModeButtonDuration = cleaned
        rerollFixedModeRandomSeed()
        invalidateRecipePreview(status: "Previewing fixed clip recipe.")
        persistCurrentProject()
    }

    func setFixedModeButtonInterval(_ seconds: Int) {
        let cleaned = min(max(seconds, 1), 300)
        guard fixedModeButtonInterval != cleaned else { return }

        fixedModeButtonInterval = cleaned
        fixedModeRandomIntervalMaximum = cleaned
        fixedModeRandomIntervalMinimum = min(fixedModeRandomIntervalMinimum, fixedModeRandomIntervalMaximum)
        defaultFixedModeButtonInterval = cleaned
        rerollFixedModeRandomSeed()
        invalidateRecipePreview(status: "Previewing fixed clip recipe.")
        persistCurrentProject()
    }

    /// Toggle the lock state of a planned clip. Locked clips can't be
    /// moved or trimmed on the timeline; the user has to unlock them
    /// first (long-press again). Persists with the project file.
    func togglePlannedRangeLock(at index: Int) {
        guard plannedRanges.indices.contains(index) else { return }
        plannedRanges[index].isLocked.toggle()
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
                                endSeconds: updated.endSeconds,
                                reason: updated.reason,
                                isLocked: updated.isLocked,
                                cutMode: updated.cutMode)
        }
        if index < plannedRanges.count - 1 {
            let nextStart = plannedRanges[index + 1].startSeconds
            updated = ClipRange(startSeconds: updated.startSeconds,
                                endSeconds: min(updated.endSeconds, nextStart),
                                reason: updated.reason,
                                isLocked: updated.isLocked,
                                cutMode: updated.cutMode)
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

    /// User selected a new Highlight clip duration. Mark the duration as
    /// manually overridden and persist it as the Highlight default. If a
    /// source is loaded, seed or resize
    /// the draft immediately so the timeline reflects the selected length.
    func setHighlightDuration(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let requested = max(seconds, 0.5)

        if let total = durationSeconds, total.isFinite, total > 0 {
            let cleaned = min(requested, total)
            highlightDraftDuration = cleaned

            let currentStart = highlightDraftStart ?? scrubPositionSeconds
            highlightDraftStart = min(max(currentStart, 0), max(0, total - cleaned))
        } else {
            highlightDraftDuration = requested
        }

        defaultHighlightDuration = Int(min(max(highlightDraftDuration.rounded(), 1), 120))
        hasManualHighlightDuration = true
    }

    /// Called when Splice mode is entered. Seeds the duration from the
    /// current Splice default and, when a source is loaded, places the
    /// draft at the start so the user has an immediate draggable band.
    func enterHighlightMode() {
        highlightDraftDuration = Double(defaultHighlightDuration)
        hasManualHighlightDuration = false
        if let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 {
            highlightDraftStart = nil
            seedHighlightDraftIfNeeded(totalDuration: durationSeconds)
        } else {
            highlightDraftStart = nil
        }
    }

    private func seedHighlightDraftIfNeeded(totalDuration: Double) {
        guard cutMode == .highlight,
              totalDuration.isFinite,
              totalDuration > 0
        else { return }

        let defaultDuration = Double(defaultHighlightDuration)
        let clampedDuration = min(max(defaultDuration, 0.1), totalDuration)

        if highlightDraftStart == nil {
            highlightDraftDuration = clampedDuration
            highlightDraftStart = 0
            hasManualHighlightDuration = false
            return
        }

        highlightDraftDuration = min(max(highlightDraftDuration, 0.1), totalDuration)
        let maxStart = max(0, totalDuration - highlightDraftDuration)
        highlightDraftStart = min(max(highlightDraftStart ?? 0, 0), maxStart)
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
        let snappedStart = ClipRangeEditor.snap(
            clamped,
            frameDuration: frameDurationSeconds,
            totalDuration: total
        )
        highlightDraftStart = min(max(snappedStart, 0), max(0, total - width))
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

    /// Set the draft's start time directly (left-edge drag). The end stays
    /// anchored, so the draft resizes instead of sliding. Clamped and snapped
    /// so the band stays inside the source and at least 0.5s wide.
    func setHighlightStart(_ newStart: Double) {
        guard let total = durationSeconds,
              total > 0,
              let draft = highlightDraft
        else { return }

        let edited = ClipRangeEditor.updatedRange(
            draft,
            totalDuration: total,
            frameDuration: frameDurationSeconds,
            startSeconds: newStart,
            endSeconds: draft.endSeconds,
            minimumDuration: 0.5
        )
        highlightDraftStart = edited.startSeconds
        highlightDraftDuration = edited.duration
    }

    /// Set the draft's end time directly (right-edge drag). The start
    /// stays put, the duration follows. Clamped and snapped similarly.
    func setHighlightEnd(_ newEnd: Double) {
        guard let total = durationSeconds,
              total > 0,
              let draft = highlightDraft
        else { return }

        let edited = ClipRangeEditor.updatedRange(
            draft,
            totalDuration: total,
            frameDuration: frameDurationSeconds,
            startSeconds: draft.startSeconds,
            endSeconds: newEnd,
            minimumDuration: 0.5
        )
        highlightDraftStart = edited.startSeconds
        highlightDraftDuration = edited.duration
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
        // Explicitly stamp .highlight on the snapped range so the
        // per-mode filter (visiblePlannedRangeIndices /
        // plannedRangesForCurrentMode) reliably shows it in the
        // Splice section. The default `CutMode = .highlight` on
        // `ClipRange` already covers this, but being explicit here
        // insulates the splice-section routing from any future
        // default-mode flip.
        var stampedSnapped = snapped
        stampedSnapped.cutMode = .highlight
        // Reject the add if it overlaps an existing planned range —
        // overlapping ranges stack their handle hit-zones on top of each
        // other and one becomes unselectable.
        for existing in plannedRanges {
            if existing.cutMode == .highlight,
               stampedSnapped.startSeconds < existing.endSeconds,
               stampedSnapped.endSeconds > existing.startSeconds {
                statusMessage = "That overlaps an existing clip — move the highlight to an empty part."
                return
            }
        }
        // Replace-target swap (per-clip "Replace with…" flow):
        // when a row's context menu set `replacingPlannedRangeIndex`,
        // swap that single planned range in place instead of
        // appending, then advance the draft cursor the same way the
        // append path does. The mode guard in
        // `beginReplacingPlannedRange` ensures the row's mode
        // matches `cutMode`, but check defensively here in case
        // state raced between the menu tap and this Add.
        if let targetIdx = replacingPlannedRangeIndex,
           plannedRanges.indices.contains(targetIdx) {
            plannedRanges[targetIdx] = stampedSnapped
            replacingPlannedRangeIndex = nil
            clips = []
            let nextStart = stampedSnapped.endSeconds
            if nextStart < total - 0.5 {
                highlightDraftStart = nextStart
            } else {
                highlightDraftStart = nil
            }
            // "Swapped" instead of "Added" so the user knows the
            // recipe replaced a row rather than appending a new
            // one. Same mode-scoped count as the append path so the
            // number matches the row they tapped.
            statusMessage = "Swapped highlight \(visiblePlannedRanges.count)."
            invalidateShuffle()
            persistCurrentProject()
            return
        }
        plannedRanges.append(stampedSnapped)
        clips = []
        let nextStart = stampedSnapped.endSeconds
        if nextStart < total - 0.5 {
            highlightDraftStart = nextStart
        } else {
            // Reached the end — clear the draft so the user explicitly
            // picks the next spot.
            highlightDraftStart = nil
        }
        // Use the visible (mode-scoped) count so the message matches
        // the timeline number. If the user is in highlight mode with
        // 3 existing highlight clips, the message says "Added clip 4"
        // — the 4th highlight — not "Added clip 7" (the 7th entry in
        // the full plannedRanges array including non-highlight clips).
        statusMessage = "Added clip \(visiblePlannedRanges.count) to the plan."
        persistCurrentProject()
    }

    /// Discard the draft without adding to the plan.
    func clearHighlightDraft() {
        highlightDraftStart = nil
    }

    /// Per-recipe "Reset" — clears the CURRENT recipe's draft
    /// fields back to the user's saved defaults. Does NOT touch
    /// `plannedRanges` and does NOT change `cutMode` — the mode
    /// tab the user is currently on is a separate choice from
    /// the recipe's inputs, and stomping it on Reset had a nasty
    /// side effect:
    ///
    /// When the user clicked Add in the Fixed tab, the call was
    /// `prepareCuts()` (which dispatches an async Task) followed
    /// immediately by `resetCurrentRecipeFields()`. The reset
    /// previously routed through `applyDefaultClipSettings` which
    /// sets `cutMode = defaultCutMode`, so by the time the async
    /// Task body read `self.cutMode` for its `switch`, the value
    /// was the user's saved default (e.g. AI) — not the Fixed tab
    /// they actually clicked on. The Task then ran the AI
    /// assessment instead of the Fixed grid cuts. Each Add button
    /// should be specific to its own recipe; this method now
    /// stays out of `cutMode`'s way so Add works correctly in
    /// every tab.
    func resetCurrentRecipeFields() {
        switch cutMode {
        case .fixed:
            fixedModeInputStyle = defaultFixedModeInputStyle
            fixedModeQueryDraft = resolvedDefaultFixedModeQueryDraft
            fixedModeButtonCount = defaultFixedModeButtonCount
            fixedModeButtonDuration = defaultFixedModeButtonDuration
            fixedModeButtonInterval = defaultFixedModeButtonInterval
            fixedModeRandomDuration = false
            fixedModeRandomInterval = false
            fixedModeRandomDurationMinimum = 1
            fixedModeRandomDurationMaximum = defaultFixedModeButtonDuration
            fixedModeRandomIntervalMinimum = 1
            fixedModeRandomIntervalMaximum = defaultFixedModeButtonInterval
            rerollFixedModeRandomSeed()
            // Fixed mode reads `segmentLengthText` for the legacy
            // stepper path — keep it on the silence default.
            segmentLengthText = "\(defaultSilenceClipDuration)"
        case .smartPause:
            segmentLengthText = "\(defaultSilenceClipDuration)"
        case .aiAssist:
            editPrompt = defaultEditPrompt
            segmentLengthText = "\(defaultAiClipDuration)"
        case .highlight:
            highlightDraftStart = nil
            highlightDraftDuration = Double(defaultHighlightDuration)
            hasManualHighlightDuration = false
        }
        statusMessage = "Cut recipe reset to defaults."
        persistCurrentProject()
    }

    /// Per-recipe "Add" — runs the active recipe, adds the
    /// result to `plannedRanges`, then clears the recipe's
    /// draft fields. Unified across the four modes so the
    /// button reads the same regardless of which recipe the
    /// user is in. The plan is independent of the recipe
    /// inputs — multiple Add taps accumulate, Reset wipes the
    /// inputs but not the plan, and the project-level "Save"
    /// is the step that promotes the plan to the saved row.
    ///
    /// For Highlight mode, `addHighlightDraftToPlan()` already
    /// adds the draft to the plan AND auto-advances the start
    /// pointer to the end of the just-added clip (a deliberate
    /// "walk the timeline left-to-right" affordance), so we
    /// don't need to clear the draft fields — the next Add tap
    /// places the band at the new position.
    func addRecipeToPlannedAndReset(for requestedMode: CutMode? = nil) {
        // Bind the operation to the mode at tap time. This matters when the
        // Add action is resumed after the paywall or while an async planner
        // is finishing: reading `cutMode` later could route a Fixed/Silence/
        // AI result into the tab the user switched to in the meantime.
        let mode = requestedMode ?? cutMode
        if cutMode != mode {
            cutMode = mode
        }

        if mode == .highlight {
            addHighlightDraftToPlan()
            return
        }
        // For Cut / SmartPause / AI: dispatch the run first (it
        // reads the field values synchronously at the top of the
        // function before dispatching its async work, so clearing
        // the fields right after is safe — the dispatched Task
        // already captured what it needs).
        prepareCuts()
        resetCurrentRecipeFields()
    }

    /// Local "Save" action. Snapshots only the active recipe's
    /// visible planned clips into the persisted `savedClips` list so
    /// the row-level save matches what the user can currently see in
    /// Planned clips. Lightweight — does NOT render anything; the
    /// "Export" button is the step that actually produces video
    /// files. Independent of the per-recipe Add/Reset flow.
    func commitPlannedToSaved() {
        let recipeRanges = plannedRangesForCurrentMode
        savedClips = recipeRanges
        // New save = new canonical order. Any shuffle the user
        // applied to the previous saved row is stale (its
        // permutation points into the old list).
        invalidateSavedClipsShuffle()
        statusMessage = savedClips.isEmpty
            ? "No \(cutMode.rawValue.lowercased()) clips to save."
            : "Saved \(savedClips.count) \(cutMode.rawValue.lowercased()) clip\(savedClips.count == 1 ? "" : "s")."
        persistCurrentProject()
    }

    /// Wipe the persisted saved row. Triggered by a "Clear saved"
    /// action so the user can start fresh without losing their
    /// planned ranges. Does not touch `plannedRanges` — that's
    /// the in-editor working state.
    func clearSavedClips() {
        guard !savedClips.isEmpty else { return }
        savedClips = []
        invalidateSavedClipsShuffle()
        statusMessage = "Cleared saved clips."
        persistCurrentProject()
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
        guard let sourceURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            errorMessage = "Pick a video first."
            return
        }
        guard let durationSnapshot = durationSeconds,
              durationSnapshot.isFinite,
              durationSnapshot > 0 else {
            // Do not start an async planning task that will try to read the
            // asset again while an import or scene switch is still settling.
            // The Add button also uses this same invariant via `canPrepare`.
            errorMessage = "The video is still loading. Wait for the duration to appear, then try again."
            statusMessage = "Waiting for video duration."
            return
        }
        guard let segmentLength = parsedSegmentLength else {
            errorMessage = "Enter a segment length of at least 1 second."
            return
        }
        let mode = cutMode
        let fixedQuery = effectiveFixedQuery.map {
            ClipQuery(
                count: $0.count,
                durationSeconds: $0.durationSeconds,
                intervalSeconds: $0.intervalSeconds
            )
        }
        let fixedInputStyleSnapshot = fixedModeInputStyle
        let fixedButtonCountSnapshot = fixedModeButtonCount
        let fixedButtonDurationSnapshot = fixedModeButtonDuration
        let fixedButtonIntervalSnapshot = fixedModeButtonInterval
        let fixedRandomDurationSnapshot = fixedModeRandomDuration
        let fixedRandomIntervalSnapshot = fixedModeRandomInterval
        let fixedRandomDurationRangeSnapshot = fixedModeRandomDurationRange
        let fixedRandomIntervalRangeSnapshot = fixedModeRandomIntervalRange
        let fixedRandomSeedSnapshot = fixedModeRandomSeed
        let frameDurationSnapshot = frameDurationSeconds
        let tierSnapshot = currentTier
        let editPromptSnapshot = editPrompt
        let providerSnapshot = selectedAIProvider
        let selectionRangesSnapshot = selectedAnalysisRanges
        let transcriptSnapshot = transcript
        let statusSnapshot = Self.analysisStatusMessage(
            for: mode,
            scoped: !selectionRangesSnapshot.isEmpty
        )
        let sceneIDSnapshot = activeSceneId

        // Headroom guard: a recipe with explicit count + duration on a source
        // shorter than one clip should fail loudly, not silently clamp to zero
        // ranges. Catch it before any work is dispatched.
        if mode == .fixed, recipeHasNoHeadroom,
           let durationSeconds, durationSeconds > 0 {
            errorMessage = "Source is shorter than one clip. Trim a clip ≤ \(Int(durationSeconds))s, shorten the source, or switch to Smart Pause / Highlight."
            statusMessage = "Recipe needs more source than is available."
            return
        }

        // Free-tier AI quota gate. Paid tiers have unlimited runs.
        if mode == .aiAssist, tierSnapshot == .free, !canRunAnotherFreeAIPlan {
            errorMessage = "You've used your \(MediaProcessingLimits.monthlyFreeAIQuota) free AI plans for this month. Upgrade to Creator from Settings to keep going."
            statusMessage = "Free-tier AI plan quota reached."
            return
        }

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }

            let accruedRanges = plannedRanges
            processingPhase = .analyzing
            progress = 0
            clips = []
            errorMessage = nil
            statusMessage = statusSnapshot

            // Count the request when the AI task is dispatched, not only
            // after a successful result. UserDefaults persistence keeps a
            // consumed Free use accounted for if the app is force-closed
            // while Apple Intelligence is still working.
            if mode == .aiAssist, tierSnapshot == .free {
                recordAIPlanInvocation()
            }

            do {
                let ranges: [ClipRange]

                switch mode {
                case .fixed:
                    let durationSeconds = durationSnapshot
                    let fresh: [ClipRange]
                    if fixedInputStyleSnapshot == .buttons,
                       fixedRandomDurationSnapshot || fixedRandomIntervalSnapshot {
                        fresh = Self.randomizedFixedRanges(
                            totalDuration: durationSeconds,
                            requestedCount: fixedButtonCountSnapshot,
                            baseDuration: fixedButtonDurationSnapshot,
                            baseInterval: fixedButtonIntervalSnapshot,
                            durationRange: fixedRandomDurationRangeSnapshot,
                            intervalRange: fixedRandomIntervalRangeSnapshot,
                            randomizeDuration: fixedRandomDurationSnapshot,
                            randomizeInterval: fixedRandomIntervalSnapshot,
                            seed: fixedRandomSeedSnapshot
                        )
                    } else if let queryRanges = fixedQuery?.ranges(forSourceDuration: durationSeconds),
                              !queryRanges.isEmpty {
                        // Natural language parsed query takes precedence over the
                        // numeric stepper when it produces actual cuts.
                        fresh = queryRanges
                    } else {
                        fresh = try Self.fixedRanges(
                            totalDuration: durationSeconds,
                            segmentLength: segmentLength,
                            frameDuration: frameDurationSnapshot,
                            tier: tierSnapshot
                        )
                    }
                    ranges = fresh.map { range in
                        var stamped = range
                        stamped.cutMode = mode
                        return stamped
                    }
                case .smartPause:
                    let fresh: [ClipRange]
                    if let transcriptRanges = Self.transcriptSpeechRanges(
                        transcriptSnapshot,
                        within: selectionRangesSnapshot,
                        totalDuration: durationSnapshot
                    ) {
                        fresh = transcriptRanges
                    } else {
                        fresh = try await smartCutAnalyzer.nonSilentRanges(
                            for: sourceURL,
                            within: selectionRangesSnapshot,
                            fallbackSegmentLength: segmentLength
                        )
                    }
                    ranges = fresh.map { range in
                        var stamped = range
                        stamped.cutMode = mode
                        return stamped
                    }
                case .highlight:
                    // Highlight mode is now fully manual — the user picks
                    // positions/durations on the timeline themselves. We do
                    // NOT auto-detect anything here; the planned ranges are
                    // whatever the user has already added via the "Add to
                    // plan" affordance. If they haven't added any yet, this
                    // is a no-op. Preserve each accrued range's existing
                    // cutMode — DO NOT stamp everything to .highlight,
                    // which would clobber cross-mode work the user did in
                    // Cut / Silence / AI tabs and route it all into the
                    // Splice section on next render. The per-mode filter
                    // (`visiblePlannedRangeIndices`) reads each range's own
                    // cutMode, so leaving them alone is correct.
                    ranges = accruedRanges
                case .aiAssist:
                    let fresh = try await appleIntelligenceRanges(
                        for: sourceURL,
                        fallbackSegmentLength: segmentLength,
                        prompt: editPromptSnapshot,
                        provider: providerSnapshot,
                        tier: tierSnapshot,
                        durationSeconds: durationSnapshot,
                        selectionRanges: selectionRangesSnapshot
                    )
                    ranges = fresh.map { range in
                        var stamped = range
                        stamped.cutMode = mode
                        return stamped
                    }
                }

                if mode == .smartPause, ranges.isEmpty {
                    throw SmartCutAnalyzerError.noSpeechDetected
                }

                try Task.checkCancellation()

                // The source and duration were validated before this task was
                // created. Keep using those snapshots instead of re-reading a
                // mutable URL/state pair after an await.
                let duration = durationSnapshot

                // A scene switch or source replacement may happen while an AI
                // or silence analysis is suspended. Never apply an old result
                // to the newly active scene.
                guard self.activeSceneId == sceneIDSnapshot,
                      self.sourceURL?.standardizedFileURL == sourceURL.standardizedFileURL,
                      self.durationSeconds == durationSnapshot else {
                    statusMessage = "Plan discarded because the active video changed."
                    return
                }
                try MediaProcessingLimits.validateSourceDuration(duration, for: tierSnapshot)
                // Stamp every freshly-planned range with the current
                // cutMode so the timeline filter (liveTimelineRanges)
                // only shows them in the matching mode. Without the
                // stamp, the AI providers + smartCutAnalyzer return
                // ranges with the default .highlight cutMode and the
                // user would see highlight ranges leak into smartPause
                // / aiAssist / fixed mode (or vice versa). The
                // accrual merge below preserves the per-range mode
                // for both existing and generated ranges.
                let stampedRanges = ranges.map { range in
                    var stamped = range
                    stamped.cutMode = mode
                    return stamped
                }
                let normalizedPlan = try MediaProcessingLimits.validatedClipPlan(
                    stampedRanges,
                    totalDuration: duration,
                    frameDuration: frameDurationSnapshot,
                    minimumDuration: mode == .fixed ? min(Self.minimumFixedClipDuration(segmentLength: segmentLength), duration) : MediaProcessingLimits.minimumAIClipDuration
                )
                // `ClipRange` defaults to `.highlight` for legacy decoding.
                // Re-stamp after every normalization step as the final mode
                // boundary so a result can never fall into the Splice list
                // just because an intermediate planner/helper returned a
                // default-valued range.
                let generatedPlan = normalizedPlan.map { range in
                    var stamped = range
                    stamped.cutMode = mode
                    return stamped
                }
                let previousCount = plannedRanges.filter { $0.cutMode == mode }.count
                var didReplaceAtTarget = false
                if mode == .highlight {
                    // Highlight mode: replace. The user is doing
                    // single-clip manual placement via the "Add"
                    // button on the timeline, so the prior plan is
                    // stale by definition once a new plan runs.
                    plannedRanges = generatedPlan
                } else {
                    // Every other mode (Cut / SmartPause / AI): accrue
                    // — append each newly-generated range to the
                    // existing `plannedRanges` if it doesn't overlap
                    // an existing one. Same persistence shape as
                    // the Highlight "Add" button (`addHighlightDraftToPlan`
                    // uses the same overlap rule), so all four
                    // modes surface their results in the planned
                    // clips row without a separate "commit" step.
                    // Replaces the prior `mergedAccruedClipPlan`
                    // helper which had a subtle timing issue where
                    // the planned-clips section didn't always
                    // refresh after the plan run.
                    let tolerance = max(frameDurationSnapshot, 0.05)
                    for range in generatedPlan {
                        let overlaps = plannedRanges.contains { existing in
                            existing.cutMode == mode &&
                            abs(existing.startSeconds - range.startSeconds) < tolerance &&
                            abs(existing.endSeconds - range.endSeconds) < tolerance
                        }
                        if !overlaps {
                            // Replace-target swap (per-clip "Replace
                            // with…" flow): take the FIRST
                            // non-overlapping generated range and
                            // swap it at the row the user picked,
                            // then any subsequent generated ranges
                            // still append. This way a multi-clip
                            // recipe (Cut / Silence / AI commonly
                            // produce N ranges in one run) still
                            // only swaps the one row the user
                            // targeted — the oldest planned range
                            // for the current mode — instead of
                            // overwriting every slot in the row.
                            // `didReplaceAtTarget` ensures exactly
                            // one swap per recipe run even when the
                            // recipe produced several non-overlapping
                            // ranges.
                            if !didReplaceAtTarget,
                               let targetIdx = replacingPlannedRangeIndex,
                               plannedRanges.indices.contains(targetIdx),
                               plannedRanges[targetIdx].cutMode == mode {
                                plannedRanges[targetIdx] = range
                                replacingPlannedRangeIndex = nil
                                didReplaceAtTarget = true
                            } else {
                                plannedRanges.append(range)
                            }
                        }
                    }
                }

                // If a replace target was set but every generated
                // range overlapped an existing clip (or the recipe
                // produced zero ranges for this slice of the
                // timeline), nothing was swapped in. Clear the
                // target so the banner doesn't get stuck on
                // "Swapping clip N" — the user needs to know the
                // recipe didn't change the row, then pick a
                // different recipe. Status message gets surfaced
                // by `prepareCuts` further down when it runs the
                // standard "no clips generated" path.
                if !didReplaceAtTarget, replacingPlannedRangeIndex != nil {
                    replacingPlannedRangeIndex = nil
                }

                guard plannedRanges.contains(where: { $0.cutMode == mode }) else {
                    throw VideoSegmenterError.invalidDuration
                }

                progress = 1
                let currentModeCount = plannedRanges.filter { $0.cutMode == mode }.count
                if mode != .highlight, previousCount > 0 {
                    let addedCount = max(currentModeCount - previousCount, 0)
                    if addedCount > 0 {
                        statusMessage = "Added \(addedCount) clip\(addedCount == 1 ? "" : "s") to the plan."
                    } else {
                        statusMessage = "No new non-overlapping clips to add."
                    }
                } else {
                    statusMessage = "Review \(currentModeCount) planned clips."
                }
                persistCurrentProject()
            } catch is CancellationError {
                statusMessage = "Processing cancelled."
            } catch VideoSegmenterError.cancelled {
                statusMessage = "Processing cancelled."
            } catch {
                let description = error.localizedDescription
                if description.localizedCaseInsensitiveContains("context window") {
                    errorMessage = "This AI request was too large for on-device Apple Intelligence. Try a shorter edit prompt or select fewer clips."
                    statusMessage = "AI request was too large."
                } else {
                    errorMessage = description
                    statusMessage = "Analysis stopped."
                }
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
            prepareExport(target: .activeRecipe)
            return
        }
        confirmPendingExport()
    }

    /// Transcript pane "Process" action. Runs silence detection on the
    /// active scene's source (using `SmartCutAnalyzer`, which is on-device
    /// AVFoundation audio-energy analysis — purpose-built for this task
    /// and the same engine Smart Pause mode already trusts), then hands
    /// the non-silent ranges to `VideoSegmenter.concatenateRangesToSingleMP4`
    /// to produce a single joined MP4 (no per-clip files, no transitions,
    /// just back-to-back speech). Result lands in `tightenedClips` so the
    /// existing export-preview sheet can hand it to Photos.
    ///
    /// Apple Intelligence (`@Generable` planning) was considered as an
    /// alternative but `SmartCutAnalyzer`'s audio-energy windows are
    /// both faster and more accurate for silence detection; AI shines
    /// at semantic planning ("the most interesting 30 seconds") rather
    /// than gap detection. So the on-device audio path wins here.
    func processTranscriptToSingleClip() {
        guard let sourceURL else {
            errorMessage = "Pick a video first."
            return
        }
        guard let total = durationSeconds, total > 0 else {
            errorMessage = "Source duration is unknown."
            return
        }
        guard !isProcessing else { return }

        processingTask?.cancel()
        let tierSnapshot = currentTier
        let segmentLengthSnapshot = parsedSegmentLength ?? 4.0
        let frameDurationSnapshot = frameDurationSeconds
        let selectionRangesSnapshot = selectedAnalysisRanges
        let transcriptSnapshot = transcript

        processingTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                processingPhase = .analyzing
                progress = 0
                errorMessage = nil
                statusMessage = selectionRangesSnapshot.isEmpty
                    ? "Finding silences…"
                    : "Finding silences in the selected clips…"

                // Step 1: silence detection. Scope this to the user's
                // highlighted/curated ranges so Process never silently
                // rewrites the whole source.
                let nonSilent: [ClipRange]
                if let transcriptRanges = Self.transcriptSpeechRanges(
                    transcriptSnapshot,
                    within: selectionRangesSnapshot,
                    totalDuration: total
                ) {
                    nonSilent = transcriptRanges
                } else {
                    nonSilent = try await smartCutAnalyzer.nonSilentRanges(
                        for: sourceURL,
                        within: selectionRangesSnapshot,
                        fallbackSegmentLength: segmentLengthSnapshot
                    )
                }

                try Task.checkCancellation()

                guard !nonSilent.isEmpty else {
                    statusMessage = "No voice or audible content was detected in the selected range."
                    errorMessage = statusMessage
                    processingPhase = .idle
                    progress = 0
                    return
                }

                // Step 2: Apple Intelligence refinement. Hands the
                // initial silence-detected ranges + the timeline
                // feature pack to FoundationModels with a tightening
                // prompt. The model reads the audio-level per point
                // (already in the feature pack) and drops ranges that
                // are too quiet / sound like false starts / contain
                // awkward pauses. Best-effort: if Apple Intelligence
                // is unavailable (older device), or the call fails,
                // we silently fall back to the SmartCutAnalyzer
                // output. The user still gets a tightened clip —
                // just without the AI refinement pass.
                statusMessage = "Refining with Apple Intelligence…"
                let refined = await refineRangesWithAppleIntelligence(
                    initialRanges: nonSilent,
                    sourceURL: sourceURL,
                    fallbackSegmentLength: segmentLengthSnapshot,
                    tier: tierSnapshot,
                    durationSeconds: total,
                    selectionRanges: selectionRangesSnapshot
                )

                try Task.checkCancellation()

                let keptRanges = refined.isEmpty ? nonSilent : refined

                // Step 3: concatenate into one MP4. Stamps each kept
                // range's cutMode so the planned-clip filter still
                // recognises them if the user re-opens the project.
                processingPhase = .exporting
                statusMessage = "Tightening \(keptRanges.count) selected range\(keptRanges.count == 1 ? "" : "s") into one clip…"

                let cutModeSnapshot = cutMode
                let stampedRanges = keptRanges.map { range -> ClipRange in
                    var stamped = range
                    stamped.cutMode = cutModeSnapshot
                    return stamped
                }

                let url = try await segmenter.concatenateRangesToSingleMP4(
                    sourceURL: sourceURL,
                    ranges: stampedRanges,
                    progress: { [weak self] value in
                        Task { @MainActor in
                            self?.progress = value
                        }
                    }
                )

                try Task.checkCancellation()

                let keptTotal = stampedRanges.reduce(0.0) { partial, range in
                    partial + (range.endSeconds - range.startSeconds)
                }

                let output = SegmentOutput(
                    index: 0,
                    title: currentProjectTitle.isEmpty
                        ? "Tightened clip"
                        : "\(currentProjectTitle) — Tightened",
                    url: url,
                    startSeconds: 0,
                    endSeconds: keptTotal,
                    photoLibraryLocalIdentifier: nil
                )

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.tightenedClips = [output]
                    self.tightenedKeptRanges = stampedRanges
                    self.tightenedSourceDuration = total
                    self.tightenedTier = tierSnapshot
                    self.tightenedFrameDuration = frameDurationSnapshot
                    self.showTightenedPreview = true
                }

                let scopeLabel = selectionRangesSnapshot.isEmpty ? "source" : "selected clips"
                statusMessage = "Tightened clip ready — \(Int(keptTotal.rounded()))s of kept speech from the \(scopeLabel)."
                processingPhase = .idle
                progress = 0
            } catch is CancellationError {
                processingPhase = .idle
                progress = 0
            } catch {
                processingPhase = .idle
                progress = 0
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                statusMessage = "Tighten failed."
            }
        }
    }

    /// Save the tightened single-clip output to Photos. Called from
    /// the tightened preview sheet's "Save" button.
    func confirmTightenedExport() {
        guard !tightenedClips.isEmpty else {
            cancelTightenedExport()
            return
        }

        processingTask?.cancel()
        processingTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                processingPhase = .saving
                progress = 0
                statusMessage = "Saving tightened clip to Photos…"
                _ = try await segmenter.saveToPhotoLibrary(
                    tightenedClips,
                    progress: { [weak self] value in
                        Task { @MainActor in
                            self?.progress = value
                        }
                    }
                )
                statusMessage = "Tightened clip saved to Photos."
                processingPhase = .idle
                progress = 0
                showTightenedPreview = false
                tightenedClips = []
                tightenedKeptRanges = []
            } catch is CancellationError {
                processingPhase = .idle
                progress = 0
            } catch {
                processingPhase = .idle
                progress = 0
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Discard the tightened preview without saving. Cleans up the
    /// intermediate file on disk so it doesn't leak into the temp dir.
    func cancelTightenedExport() {
        for clip in tightenedClips {
            try? FileManager.default.removeItem(at: clip.url)
        }
        showTightenedPreview = false
        tightenedClips = []
        tightenedKeptRanges = []
        tightenedSourceDuration = 0
    }

    /// Silence-mode "Smart-Enhance with Apple Intelligence" action.
    /// Takes the user's existing .smartPause planned ranges (already
    /// detected by SmartCutAnalyzer's pure audio-energy analysis),
    /// runs them through FoundationModels to drop ranges that
    /// sound like false starts, awkward pauses, or barely-audible
    /// sections, and replaces the silence-mode planned ranges in
    /// place. Free-tier users are gated to 3 AI plan invocations
    /// per month (`canRunAnotherFreeAIPlan`); the UI surfaces the
    /// paywall before this is called when the quota is hit.
    func enhanceSilenceModeWithAppleIntelligence() {
        guard let sourceURL else {
            errorMessage = "Pick a video first."
            return
        }
        guard !isProcessing else { return }
        guard canRunAnotherFreeAIPlan else {
            errorMessage = "You've used your \(MediaProcessingLimits.monthlyFreeAIQuota) free AI plans for this month. Upgrade to Creator from Settings to keep going."
            statusMessage = "Free-tier AI plan quota reached."
            return
        }
        let currentSilenceRanges = plannedRanges.filter { $0.cutMode == .smartPause }
        guard !currentSilenceRanges.isEmpty else {
            statusMessage = "Run Smart Pause first to plan some clips."
            return
        }
        guard let segmentLength = parsedSegmentLength else {
            errorMessage = "Enter a segment length of at least 1 second."
            return
        }

        processingTask?.cancel()
        let tierSnapshot = currentTier
        let segmentLengthSnapshot = segmentLength

        processingTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                processingPhase = .analyzing
                progress = 0
                errorMessage = nil
                statusMessage = "Refining silence-mode clips with Apple Intelligence…"

                let refined = await refineRangesWithAppleIntelligence(
                    initialRanges: currentSilenceRanges,
                    sourceURL: sourceURL,
                    fallbackSegmentLength: segmentLengthSnapshot,
                    tier: tierSnapshot,
                    durationSeconds: durationSeconds,
                    selectionRanges: currentSilenceRanges
                )

                try Task.checkCancellation()

                guard !refined.isEmpty else {
                    statusMessage = "Apple Intelligence returned no refined ranges — keeping your existing silence-mode clips."
                    processingPhase = .idle
                    progress = 0
                    return
                }

                let removedCount = currentSilenceRanges.count - refined.count

                // Splice the refined ranges back into plannedRanges
                // by removing the old .smartPause rows and appending
                // the refined ones. Other modes' planned ranges are
                // untouched.
                let nonSilencePlanned = plannedRanges.filter { $0.cutMode != .smartPause }
                let stampedRefined = refined.map { range -> ClipRange in
                    var stamped = range
                    stamped.cutMode = .smartPause
                    return stamped
                }
                plannedRanges = nonSilencePlanned + stampedRefined
                invalidateShuffle()
                clips = []

                // Count this as an AI invocation against the
                // monthly quota so free users see the count tick
                // down — same gate as the AI-mode planning path.
                recordAIPlanInvocation()

                if removedCount > 0 {
                    statusMessage = "Refined \(refined.count) silence-mode clips (dropped \(removedCount) awkward/false-start ranges)."
                } else {
                    statusMessage = "Refined \(refined.count) silence-mode clips — all kept by Apple Intelligence."
                }
                processingPhase = .idle
                progress = 0
                persistCurrentProject()
            } catch is CancellationError {
                processingPhase = .idle
                progress = 0
            } catch {
                processingPhase = .idle
                progress = 0
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                statusMessage = "Smart-Enhance failed."
            }
        }
    }

    /// Step 1 of the save flow: render the planned ranges to a temp directory and
    /// surface the results in a preview sheet. The user must confirm before anything
    /// touches the photo library.
    ///
    /// `target` controls which scene(s) to render. Defaults to the
    /// active scene (the pre-Phase-5 behavior). Use `.activeRecipe`
    /// for the current mode's visible planned clips, and `.allScenes` to
    /// render every scene in the project with its own source — each
    /// scene's clips are rendered against the segmenter directly (no
    /// in-memory source swap), so per-scene source video (Phase 4) is
    /// respected. Missing-source scenes are skipped with a status
    /// message rather than failing the whole export.
    func prepareExport(target: ExportTarget = .activeScene) {
        exportTarget = target
        saveCurrentStateIntoSceneList(updatedAt: Date())
        let flatExportPlan = flatExportClips(for: target)
        let usesShuffledOrder = target == .allScenes && isShuffled
        let tierSnapshot = currentTier
        let exportSettingsSnapshot = projectExportSettings
        let durationSnapshot = durationSeconds
        let frameDurationSnapshot = frameDurationSeconds

        // Resolve the target into a flat list of clips to render. Each
        // clip knows its source scene (which provides the source URL
        // + cached duration) and its position within that scene's
        // range list. The flat list is what the segmenter iterates,
        // optionally reordered by `shuffledOrder` (cross-scene
        // shuffle). Pre-checks here surface "no scenes / no clips"
        // errors before spinning up the render task.
        switch target {
        case .activeRecipe, .activeScene:
            guard !scenes.isEmpty else {
                errorMessage = "No active scene to export."
                return
            }
            guard !flatExportPlan.isEmpty else {
                errorMessage = "Plan \(cutMode.rawValue.lowercased()) clips before exporting."
                return
            }
        case .specificScene(let id):
            guard let scene = scenes.first(where: { $0.id == id }) else {
                errorMessage = "That scene no longer exists."
                return
            }
            guard !scene.plannedRanges.isEmpty else {
                errorMessage = "\(scene.name) has no planned clips."
                return
            }
        case .allScenes:
            guard !scenes.isEmpty else {
                errorMessage = "No scenes to export."
                return
            }
            guard !flatExportPlan.isEmpty else {
                errorMessage = "Plan clips before exporting."
                return
            }
        }

        do {
            let estimatedBytes = estimatedExportBytes(
                for: flatExportPlan,
                appendsOutro: VideoSegmenter.shouldAppendOutro(forTier: tierSnapshot)
            )
            try mediaWorkspace.validateAvailableCapacity(additionalBytes: estimatedBytes)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusMessage = "Not enough free space to render this export."
            return
        }

        processingTask?.cancel()
        // Creator priority: schedule the entire render-and-save flow at
        // the tier-appropriate QoS (`.userInitiated` for Creator,
        // `.utility` for Free). The system scheduler promotes paid
        // exports ahead of background Free renders.
        let exportPriority = ExportBackgroundTaskManager.exportQoS(for: tierSnapshot)
        processingTask = Task(priority: exportPriority) { [weak self] in
            guard let self else { return }

            processingPhase = .exporting
            progress = 0
            errorMessage = nil
            pendingExportMissingScenes = []
            let totalClips = flatExportPlan.count
            statusMessage = totalClips == 1
                ? "Rendering clip for preview..."
                : (usesShuffledOrder
                    ? "Rendering \(totalClips) clips in shuffled order..."
                    : "Rendering \(totalClips) clips...")
            let exportProjectTitle = currentProjectTitle
            await exportNotifications.prepareForExportNotifications()
            exportBackgroundTasks.beginExportTask(named: "ReelClips Preview") { [weak self] in
                self?.processingTask?.cancel()
                self?.statusMessage = "Preview stopped while the app was in the background."
            }
            defer {
                exportBackgroundTasks.endExportTask()
            }

            var aggregated: [SegmentOutput] = []
            var sceneLabels: [UUID: String] = [:]
            var missing: [SkippedSceneExport] = []

            do {
                // Group the flat (possibly-shuffled) clip list by scene.
                // Within a scene, pass the ranges in the order they appear
                // in the flat list — the segmenter returns clips in the same
                // order, so we can recover the per-scene batch then walk the
                // flat list again to interleave across scenes.
                let flat = flatExportPlan
                let byScene: [Int: [FlatExportClip]] = Dictionary(
                    grouping: flat
                ) { $0.sceneIndex }

                // Map from (sceneIndex, original clipIndex in that scene) →
                // output clip. This is robust when the user shuffles clips
                // within a scene: the segmenter returns outputs in the order
                // we pass `rangesInOrder`, so we zip that returned order
                // back to the original flat-list entries.
                var renderedByClipKey: [String: SegmentOutput] = [:]
                var totalRendered = 0

                // Sort scene indices so the per-scene render proceeds in scene
                // order, keeping the existing "Rendered scene X of Y" UX. The
                // final aggregated list is reordered to the flat (shuffled)
                // order regardless.
                let orderedSceneIndices = byScene.keys.sorted()

                for sceneIndex in orderedSceneIndices {
                    guard let group = byScene[sceneIndex] else { continue }
                    let scene = group[0].scene
                    let rangesInOrder = group.map { $0.range }
                    let sceneSourceURL = group[0].sourceURL

                    try Task.checkCancellation()

                    // Skip scenes with no source on disk. Remaining scenes
                    // continue rendering.
                    guard let sceneSourceURL,
                          FileManager.default.fileExists(atPath: sceneSourceURL.path) else {
                        missing.append(SkippedSceneExport(sceneName: scene.name, reason: "Source video missing"))
                        continue
                    }

                    do {
                        let sceneDuration = scene.durationSeconds ?? durationSnapshot
                        let sceneFrameDuration = scene.frameDurationSeconds ?? frameDurationSnapshot
                        guard let total = sceneDuration, total > 0 else {
                            missing.append(SkippedSceneExport(sceneName: scene.name, reason: "Missing source duration"))
                            continue
                        }

                        try MediaProcessingLimits.validateSourceDuration(total, for: tierSnapshot)
                        let safeRanges = try MediaProcessingLimits.validatedClipPlan(
                            rangesInOrder,
                            totalDuration: total,
                            frameDuration: sceneFrameDuration
                        )
                        // Titles follow the per-scene order so they map to the
                        // output clip positions exactly.
                        let titles = clipTitlesForRanges(safeRanges, sceneName: scene.name)
                        let sceneClipCount = safeRanges.count
                        let sceneSpan = Double(sceneClipCount) / Double(max(totalClips, 1))
                        // Capture the current `totalRendered` into a local so the
                        // progress closure sees a stable value for this scene's
                        // segment. `totalRendered` is mutated later in the loop
                        // body after the segmenter returns, but the closure
                        // runs *during* the call, so it needs the pre-call value.
                        let renderedSoFar = totalRendered

                        let rendered = try await segmenter.segmentVideo(
                            sourceURL: sceneSourceURL,
                            ranges: safeRanges,
                            clipTitles: titles,
                            progress: { [weak self] value in
                                guard let self else { return }
                                let clamped = min(max(value, 0), 1)
                                // Per-clip progress within this scene's segment
                                // of the total. We weight by the scene's share
                                // of the total clip count so multi-scene exports
                                // advance steadily.
                                self.progress = min(1, (Double(renderedSoFar) / Double(max(totalClips, 1))) + clamped * sceneSpan)
                            },
                            tier: tierSnapshot,
                            settings: exportSettingsSnapshot
                        )

                        try Task.checkCancellation()

                        for (offset, clip) in rendered.enumerated() {
                            if group.indices.contains(offset) {
                                let entry = group[offset]
                                renderedByClipKey[Self.exportClipKey(sceneIndex: entry.sceneIndex, clipIndex: entry.clipIndex)] = clip
                            }
                            sceneLabels[clip.id] = scene.name
                        }
                        totalRendered += rendered.count

                        if totalClips > 1 {
                            progress = Double(totalRendered) / Double(totalClips)
                            statusMessage = usesShuffledOrder
                                ? "Rendered \(totalRendered) of \(totalClips) clips in shuffled order"
                                : "Rendered \(totalRendered) of \(totalClips) clips (\(scene.name))"
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch VideoSegmenterError.cancelled {
                        throw VideoSegmenterError.cancelled
                    } catch {
                        missing.append(
                            SkippedSceneExport(
                                sceneName: scene.name,
                                reason: Self.exportSkipReason(for: error)
                            )
                        )
                        continue
                    }
                }

                try Task.checkCancellation()

                // Final pass: walk the flat list in export order (shuffled
                // or canonical) and pluck each clip by its original
                // scene/range key. This is what makes cross-scene and
                // same-scene shuffle visible to the user.
                for entry in flat {
                    let key = Self.exportClipKey(sceneIndex: entry.sceneIndex, clipIndex: entry.clipIndex)
                    guard let rendered = renderedByClipKey[key] else { continue }
                    aggregated.append(rendered)
                }

                pendingExportClips = aggregated
                pendingExportSceneLabels = sceneLabels
                pendingExportMissingScenes = missing
                processingPhase = .idle
                let count = aggregated.count
                if count == 0 {
                    let skipped = missing.map(\.displayText).joined(separator: ", ")
                    statusMessage = "No clips rendered. \(missing.isEmpty ? "" : "Skipped: \(skipped).")"
                    isShowingExportPreview = false
                } else {
                    let suffix = missing.isEmpty
                        ? ""
                        : " (skipped: \(missing.count) scene\(missing.count == 1 ? "" : "s"))"
                    statusMessage = "Review \(count) clip\(count == 1 ? "" : "s") before saving.\(suffix)"
                    isShowingExportPreview = true
                }
            } catch is CancellationError {
                mediaWorkspace.removeDirectories(for: aggregated)
                statusMessage = "Preview cancelled."
            } catch VideoSegmenterError.cancelled {
                mediaWorkspace.removeDirectories(for: aggregated)
                statusMessage = "Preview cancelled."
            } catch {
                mediaWorkspace.removeDirectories(for: aggregated)
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

    /// Build per-clip titles for a given set of ranges. The scene
    /// name is prefixed to the title so a multi-scene export's
    /// preview sheet can show "Scene 1 — Clip 03" rather than
    /// "Clip 03" for every entry. Used by `prepareExport` to build
    /// the title list passed to the segmenter.
    private func clipTitlesForRanges(_ ranges: [ClipRange], sceneName: String) -> [String] {
        ranges.enumerated().map { offset, _ in
            "\(sceneName) · \(String(format: "%02d", offset + 1))"
        }
    }

    private static func exportClipKey(sceneIndex: Int, clipIndex: Int) -> String {
        "\(sceneIndex):\(clipIndex)"
    }

    private static func exportSkipReason(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }

        let fallback = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Could not render this scene" : fallback
    }

    private func estimatedExportBytes(
        for plan: [FlatExportClip],
        appendsOutro: Bool
    ) -> Int64 {
        let estimated = plan.reduce(0.0) { total, entry in
            guard let sourceURL = entry.sourceURL,
                  FileManager.default.fileExists(atPath: sourceURL.path) else {
                return total
            }
            let sourceDuration = entry.scene.durationSeconds
                ?? (sourceURL.standardizedFileURL == self.sourceURL?.standardizedFileURL
                    ? durationSeconds
                    : nil)
                ?? 0
            guard sourceDuration > 0 else { return total }

            let sourceBytes = Double(mediaWorkspace.fileSize(at: sourceURL))
            let clipDuration = max(entry.range.endSeconds - entry.range.startSeconds, 0)
            let outroDuration = appendsOutro ? CMTimeGetSeconds(OutroRenderer.duration) : 0
            return total + sourceBytes * ((clipDuration + outroDuration) / sourceDuration)
        }

        // Export settings and container overhead can exceed the source-bitrate
        // estimate. MediaWorkspace adds a separate 512 MB system reserve.
        let withHeadroom = (estimated * 1.25).rounded(.up)
        guard withHeadroom.isFinite, withHeadroom < Double(Int64.max) else {
            return Int64.max
        }
        return Int64(withHeadroom)
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
                pendingExportSceneLabels = [:]
                pendingExportMissingScenes = []
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

    func removePendingExportClip(_ clip: SegmentOutput) {
        guard var pending = pendingExportClips,
              let index = pending.firstIndex(where: { $0.id == clip.id }) else { return }

        let removed = pending.remove(at: index)
        mediaWorkspace.removeFile(for: removed)
        pendingExportClips = pending
        pendingExportSceneLabels[removed.id] = nil
        statusMessage = pending.isEmpty
            ? "Export queue is empty."
            : "Removed 1 clip. \(pending.count) clip\(pending.count == 1 ? "" : "s") still queued."
    }

    /// Step 2 alt: discard the rendered clips without saving.
    func cancelPendingExport() {
        if let pending = pendingExportClips, !pending.isEmpty {
            // Reap the temp files the segmenter produced.
            mediaWorkspace.removeDirectories(for: pending)
        }
        pendingExportClips = nil
        pendingExportSceneLabels = [:]
        pendingExportMissingScenes = []
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
        mediaImportTask?.cancel()
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
            mediaWorkspace.cleanupDerivedMedia(
                olderThan: Date().addingTimeInterval(-30 * 24 * 60 * 60)
            )
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

        // Fresh projects start in Splice so the first imported clip
        // immediately has a draggable selection. Existing projects
        // still restore their saved mode in loadProject(_:).
        applyFreshSpliceDefaults(clearPlannedState: false)
    }

    func resetClipDefaults() {
        // Reset only the CURRENT clip recipe back to the user's saved
        // defaults — not the persistent defaults themselves. The old
        // behaviour wiped the saved defaults to factory, which made
        // "Reset" destructive and lossy: a user who customised their
        // defaults would lose them every time they hit the button.
        // Now the button is a non-destructive "go back to my saved
        // recipe" — saved defaults stay intact.
        applyDefaultClipSettings(clearPlannedState: true)
        statusMessage = "Cut recipe reset to defaults."
        persistCurrentProject()
    }

    private func applyDefaultClipSettings(clearPlannedState: Bool) {
        cutMode = defaultCutMode
        // Per-mode default for the now-active cutMode so a
        // "Reset Recipe" lands on the right starting value for
        // whichever mode the user is using.
        segmentLengthText = "\(defaultSegmentLengthForMode(defaultCutMode))"
        editPrompt = defaultEditPrompt
        highlightDraftStart = nil
        highlightDraftDuration = Double(defaultHighlightDuration)
        hasManualHighlightDuration = false
        fixedModeInputStyle = defaultFixedModeInputStyle
        fixedModeQueryDraft = resolvedDefaultFixedModeQueryDraft
        fixedModeButtonCount = defaultFixedModeButtonCount
        fixedModeButtonDuration = defaultFixedModeButtonDuration
        fixedModeButtonInterval = defaultFixedModeButtonInterval
        fixedModeRandomDuration = false
        fixedModeRandomInterval = false
        fixedModeRandomDurationMinimum = 1
        fixedModeRandomDurationMaximum = defaultFixedModeButtonDuration
        fixedModeRandomIntervalMinimum = 1
        fixedModeRandomIntervalMaximum = defaultFixedModeButtonInterval
        rerollFixedModeRandomSeed()

        if clearPlannedState {
            plannedRanges = []
            clips = []
            pendingExportClips = nil
            pendingExportSceneLabels = [:]
            pendingExportMissingScenes = []
            progress = 0
        }
    }

    private func applyFreshSpliceDefaults(clearPlannedState: Bool) {
        cutMode = .highlight
        segmentLengthText = "\(defaultSegmentLengthForMode(.highlight))"
        editPrompt = defaultEditPrompt
        highlightDraftStart = nil
        highlightDraftDuration = Double(defaultHighlightDuration)
        hasManualHighlightDuration = false
        fixedModeInputStyle = defaultFixedModeInputStyle
        fixedModeQueryDraft = resolvedDefaultFixedModeQueryDraft
        fixedModeButtonCount = defaultFixedModeButtonCount
        fixedModeButtonDuration = defaultFixedModeButtonDuration
        fixedModeButtonInterval = defaultFixedModeButtonInterval
        fixedModeRandomDuration = false
        fixedModeRandomInterval = false
        fixedModeRandomDurationMinimum = 1
        fixedModeRandomDurationMaximum = defaultFixedModeButtonDuration
        fixedModeRandomIntervalMinimum = 1
        fixedModeRandomIntervalMaximum = defaultFixedModeButtonInterval
        rerollFixedModeRandomSeed()

        if clearPlannedState {
            plannedRanges = []
            clips = []
            pendingExportClips = nil
            pendingExportSceneLabels = [:]
            pendingExportMissingScenes = []
            progress = 0
        }
    }

    private func applyDefaultsToBlankEditorIfNeeded() {
        guard currentProjectID == nil,
              activeSceneId == nil,
              scenes.isEmpty,
              sourceURL == nil,
              durationSeconds == nil
        else { return }

        applyDefaultClipSettings(clearPlannedState: true)
    }

    private var resolvedDefaultFixedModeQueryDraft: String {
        let trimmed = defaultFixedModeQueryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return FixedModeQueryFormatter.phrase(
            count: defaultFixedModeButtonCount,
            duration: defaultFixedModeButtonDuration,
            interval: defaultFixedModeButtonInterval
        )
    }

    private func cancelPreviewLoading() {
        previewTask?.cancel()
        waveformTask?.cancel()
    }

    private func beginMediaImport(status: String) -> UUID? {
        guard !isImportingMedia,
              mediaImportTask == nil
        else {
            statusMessage = "Finish the current import before choosing another video."
            return nil
        }

        let importID = UUID()
        activeMediaImportID = importID
        isImportingMedia = true
        processingPhase = .loading
        progress = 0
        errorMessage = nil
        statusMessage = status
        return importID
    }

    private func finishMediaImport(_ importID: UUID) {
        guard activeMediaImportID == importID else { return }
        activeMediaImportID = nil
        mediaImportTask = nil
        isImportingMedia = false
    }

    /// Convert timestamped speech segments into contiguous voice ranges.
    /// Returns nil when there is no transcript overlap with the requested
    /// scope, allowing callers to fall back to audio-energy analysis.
    private static func transcriptSpeechRanges(
        _ transcript: Transcript?,
        within scopes: [ClipRange],
        totalDuration: Double,
        minimumSilenceDuration: Double = 0.35
    ) -> [ClipRange]? {
        guard let transcript, !transcript.isEmpty,
              totalDuration.isFinite, totalDuration > 0 else { return nil }

        let effectiveScopes: [ClipRange]
        if scopes.isEmpty {
            effectiveScopes = [ClipRange(startSeconds: 0, endSeconds: totalDuration)]
        } else {
            effectiveScopes = scopes.compactMap { scope in
                let start = min(max(scope.startSeconds, 0), totalDuration)
                let end = min(max(scope.endSeconds, 0), totalDuration)
                guard end - start > 0.05 else { return nil }
                return ClipRange(startSeconds: start, endSeconds: end)
            }
        }

        var result: [ClipRange] = []
        var foundTranscriptOverlap = false

        for scope in effectiveScopes {
            let segments = transcript.segments.compactMap { segment -> ClipRange? in
                let start = max(0, max(segment.startSeconds, scope.startSeconds))
                let end = min(totalDuration, min(segment.endSeconds, scope.endSeconds))
                guard end - start > 0.05 else { return nil }
                return ClipRange(startSeconds: start, endSeconds: end)
            }
            .sorted { $0.startSeconds < $1.startSeconds }

            guard let first = segments.first else { continue }
            foundTranscriptOverlap = true

            var currentStart = first.startSeconds
            var currentEnd = first.endSeconds
            for segment in segments.dropFirst() {
                if segment.startSeconds - currentEnd >= minimumSilenceDuration {
                    result.append(ClipRange(startSeconds: currentStart, endSeconds: currentEnd))
                    currentStart = segment.startSeconds
                }
                currentEnd = max(currentEnd, segment.endSeconds)
            }
            result.append(ClipRange(startSeconds: currentStart, endSeconds: currentEnd))
        }

        return foundTranscriptOverlap ? result : nil
    }

    private var analysisStatusMessage: String {
        Self.analysisStatusMessage(for: cutMode)
    }

    private static func analysisStatusMessage(for mode: CutMode, scoped: Bool = false) -> String {
        switch mode {
        case .fixed:
            return "Planning fixed clips..."
        case .smartPause:
            return scoped
                ? "Running Smart Pause on the selected range..."
                : "Running Smart Pause on the whole source..."
        case .highlight:
            return "Ready — drag the highlight on the timeline."
        case .aiAssist:
            return scoped
                ? "Asking Apple Intelligence about the selected clips..."
                : "Asking Apple Intelligence..."
        }
    }

    private func loadVideo(from item: PhotosPickerItem, importID: UUID) async {
        defer { finishMediaImport(importID) }

        processingPhase = .loading
        progress = 0
        resetLoadedMediaState(keepSource: false)
        errorMessage = nil
        statusMessage = "Loading video..."

        // Capture the PHAsset localIdentifier before the transferable
        // load — this is the identifier we write into `.reelclip`
        // export files so the recipient can resolve the source video.
        let photoId = item.photoLibraryLocalIdentifier

        var materializedVideo: PickedVideo?
        var sourceInstalled = false
        defer {
            if let materializedVideo,
               materializedVideo.isWorkspaceCopyNew,
               !sourceInstalled {
                mediaWorkspace.removeImportedSource(at: materializedVideo.url)
            }
        }

        do {
            guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
                statusMessage = "Choose a valid video file."
                processingPhase = .idle
                return
            }
            materializedVideo = video

            guard !Task.isCancelled else {
                statusMessage = "Video import cancelled."
                processingPhase = .idle
                return
            }

            guard FileManager.default.fileExists(atPath: video.url.path) else {
                throw PickedVideoImportError.photosDownloadUnavailable
            }
            try await setLoadedVideo(url: video.url)
            // Persist the PHAsset identifier so it's available when
            // the project is exported to a `.reelclip` file. Prefer
            // the identifier from the PhotosPickerItem (most reliable);
            // fall back to the one from PickedVideo (set by the
            // transferable import, currently always nil).
            sourcePhotoLibraryIdentifier = photoId ?? video.photoLibraryLocalIdentifier
            persistCurrentProject()
            sourceInstalled = true
            isProjectBrowserVisible = false
            statusMessage = "Ready to analyze cuts."
        } catch is CancellationError {
            sourceURL = nil
            durationSeconds = nil
            sourceThumbnails = []
            waveformSamples = []
            scrubPositionSeconds = 0
            statusMessage = "Video import cancelled."
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

    private func loadVideoFile(from url: URL, importID: UUID) async {
        defer { finishMediaImport(importID) }

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
            guard !Task.isCancelled else {
                statusMessage = "File import cancelled."
                processingPhase = .idle
                return
            }

            let copiedURL = try mediaWorkspace.importSourceCopy(from: url)
            try await setLoadedVideo(url: copiedURL)
            isProjectBrowserVisible = false
            statusMessage = "Ready to analyze cuts."
        } catch is CancellationError {
            sourceURL = nil
            durationSeconds = nil
            sourceThumbnails = []
            waveformSamples = []
            scrubPositionSeconds = 0
            statusMessage = "File import cancelled."
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

    private func loadPreparedVideoFile(
        from url: URL,
        photoLibraryIdentifier: String?,
        sourceName: String,
        canDiscardPreparedSource: Bool,
        trimRange: ClipRange?,
        importID: UUID
    ) async {
        defer { finishMediaImport(importID) }
        var shouldDiscardPreparedSource = trimRange != nil && canDiscardPreparedSource
        var createdTrimSource: ImportedSourceCopy?
        defer {
            if shouldDiscardPreparedSource {
                mediaWorkspace.removeImportedSource(at: url)
            }
        }

        processingPhase = .loading
        progress = 0
        resetLoadedMediaState(keepSource: false)
        errorMessage = nil

        do {
            guard !Task.isCancelled else {
                statusMessage = "Video import cancelled."
                processingPhase = .idle
                return
            }

            let finalURL: URL
            if let trimRange {
                let sourceDuration = try await segmenter.duration(for: url)
                let start = min(max(trimRange.startSeconds, 0), sourceDuration)
                let end = min(max(trimRange.endSeconds, 0), sourceDuration)
                guard end - start > 0.05 else {
                    throw NSError(
                        domain: "VideoImport",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Select a section longer than one video frame."]
                    )
                }
                try MediaProcessingLimits.validateSourceDuration(end - start, for: currentTier)

                // The trim renderer writes a temporary output and then copies
                // that result into Imports before deleting the original
                // candidate. Budget for both files at their estimated source
                // bitrate so large trims fail before AVFoundation starts.
                let sourceBytes = mediaWorkspace.fileSize(at: url)
                let selectedRatio = min(max((end - start) / sourceDuration, 0), 1)
                let estimatedTrimBytes = Int64((Double(sourceBytes) * selectedRatio).rounded(.up))
                let trimCapacity = estimatedTrimBytes.multipliedReportingOverflow(by: 2)
                try mediaWorkspace.validateAvailableCapacity(
                    additionalBytes: trimCapacity.overflow ? Int64.max : trimCapacity.partialValue
                )

                let rendered = try await segmenter.renderSourceTrim(
                    sourceURL: url,
                    range: ClipRange(startSeconds: start, endSeconds: end),
                    progress: { [weak self] value in
                        self?.progress = min(max(value, 0), 1)
                    }
                )
                defer { mediaWorkspace.removeDirectories(for: [rendered]) }
                let importedTrim = try mediaWorkspace.importSourceCopyResult(from: rendered.url)
                createdTrimSource = importedTrim
                finalURL = importedTrim.url
            } else {
                finalURL = url
            }

            try await setLoadedVideo(url: finalURL, suggestedProjectTitle: sourceName)
            if finalURL.standardizedFileURL == url.standardizedFileURL {
                shouldDiscardPreparedSource = false
            }
            // A rendered trim is a new source. Pointing it at the original
            // PHAsset would make a restored project reopen the untrimmed video.
            sourcePhotoLibraryIdentifier = trimRange == nil ? photoLibraryIdentifier : nil
            persistCurrentProject()
            isProjectBrowserVisible = false
            statusMessage = trimRange == nil
                ? "Ready to analyze cuts."
                : "Selected section imported. Ready to analyze cuts."
        } catch is CancellationError {
            if trimRange == nil, canDiscardPreparedSource {
                mediaWorkspace.removeImportedSource(at: url)
            }
            if let createdTrimSource, createdTrimSource.wasCreated {
                mediaWorkspace.removeImportedSource(at: createdTrimSource.url)
            }
            sourceURL = nil
            durationSeconds = nil
            sourceThumbnails = []
            waveformSamples = []
            scrubPositionSeconds = 0
            statusMessage = "Video import cancelled."
        } catch {
            if trimRange == nil, canDiscardPreparedSource {
                mediaWorkspace.removeImportedSource(at: url)
            }
            if let createdTrimSource, createdTrimSource.wasCreated {
                mediaWorkspace.removeImportedSource(at: createdTrimSource.url)
            }
            sourceURL = nil
            durationSeconds = nil
            sourceThumbnails = []
            waveformSamples = []
            scrubPositionSeconds = 0
            errorMessage = error.localizedDescription
            statusMessage = "Could not import selected section."
        }

        processingPhase = .idle
    }

    private func resetLoadedMediaState(keepSource: Bool) {
        if !keepSource {
            resetPlaybackMedia()
            sourceURL = nil
            durationSeconds = nil
            sourcePhotoLibraryIdentifier = nil
        }
        plannedRanges = []
        scenes = []
        activeSceneId = nil
        sourceThumbnails = []
        waveformSamples = []
        scrubPositionSeconds = 0
        frameDurationSeconds = 1.0 / 30.0
        sourceAspectRatio = 16.0 / 9.0
        clips = []
        transcriptTask?.cancel()
        transcriptTask = nil
        transcript = nil
        transcriptState = .idle
    }

    private func setLoadedVideo(url: URL, suggestedProjectTitle: String? = nil) async throws {
        sourceURL = url
        preparePlaybackMedia(for: url)
        // Seed the editable title with the source filename fallback the first
        // time a video is imported. The user can rename it inline; an empty
        // title is coerced to this same fallback at persist time.
        if projectTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            projectTitleDraft = suggestedProjectTitle
                .map(Self.defaultProjectTitle(forSourceName:))
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.defaultProjectTitle(for: url)
        }
        let duration = try await segmenter.duration(for: url)
        try MediaProcessingLimits.validateSourceDuration(duration, for: currentTier)
        durationSeconds = duration
        frameDurationSeconds = try await frameDuration(for: url)
        sourceAspectRatio = try await aspectRatio(for: url)
        seedHighlightDraftIfNeeded(totalDuration: duration)
        loadPreviews(for: url, durationSeconds: duration)
        loadWaveform(for: url, durationSeconds: duration)
        refreshPlanForCurrentInputs()
        persistCurrentProject()
        // New projects don't have a cached transcript — kick off STT now.
        startTranscriptionIfNeeded(for: url, persistWhenReady: true)
    }

    private func sourceMatches(_ url: URL) -> Bool {
        sourceURL?.standardizedFileURL == url.standardizedFileURL
    }

    private func resetPlaybackMedia() {
        proxyTask?.cancel()
        proxyTask = nil
        proxyGenerationID = nil
        playbackURL = nil
        playbackOriginalURL = nil
        isGeneratingProxy = false
        proxyGenerationProgress = 0
    }

    private func preparePlaybackMedia(for originalURL: URL) {
        proxyTask?.cancel()
        let generationID = UUID()
        proxyGenerationID = generationID
        playbackOriginalURL = originalURL
        playbackURL = originalURL
        isGeneratingProxy = false
        proxyGenerationProgress = 0

        if let cachedURL = mediaWorkspace.cachedProxyURL(for: originalURL) {
            playbackURL = cachedURL
            proxyGenerationProgress = 1
            proxyTask = nil
            return
        }

        proxyTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if self.proxyGenerationID == generationID {
                    self.proxyTask = nil
                }
            }

            do {
                let shouldGenerate = try await self.proxyGenerator.shouldGenerateProxy(for: originalURL)
                try Task.checkCancellation()
                guard self.proxyGenerationID == generationID,
                      self.sourceMatches(originalURL) else { return }
                guard shouldGenerate else { return }

                self.isGeneratingProxy = true
                let proxyURL = try await self.proxyGenerator.generateProxy(for: originalURL) { [weak self] value in
                    guard let self,
                          self.proxyGenerationID == generationID,
                          self.sourceMatches(originalURL) else { return }
                    self.proxyGenerationProgress = min(max(value, 0), 1)
                }
                try Task.checkCancellation()
                guard self.proxyGenerationID == generationID,
                      self.sourceMatches(originalURL) else { return }

                self.playbackURL = proxyURL
                self.isGeneratingProxy = false
                self.proxyGenerationProgress = 1
            } catch is CancellationError {
                guard self.proxyGenerationID == generationID else { return }
                self.isGeneratingProxy = false
                self.proxyGenerationProgress = 0
            } catch {
                // A proxy is an optimization. Falling back to the original
                // preserves editing instead of turning an encoder failure into
                // a blocking import error.
                guard self.proxyGenerationID == generationID,
                      self.sourceMatches(originalURL) else { return }
                self.playbackURL = originalURL
                self.isGeneratingProxy = false
                self.proxyGenerationProgress = 0
            }
        }
    }

    /// Run on-device speech-to-text on the given source. If a transcript is
    /// already cached on the current project, skip the work.
    private func startTranscriptionIfNeeded(for url: URL, persistWhenReady: Bool) {
        transcriptTask?.cancel()
        if let projectID = currentProjectID,
           let cached = projects.first(where: { $0.id == projectID })?.transcript,
           !cached.isEmpty {
            transcript = cached
            transcriptState = .ready
            return
        }
        transcriptState = .processing
        transcriptTask = Task { [weak self] in
            guard let self else { return }
            let service = TranscriptService()
            do {
                let result = try await service.transcribe(audioFileURL: url)
                if Task.isCancelled { return }
                self.transcript = result
                self.transcriptState = .ready
                if persistWhenReady {
                    self.persistCurrentProject()
                }
            } catch {
                if Task.isCancelled { return }
                self.transcriptState = .failed(error.localizedDescription)
            }
        }
    }

    private func loadProject(_ project: MediaProject) async {
        processingPhase = .loading
        progress = 0
        errorMessage = nil
        statusMessage = "Opening project..."

        let activeSceneIsBlank = project.activeScene?.hasSource == false
        guard activeSceneIsBlank || FileManager.default.fileExists(atPath: project.sourceURL.path) else {
            processingPhase = .idle
            errorMessage = "The original imported video for this project is missing."
            statusMessage = "Could not open project."
            return
        }

        if !activeSceneIsBlank {
            do {
                try MediaProcessingLimits.validateSourceDuration(project.durationSeconds, for: currentTier)
            } catch {
                processingPhase = .idle
                errorMessage = error.localizedDescription
                statusMessage = "Could not open project."
                return
            }
        }

        resetLoadedMediaState(keepSource: false)
        currentProjectID = project.id
        projectTitleDraft = project.title
        if !activeSceneIsBlank {
            sourceURL = project.sourceURL
            durationSeconds = project.durationSeconds
        }
        cutMode = project.cutMode
        segmentLengthText = project.segmentLengthText
        editPrompt = project.editPrompt
        // Restore the cached PHAsset identifier so the project
        // can be re-exported with the source reference intact.
        sourcePhotoLibraryIdentifier = project.sourcePhotoLibraryIdentifier
        frameDurationSeconds = Self.safeFrameDuration(project.frameDurationSeconds)
        sourceAspectRatio = Self.safeAspectRatio(project.sourceAspectRatio)
        scenes = project.scenes
        activeSceneId = project.activeSceneId ?? project.scenes.first?.id
        if let scene = project.activeScene {
            applyScene(scene)
            if activeSceneIsBlank {
                sourceURL = nil
                durationSeconds = nil
                sourcePhotoLibraryIdentifier = nil
                sourceThumbnails = []
                waveformSamples = []
                sourceAspectRatio = 16.0 / 9.0
                frameDurationSeconds = 1.0 / 30.0
                plannedRanges = []
                scrubPositionSeconds = 0
            } else {
                plannedRanges = VideoSegmenter.normalizedRanges(scene.plannedRanges, totalDuration: project.durationSeconds)
                scrubPositionSeconds = Self.clampedSeconds(scene.scrubPositionSeconds, duration: project.durationSeconds)
            }
        } else {
            plannedRanges = VideoSegmenter.normalizedRanges(project.plannedRanges, totalDuration: project.durationSeconds)
            scrubPositionSeconds = Self.clampedSeconds(project.scrubPositionSeconds, duration: project.durationSeconds)
        }
        clips = project.exportedClips
            .map(\.segmentOutput)
            .filter { isClipShareable($0) }
        // Restore committed planned ranges. Projects saved before
        // the "Save" button existed (no `savedClips` field) decode
        // with `[]` and the user starts with an empty saved row.
        savedClips = project.savedClips
        isProjectBrowserVisible = false

        // Surface any persisted transcript for the project.
        if let saved = project.transcript, !saved.isEmpty {
            transcript = saved
            transcriptState = .ready
        } else {
            transcript = nil
            transcriptState = .idle
        }

        if !activeSceneIsBlank {
            loadPreviews(for: project.sourceURL, durationSeconds: project.durationSeconds)
            loadWaveform(for: project.sourceURL, durationSeconds: project.durationSeconds)
            if let sourceURL {
                preparePlaybackMedia(for: sourceURL)
            }
        }

        statusMessage = activeSceneIsBlank
            ? "\(activeScene?.name ?? "Scene") is empty — import a clip to start."
            : "Continue editing \(project.title)."
        processingPhase = .idle
    }

    func persistCurrentProject() {
        let now = Date()
        let projectID = currentProjectID ?? UUID()
        let existingProject = projects.first { $0.id == projectID }
        let projectSourceURL = sourceURL ?? existingProject?.sourceURL
        let projectDuration = durationSeconds ?? existingProject?.durationSeconds
        guard let projectSourceURL, let projectDuration else { return }
        let activeSceneIsBlank = activeScene?.hasSource == false
        let sceneState = sceneStateForPersistence(existingProject: existingProject, now: now)
        let project = MediaProject(
            id: projectID,
            title: resolveProjectTitleForPersistence(existingTitle: existingProject?.title, sourceURL: projectSourceURL),
            sourcePath: projectSourceURL.standardizedFileURL.path,
            sourceFileName: projectSourceURL.lastPathComponent,
            durationSeconds: projectDuration,
            sourceAspectRatio: Self.safeAspectRatio(sourceAspectRatio),
            frameDurationSeconds: Self.safeFrameDuration(frameDurationSeconds),
            cutMode: cutMode,
            segmentLengthText: segmentLengthText,
            editPrompt: editPrompt,
            plannedRanges: plannedRanges,
            scenes: sceneState.scenes,
            activeSceneId: sceneState.activeSceneId,
            exportedClips: clips
                .filter { isClipShareable($0) }
                .map(StoredClipOutput.init(clip:)),
            savedClips: savedClips,
            scrubPositionSeconds: Self.clampedSeconds(scrubPositionSeconds, duration: projectDuration),
            transcript: transcript,
            sourcePhotoLibraryIdentifier: activeSceneIsBlank
                ? nil
                : sourcePhotoLibraryIdentifier ?? existingProject?.sourcePhotoLibraryIdentifier,
            exportSettings: currentProjectExportSettings,
            createdAt: existingProject?.createdAt ?? now,
            updatedAt: now
        )

        do {
            projects = try projectStore.upsert(project)
            currentProjectID = projectID
            scenes = project.scenes
            activeSceneId = project.activeSceneId
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Could not save project state."
        }
    }

    private func sceneStateForPersistence(
        existingProject: MediaProject?,
        now: Date
    ) -> (scenes: [MediaProjectScene], activeSceneId: UUID?) {
        if scenes.isEmpty {
            scenes = existingProject?.scenes ?? []
        }

        saveCurrentStateIntoSceneList(updatedAt: now)

        if scenes.isEmpty {
            let scene = currentSceneSnapshot(
                id: activeSceneId ?? UUID(),
                name: "Scene 1",
                createdAt: existingProject?.createdAt ?? now,
                updatedAt: now
            )
            scenes = [scene]
            activeSceneId = scene.id
        } else if activeSceneId == nil {
            activeSceneId = scenes.first?.id
        }

        return (scenes, activeSceneId)
    }

    private func saveCurrentStateIntoSceneList(updatedAt: Date) {
        let existingScene: MediaProjectScene?
        if let activeSceneId {
            existingScene = scenes.first(where: { $0.id == activeSceneId })
        } else {
            existingScene = scenes.first
        }

        let snapshot = currentSceneSnapshot(
            id: existingScene?.id ?? activeSceneId ?? UUID(),
            name: existingScene?.name ?? nextSceneName(),
            createdAt: existingScene?.createdAt ?? updatedAt,
            updatedAt: updatedAt
        )

        if let index = scenes.firstIndex(where: { $0.id == snapshot.id }) {
            scenes[index] = snapshot
        } else {
            scenes.append(snapshot)
        }
        activeSceneId = snapshot.id
    }

    private func currentSceneSnapshot(
        id: UUID,
        name: String,
        createdAt: Date,
        updatedAt: Date
    ) -> MediaProjectScene {
        // Snapshot the CURRENTLY LOADED source onto the scene so the
        // scene is self-describing for the codec (a .reelclip file
        // needs to know what source each scene refers to without
        // looking at the project-level cache). For the path, prefer
        // the in-memory `sourceURL` (after `importSourceCopy` it's a
        // stable file URL in the workspace's sources dir) and fall
        // back to the existing scene's path if sourceURL is nil
        // (e.g. a snapshot of a freshly-deleted source).
        let snapshotSourcePath: String? = sourceURL?.standardizedFileURL.path
        let snapshotSourceFileName: String? = sourceURL?.lastPathComponent
        return MediaProjectScene(
            id: id,
            name: name,
            sourcePath: snapshotSourcePath,
            sourceFileName: snapshotSourceFileName,
            sourcePhotoLibraryIdentifier: sourcePhotoLibraryIdentifier,
            sourceOriginalFilename: sourceURL?.lastPathComponent,
            durationSeconds: durationSeconds,
            sourceAspectRatio: sourceAspectRatio,
            frameDurationSeconds: frameDurationSeconds,
            cutMode: cutMode,
            segmentLengthText: segmentLengthText,
            editPrompt: editPrompt,
            plannedRanges: plannedRanges,
            highlightDraftStart: highlightDraftStart,
            highlightDraftDuration: highlightDraftDuration,
            scrubPositionSeconds: scrubPositionSeconds,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func applyScene(_ scene: MediaProjectScene) {
        cutMode = scene.cutMode
        segmentLengthText = scene.segmentLengthText
        editPrompt = scene.editPrompt
        plannedRanges = scene.plannedRanges
        highlightDraftStart = scene.highlightDraftStart
        highlightDraftDuration = scene.highlightDraftDuration ?? highlightDraftDuration
        scrubPositionSeconds = scene.scrubPositionSeconds
        clips = []
        pendingExportClips = nil
        pendingExportSceneLabels = [:]
        pendingExportMissingScenes = []
        progress = 0

        // Per-scene source switching. Three cases:
        // 1. Scene has a per-scene source AND it differs from the
        //    currently loaded one → swap to the scene's source,
        //    regenerate thumbnails + waveform.
        // 2. Scene has a per-scene source AND it matches the
        //    currently loaded one → no-op, the previews are valid.
        // 3. Scene has NO per-scene source (legacy v2 scene) → fall
        //    back to whatever the project currently has loaded. The
        //    source was set on the project once, all scenes share
        //    it. This keeps v2 projects working without a
        //    forced migration.
        applySourceForScene(scene)
    }

    /// If the scene has a per-scene source different from what's
    /// currently loaded, swap to it (regenerating previews + waveform
    /// on a background task). If the scene's source matches the
    /// current one, this is a no-op. If the scene has no per-scene
    /// source (legacy v2), the project-level source stays loaded.
    private func applySourceForScene(_ scene: MediaProjectScene) {
        guard scene.hasSource else {
            // Legacy scene — keep the project-level source as-is.
            return
        }

        let sceneSourcePath = scene.sourcePath
        let currentSourcePath = sourceURL?.standardizedFileURL.path

        // Same source (matching path, or both nil with a matching
        // photo identifier) — nothing to do. Previews stay valid.
        if sceneSourcePath == currentSourcePath,
           scene.sourcePhotoLibraryIdentifier == sourcePhotoLibraryIdentifier {
            if let sourceURL, playbackURL == nil {
                preparePlaybackMedia(for: sourceURL)
            }
            return
        }

        // Source mismatch — load the scene's source. For Photos
        // assets we keep the existing project path (we don't have
        // a way to re-resolve the localIdentifier to a file URL
        // here; the file is gone if it was a temp copy). The
        // thumbnails will regenerate against whatever the path
        // points to.
        if let sceneURL = scene.sourceURL {
            let identifier = scene.sourcePhotoLibraryIdentifier
            let knownDuration = scene.durationSeconds
            let knownAspect = scene.sourceAspectRatio
            let knownFrameDuration = scene.frameDurationSeconds
            Task { [weak self] in
                await self?.swapSource(
                    to: sceneURL,
                    photoLibraryIdentifier: identifier,
                    knownDuration: knownDuration,
                    knownAspect: knownAspect,
                    knownFrameDuration: knownFrameDuration
                )
            }
        } else if let identifier = scene.sourcePhotoLibraryIdentifier {
            // Photos-only scene — just update the identifier so the
            // existing project-level file (if any) is associated
            // with this scene's asset. We can't regenerate the
            // previews against the asset without an async PHAsset
            // fetch; defer to the next save.
            sourcePhotoLibraryIdentifier = identifier
        }
    }

    /// Swap the project-level source to a new file URL. Used by
    /// `applySourceForScene` when a scene's source differs from the
    /// currently loaded one. Mirrors `setLoadedVideo` but as a
    /// side-effect of scene switching (no title seeding, no
    /// transcript kick-off — those are first-load actions).
    private func swapSource(
        to url: URL,
        photoLibraryIdentifier: String?,
        knownDuration: Double?,
        knownAspect: Double?,
        knownFrameDuration: Double?
    ) async {
        processingPhase = .loading
        progress = 0
        errorMessage = nil
        statusMessage = "Loading scene source..."

        // Tear down the in-memory previews so the UI doesn't show
        // stale thumbnails for the new source.
        sourceThumbnails = []
        waveformSamples = []

        sourceURL = url
        preparePlaybackMedia(for: url)
        sourcePhotoLibraryIdentifier = photoLibraryIdentifier

        do {
            let duration: Double
            if let knownDuration {
                duration = knownDuration
            } else {
                duration = try await segmenter.duration(for: url)
            }
            try MediaProcessingLimits.validateSourceDuration(duration, for: currentTier)
            durationSeconds = duration
            if let knownAspect {
                sourceAspectRatio = knownAspect
            } else {
                sourceAspectRatio = try await aspectRatio(for: url)
            }
            if let knownFrameDuration {
                frameDurationSeconds = knownFrameDuration
            } else {
                frameDurationSeconds = try await frameDuration(for: url)
            }
            loadPreviews(for: url, durationSeconds: duration)
            loadWaveform(for: url, durationSeconds: duration)
        } catch {
            // Source file is gone (e.g. workspace temp dir was
            // cleaned). Fall back to a clean state so the UI
            // doesn't lie about the loaded source.
            errorMessage = "Scene source is missing: \(error.localizedDescription)"
            statusMessage = "This scene's video file is unavailable."
            sourceURL = nil
            durationSeconds = nil
            sourcePhotoLibraryIdentifier = nil
            sourceThumbnails = []
            waveformSamples = []
        }

        processingPhase = .idle
    }

    private func nextSceneName() -> String {
        let existingNames = Set(scenes.map(\.name))
        var index = scenes.count + 1
        var candidate = "Scene \(index)"
        while existingNames.contains(candidate) {
            index += 1
            candidate = "Scene \(index)"
        }
        return candidate
    }

    private func uniqueSceneName(_ proposedName: String, excluding sceneId: UUID? = nil) -> String {
        let base = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nextSceneName() }

        let existingNames = Set(
            scenes
                .filter { $0.id != sceneId }
                .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        guard existingNames.contains(base.lowercased()) else { return base }

        var index = 2
        var candidate = "\(base) \(index)"
        while existingNames.contains(candidate.lowercased()) {
            index += 1
            candidate = "\(base) \(index)"
        }
        return candidate
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
        persistCurrentProject()

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

    private func appleIntelligenceRanges(
        for sourceURL: URL,
        fallbackSegmentLength: Double,
        prompt: String,
        provider: AIProvider,
        tier: SubscriptionStore.Tier,
        durationSeconds: Double?,
        selectionRanges: [ClipRange] = []
    ) async throws -> [ClipRange] {
        guard let durationSeconds else {
            throw VideoSegmenterError.invalidDuration
        }

        try MediaProcessingLimits.validateSourceDuration(durationSeconds, for: tier)
        let features = try await timelineFeaturePack(
            for: sourceURL,
            durationSeconds: durationSeconds,
            fallbackSegmentLength: fallbackSegmentLength,
            selectionRanges: selectionRanges,
            includeVideoFrames: provider.supportsVision
        )

        // Apple Intelligence is the only AI runtime. If the device
        // doesn't support it (pre-iOS 26, or Apple Intelligence
        // disabled in Settings), the registry returns nil and we
        // surface a friendly error — no fallback to a cloud
        // provider, since the v72 180 removed them entirely.
        guard let resolved = AIProviderRegistry.resolvedProvider(
            for: provider
        ) else {
            throw NSError(
                domain: "AIProvider",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is unavailable on this device. Requires iPhone 15 Pro or later with Apple Intelligence enabled in Settings."]
            )
        }

        // Apple Intelligence doesn't use credentials — the
        // `credential` parameter is reserved for future
        // bring-your-own-model paths.
        let credential: String? = nil

        statusMessage = "Asking \(resolved.provider.displayName)…"
        do {
            let ranges: [ClipRange]
            if resolved.provider.id.supportsVision, !features.videoFrames.isEmpty {
                ranges = try await resolved.provider.planCutsWithVision(
                    prompt: prompt,
                    features: features,
                    frames: features.videoFrames,
                    credential: credential
                )
            } else {
                ranges = try await resolved.provider.planCuts(
                    prompt: prompt,
                    features: features,
                    credential: credential
                )
            }
            return selectionRanges.isEmpty
                ? ranges
                : Self.constrainedRanges(ranges, to: selectionRanges, totalDuration: durationSeconds)
        } catch {
            // Re-raise — caller renders the localised error message.
            throw error
        }
    }

    /// Refines a set of silence-detected ranges through Apple
    /// Intelligence. Hands the initial ranges + the audio-level
    /// timeline feature pack to FoundationModels with a tightening
    /// prompt; the model can drop ranges that sound like false
    /// starts / awkward pauses / barely audible sections. Returns
    /// the AI's refined ranges, or `[]` if Apple Intelligence is
    /// unavailable or the call fails — the caller falls back to the
    /// SmartCutAnalyzer output in that case.
    ///
    /// Best-effort by design: a tightening action should never be
    /// blocked by AI unavailability. The user still gets a tightened
    /// clip; they just skip the semantic refinement pass.
    private func refineRangesWithAppleIntelligence(
        initialRanges: [ClipRange],
        sourceURL: URL,
        fallbackSegmentLength: Double,
        tier: SubscriptionStore.Tier,
        durationSeconds: Double?,
        selectionRanges: [ClipRange]
    ) async -> [ClipRange] {
        // Quick gate: if there are no ranges to refine, skip the
        // model round-trip entirely.
        guard !initialRanges.isEmpty else { return [] }

        // Build the prompt. List the initial ranges so the model
        // knows the candidate pool; ask it to drop awkward / barely
        // audible ranges; remind it to stay inside the source
        // duration. The timeline feature pack (sent separately to
        // the provider) carries the per-window audio levels the
        // model needs to judge "is this range actually speech".
        let rangeList = initialRanges.enumerated().map { index, range in
            "  \(index + 1). \(String(format: "%.2f", range.startSeconds))–\(String(format: "%.2f", range.endSeconds))s"
        }.joined(separator: "\n")
        let prompt = """
        Initial silence-detected ranges (in seconds):

        \(rangeList)

        Source duration: \(String(format: "%.2f", durationSeconds ?? 0))s.

        Refine these ranges for a tightened single-clip output. Drop \
        ranges that are barely audible, sound like false starts, \
        contain only noise, or are awkward pauses. Keep ranges that \
        contain actual speech or meaningful audio. Return refined \
        ranges in the same JSON format (start, end, reason). Stay \
        inside the source duration and inside the selected ranges.
        """

        do {
            let refined = try await appleIntelligenceRanges(
                for: sourceURL,
                fallbackSegmentLength: fallbackSegmentLength,
                prompt: prompt,
                provider: .appleIntelligence,
                tier: tier,
                durationSeconds: durationSeconds,
                selectionRanges: selectionRanges
            )
            return refined
        } catch {
            // Apple Intelligence unavailable, model errored, or
            // device ineligible. Best-effort: return empty so the
            // caller falls back to the SmartCutAnalyzer output.
            return []
        }
    }

    /// Apple Intelligence is the only AI runtime; no keychain
    /// credential is needed. Kept as a method so the SettingsView
    /// still has a single "is the provider configured?" hook to
    /// gate the status pill.
    func hasConfiguredCredential(for provider: AIProvider) -> Bool {
        // Apple Intelligence is a system framework — always
        // "configured" in the sense that the runtime exists; the
        // device-eligibility check happens in
        /// `AIProviderRegistry.provider(for:)`.
        return true
    }

    private func timelineFeaturePack(
        for sourceURL: URL,
        durationSeconds: Double,
        fallbackSegmentLength: Double,
        selectionRanges: [ClipRange] = [],
        includeVideoFrames: Bool = false
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

        let allPoints = timelineFeaturePoints(
            samples: samples,
            durationSeconds: durationSeconds
        )
        let normalizedSelectionRanges = Self.normalizedAnalysisRanges(
            selectionRanges,
            totalDuration: durationSeconds
        )
        let points = normalizedSelectionRanges.isEmpty
            ? allPoints
            : allPoints.flatMap { point in
                normalizedSelectionRanges.compactMap { scope in
                    let start = max(point.startSeconds, scope.startSeconds)
                    let end = min(point.endSeconds, scope.endSeconds)
                    guard end > start else { return nil }
                    return TimelineFeaturePoint(
                        startSeconds: start,
                        endSeconds: end,
                        audioLevel: point.audioLevel,
                        isQuiet: point.isQuiet
                    )
                }
            }
        let requestedMaxClips = MediaProcessingLimits.maximumPlannedClips
        let fallbackRanges: [ClipRange]
        if normalizedSelectionRanges.isEmpty {
            fallbackRanges = Array(
                SmartCutAnalyzer.equalRanges(
                    totalDuration: durationSeconds,
                    segmentLength: fallbackSegmentLength
                )
                .prefix(MediaProcessingLimits.maximumPlannedClips)
            )
        } else {
            fallbackRanges = Array(
                normalizedSelectionRanges.flatMap { scope in
                    SmartCutAnalyzer.equalRanges(
                        totalDuration: scope.duration,
                        segmentLength: fallbackSegmentLength
                    ).map { range in
                        ClipRange(
                            startSeconds: range.startSeconds + scope.startSeconds,
                            endSeconds: range.endSeconds + scope.startSeconds
                        )
                    }
                }
                .prefix(MediaProcessingLimits.maximumPlannedClips)
            )
        }

        let videoFrames = includeVideoFrames
            ? try await extractVideoFrames(
                for: sourceURL,
                durationSeconds: durationSeconds,
                selectionRanges: normalizedSelectionRanges
            )
            : []

        return TimelineFeaturePack(
            sourceDurationSeconds: durationSeconds,
            fallbackSegmentLengthSeconds: fallbackSegmentLength,
            requestedMaxClips: requestedMaxClips,
            targetPlatform: "Reels/TikTok",
            analysisPoints: points,
            fallbackRanges: fallbackRanges,
            videoFrames: videoFrames,
            selectionRanges: normalizedSelectionRanges
        )
    }

    private static func normalizedAnalysisRanges(
        _ ranges: [ClipRange],
        totalDuration: Double
    ) -> [ClipRange] {
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }
        return ranges.compactMap { range in
            let start = min(max(range.startSeconds, 0), totalDuration)
            let end = min(max(range.endSeconds, 0), totalDuration)
            guard end - start > 0.05 else { return nil }
            return ClipRange(startSeconds: start, endSeconds: end)
        }
    }

    private static func constrainedRanges(
        _ ranges: [ClipRange],
        to scopes: [ClipRange],
        totalDuration: Double
    ) -> [ClipRange] {
        let normalizedScopes = normalizedAnalysisRanges(scopes, totalDuration: totalDuration)
        return ranges.flatMap { range in
            normalizedScopes.compactMap { scope in
                let start = max(range.startSeconds, scope.startSeconds)
                let end = min(range.endSeconds, scope.endSeconds)
                guard end - start > 0.05 else { return nil }
                return ClipRange(
                    startSeconds: start,
                    endSeconds: end,
                    reason: range.reason,
                    isLocked: range.isLocked,
                    cutMode: range.cutMode
                )
            }
        }
    }

    /// Extract up to 8 sampled frames as base64 JPEG for vision-capable
    /// providers. Reuses already-loaded `sourceThumbnails` when present
    /// (the timeline UI keeps them hot); otherwise falls back to
    /// `MediaPreviewGenerator` to pull 8 frames at 512px. Each frame is
    /// JPEG-compressed at 0.6 quality before base64 encoding so the total
    /// payload stays around ~240KB.
    private func extractVideoFrames(
        for sourceURL: URL,
        durationSeconds: Double,
        selectionRanges: [ClipRange] = []
    ) async throws -> [VideoFrameSample] {
        let thumbnails: [MediaThumbnail]
        if !sourceThumbnails.isEmpty {
            thumbnails = Array(sourceThumbnails.prefix(8))
        } else {
            thumbnails = (try? await previewGenerator.thumbnails(
                for: sourceURL,
                durationSeconds: durationSeconds,
                targetCount: 8,
                maximumSize: CGSize(width: 512, height: 512)
            )) ?? []
        }

        let selectedThumbnails = selectionRanges.isEmpty
            ? thumbnails
            : thumbnails.filter { thumbnail in
                selectionRanges.contains { scope in
                    thumbnail.timeSeconds >= scope.startSeconds &&
                        thumbnail.timeSeconds <= scope.endSeconds
                }
            }

        return selectedThumbnails.compactMap { thumbnail in
            guard let jpegData = thumbnail.image.jpegData(compressionQuality: 0.6) else { return nil }
            let base64 = jpegData.base64EncodedString()
            return VideoFrameSample(timeSeconds: thumbnail.timeSeconds, base64JPEG: base64)
        }
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
            let targetCount = 12
            let maximumSize = CGSize(width: 240, height: 240)

            do {
                if let cached = mediaWorkspace.loadThumbnailCache(
                    for: sourceURL,
                    durationSeconds: durationSeconds,
                    targetCount: targetCount,
                    maximumSize: maximumSize
                ) {
                    sourceThumbnails = cached
                    previewTask = nil
                    return
                }

                let thumbnails = try await previewGenerator.thumbnails(
                    for: sourceURL,
                    durationSeconds: durationSeconds,
                    targetCount: targetCount,
                    maximumSize: maximumSize
                )
                try Task.checkCancellation()
                sourceThumbnails = thumbnails
                mediaWorkspace.saveThumbnailCache(
                    thumbnails,
                    for: sourceURL,
                    durationSeconds: durationSeconds,
                    targetCount: targetCount,
                    maximumSize: maximumSize
                )
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
            let targetSampleCount = 84

            do {
                if let cached = mediaWorkspace.loadWaveformCache(
                    for: sourceURL,
                    durationSeconds: durationSeconds,
                    targetSampleCount: targetSampleCount
                ) {
                    waveformSamples = cached
                    waveformTask = nil
                    return
                }

                let samples = try await waveformAnalyzer.samples(
                    for: sourceURL,
                    durationSeconds: durationSeconds,
                    targetSampleCount: targetSampleCount
                )
                try Task.checkCancellation()
                waveformSamples = samples
                mediaWorkspace.saveWaveformCache(
                    samples,
                    for: sourceURL,
                    durationSeconds: durationSeconds,
                    targetSampleCount: targetSampleCount
                )
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
        let fileStem = url.deletingPathExtension().lastPathComponent
        return defaultProjectTitle(forSourceName: fileStem)
    }

    private static func defaultProjectTitle(forSourceName sourceName: String) -> String {
        let fileStem = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        let sourceTitle = stripImportedSourcePrefix(from: fileStem)
        let title = normalizedDefaultProjectTitle(from: sourceTitle)

        return title.isEmpty ? "Untitled project" : title
    }

    private static func stripImportedSourcePrefix(from fileStem: String) -> String {
        var title = fileStem
        let components = title.components(separatedBy: "-")

        if components.count > 7,
           components[0].count == 8,
           components[1].count == 6 {
            let uuidCandidate = components[2...6].joined(separator: "-")
            if UUID(uuidString: uuidCandidate) != nil {
                title = components[7...].joined(separator: "-")
            }
        }

        return title
    }

    private static func normalizedDefaultProjectTitle(from rawTitle: String) -> String {
        FilenameSanitizer.sanitize(rawTitle, fallback: "")
            .replacingOccurrences(of: "_+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
    }

    private static func fixedRanges(
        totalDuration: Double,
        segmentLength: Double,
        frameDuration: Double,
        tier: SubscriptionStore.Tier
    ) throws -> [ClipRange] {
        try MediaProcessingLimits.validateSourceDuration(totalDuration, for: tier)
        let minimumDuration = min(minimumFixedClipDuration(segmentLength: segmentLength), totalDuration)
        let ranges = SmartCutAnalyzer.equalRanges(
            totalDuration: totalDuration,
            segmentLength: segmentLength,
            minimumFinalSegmentLength: minimumDuration
        )
        let validated = try MediaProcessingLimits.validatedClipPlan(
            ranges,
            totalDuration: totalDuration,
            frameDuration: frameDuration,
            minimumDuration: minimumDuration
        )
        // Stamp every freshly-planned fixed range with .fixed so the
        // timeline filter (liveTimelineRanges) only shows them in
        // fixed mode. Without the stamp, equalRanges returns ranges
        // with the default .highlight cutMode and they'd appear in
        // the wrong mode.
        return validated.map { range in
            var stamped = range
            stamped.cutMode = .fixed
            return stamped
        }
    }

    private struct FixedRecipeRandomGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        }

        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private static func randomizedFixedRanges(
        totalDuration: Double,
        requestedCount: Int,
        baseDuration: Int,
        baseInterval: Int,
        durationRange: ClosedRange<Double>,
        intervalRange: ClosedRange<Double>,
        randomizeDuration: Bool,
        randomizeInterval: Bool,
        seed: UInt64
    ) -> [ClipRange] {
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }
        let count = min(max(requestedCount, 1), MediaProcessingLimits.maximumPlannedClips)
        let anchorDuration = min(max(Double(baseDuration), 0.1), totalDuration)
        let anchorInterval = min(max(Double(baseInterval), 0.1), totalDuration)
        let minimumDuration = min(1.0, totalDuration)
        var generator = FixedRecipeRandomGenerator(seed: seed)

        return boundedRandomFixedRanges(
            totalDuration: totalDuration,
            requestedCount: count,
            anchorDuration: anchorDuration,
            anchorInterval: anchorInterval,
            durationRange: durationRange,
            intervalRange: intervalRange,
            minimumDuration: minimumDuration,
            randomizeDuration: randomizeDuration,
            randomizeInterval: randomizeInterval,
            generator: &generator
        )
    }

    private static func boundedRandomFixedRanges(
        totalDuration: Double,
        requestedCount: Int,
        anchorDuration: Double,
        anchorInterval: Double,
        durationRange: ClosedRange<Double>,
        intervalRange: ClosedRange<Double>,
        minimumDuration: Double,
        randomizeDuration: Bool,
        randomizeInterval: Bool,
        generator: inout FixedRecipeRandomGenerator
    ) -> [ClipRange] {
        let durationBounds = normalizedRandomRange(
            durationRange,
            fallback: anchorDuration,
            minimum: minimumDuration,
            maximum: totalDuration
        )
        let intervalBounds = normalizedRandomRange(
            intervalRange,
            fallback: anchorInterval,
            minimum: minimumDuration,
            maximum: totalDuration
        )
        let durationLower = randomizeDuration ? durationBounds.lowerBound : min(max(anchorDuration, minimumDuration), totalDuration)
        let durationUpper = randomizeDuration ? durationBounds.upperBound : durationLower
        let intervalLower = randomizeInterval ? intervalBounds.lowerBound : min(max(anchorInterval, minimumDuration), totalDuration)
        let intervalUpper = randomizeInterval ? intervalBounds.upperBound : intervalLower
        let minimumStep = max(durationLower, intervalLower)
        guard minimumStep > 0, totalDuration >= durationLower else { return [] }

        let physicalMaximumCount = Int(((totalDuration - durationLower) / minimumStep).rounded(.down)) + 1
        let targetCount = min(requestedCount, max(0, physicalMaximumCount))
        guard targetCount > 0 else { return [] }

        var ranges: [ClipRange] = []
        var start = 0.0

        for index in 0..<targetCount {
            guard start < totalDuration else { break }
            let clipsLeftAfterThis = targetCount - index - 1
            let maxSpan = totalDuration - start - Double(clipsLeftAfterThis) * minimumStep
            guard maxSpan >= durationLower else { break }

            let span: Double
            if randomizeDuration {
                let upper = max(durationLower, min(durationUpper, maxSpan))
                span = Double.random(in: durationLower...upper, using: &generator)
            } else {
                span = min(durationLower, maxSpan)
            }

            guard span >= minimumDuration else { break }
            ranges.append(ClipRange(startSeconds: start, endSeconds: min(start + span, totalDuration), cutMode: .fixed))

            guard clipsLeftAfterThis > 0 else { continue }
            let minStepForThisClip = max(span, intervalLower)
            let maxStepForFit = totalDuration - start - Double(clipsLeftAfterThis - 1) * minimumStep - durationLower
            guard maxStepForFit >= minStepForThisClip else { break }

            let step: Double
            if randomizeInterval {
                let upper = max(minStepForThisClip, min(max(intervalUpper, span), maxStepForFit))
                step = Double.random(in: minStepForThisClip...upper, using: &generator)
            } else {
                step = min(max(anchorInterval, span), maxStepForFit)
            }
            start += max(step, minStepForThisClip)
        }
        return ranges
    }

    private static func normalizedRandomRange(
        _ range: ClosedRange<Double>,
        fallback: Double,
        minimum: Double,
        maximum: Double
    ) -> ClosedRange<Double> {
        let fallbackValue = min(max(fallback, minimum), maximum)
        let rawLower = range.lowerBound.isFinite ? range.lowerBound : fallbackValue
        let rawUpper = range.upperBound.isFinite ? range.upperBound : fallbackValue
        let lower = min(max(min(rawLower, rawUpper), minimum), maximum)
        let upper = min(max(max(rawLower, rawUpper), minimum), maximum)
        return lower...max(lower, upper)
    }

    private static func stampedFixedRanges(_ ranges: [ClipRange]) -> [ClipRange] {
        ranges.map { range in
            ClipRange(
                startSeconds: range.startSeconds,
                endSeconds: range.endSeconds,
                reason: range.reason,
                isLocked: range.isLocked,
                cutMode: .fixed
            )
        }
    }

    private static func minimumFixedClipDuration(segmentLength: Double) -> Double {
        guard segmentLength.isFinite, segmentLength > 0 else { return 1.0 }
        return min(max(segmentLength * 0.5, 0.10), 1.0)
    }

    private static func rangesOverlap(_ lhs: ClipRange, _ rhs: ClipRange, tolerance: Double) -> Bool {
        if abs(lhs.startSeconds - rhs.startSeconds) <= tolerance,
           abs(lhs.endSeconds - rhs.endSeconds) <= tolerance {
            return true
        }
        return lhs.startSeconds < rhs.endSeconds - tolerance
            && rhs.startSeconds < lhs.endSeconds - tolerance
    }
}
