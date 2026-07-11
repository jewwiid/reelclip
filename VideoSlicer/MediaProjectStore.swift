import Foundation

struct StoredClipOutput: Identifiable, Codable, Equatable {
    let id: UUID
    var index: Int
    var title: String
    var path: String
    var startSeconds: Double
    var endSeconds: Double
    var photoLibraryLocalIdentifier: String?

    var url: URL {
        URL(fileURLWithPath: path)
    }

    init(
        id: UUID = UUID(),
        index: Int,
        title: String = "",
        path: String,
        startSeconds: Double,
        endSeconds: Double,
        photoLibraryLocalIdentifier: String? = nil
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.path = path
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.photoLibraryLocalIdentifier = photoLibraryLocalIdentifier
    }

    init(clip: SegmentOutput) {
        self.id = clip.id
        self.index = clip.index
        // Store the raw (possibly empty) title so a user-cleared rename
        // round-trips exactly. `SegmentOutput.displayTitle` does the fallback
        // at render time.
        self.title = clip.title
        self.path = clip.url.standardizedFileURL.path
        self.startSeconds = clip.startSeconds
        self.endSeconds = clip.endSeconds
        self.photoLibraryLocalIdentifier = clip.photoLibraryLocalIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case id, index, title, path, startSeconds, endSeconds, photoLibraryLocalIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.index = try container.decode(Int.self, forKey: .index)
        // Projects saved before the rename feature shipped don't have a
        // title field. Decode-if-present keeps those projects loadable.
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.path = try container.decode(String.self, forKey: .path)
        self.startSeconds = try container.decode(Double.self, forKey: .startSeconds)
        self.endSeconds = try container.decode(Double.self, forKey: .endSeconds)
        self.photoLibraryLocalIdentifier = try container.decodeIfPresent(String.self, forKey: .photoLibraryLocalIdentifier)
    }

    var segmentOutput: SegmentOutput {
        SegmentOutput(
            id: id,
            index: index,
            title: title,
            url: url,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            photoLibraryLocalIdentifier: photoLibraryLocalIdentifier
        )
    }
}

/// Recipe controls that need to follow a scene when a project is reopened or
/// handed to another editor. Render progress, thumbnail caches, proxy URLs,
/// and drag gestures are deliberately excluded because they are transient or
/// reproducible from the original source media.
struct MediaProjectSceneEditorState: Codable, Equatable {
    var timelineZoom: TimelineZoom
    var selectedAIProvider: AIProvider
    var hasManualHighlightDuration: Bool
    var fixedModeInputStyle: FixedModeInputStyle
    var fixedModeQueryDraft: String
    var fixedModeButtonCount: Int
    var fixedModeButtonDuration: Int
    var fixedModeButtonInterval: Int
    var fixedModeRandomDuration: Bool
    var fixedModeRandomInterval: Bool
    var fixedModeRandomDurationMinimum: Int
    var fixedModeRandomDurationMaximum: Int
    var fixedModeRandomIntervalMinimum: Int
    var fixedModeRandomIntervalMaximum: Int
    var fixedModeRandomSeed: UInt64
}

struct MediaProjectScene: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// Per-scene source video. The path is a file URL to a local copy
    /// (from `MediaWorkspace.importSourceCopy`); for Photos imports,
    /// `sourcePhotoLibraryIdentifier` carries the PHAsset localIdentifier for
    /// local and legacy recovery. Portable v3 packages embed the source and
    /// remove that identifier. Per-scene source means Scene 1 can be a cut of
    /// clip A and Scene 2 of clip B in the same project.
    ///
    /// - `sourcePath` / `sourceFileName` / `durationSeconds` /
    ///   `sourceAspectRatio` / `frameDurationSeconds` are the snapshot
    ///   taken at the time the scene was created or last loaded with
    ///   this source. They make the scene self-describing for the
    ///   codec and for legacy replay (when the project-level cache
    ///   has been wiped).
    /// - `sourcePhotoLibraryIdentifier` is the PHAsset reference.
    /// - `sourceOriginalFilename` is the human-readable name shown
    ///   in the scene switcher when the file path has been moved
    ///   (e.g. the temp dir was cleaned).
    ///
    /// All fields are optional because a freshly-added blank scene
    /// might not have a source yet, and legacy v2 scenes (saved
    /// before this field set existed) decode with nil.
    var sourcePath: String?
    var sourceFileName: String?
    var sourcePhotoLibraryIdentifier: String?
    var sourceOriginalFilename: String?
    var durationSeconds: Double?
    var sourceAspectRatio: Double?
    var frameDurationSeconds: Double?
    var cutMode: CutMode
    var segmentLengthText: String
    var editPrompt: String
    var plannedRanges: [ClipRange]
    var highlightDraftStart: Double?
    var highlightDraftDuration: Double?
    /// Transcript belongs to the scene source, not to the project globally.
    /// Optional keeps projects written before per-scene transcripts loadable.
    var transcript: Transcript?
    var editorState: MediaProjectSceneEditorState?
    var scrubPositionSeconds: Double
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        sourcePath: String? = nil,
        sourceFileName: String? = nil,
        sourcePhotoLibraryIdentifier: String? = nil,
        sourceOriginalFilename: String? = nil,
        durationSeconds: Double? = nil,
        sourceAspectRatio: Double? = nil,
        frameDurationSeconds: Double? = nil,
        cutMode: CutMode,
        segmentLengthText: String,
        editPrompt: String,
        plannedRanges: [ClipRange],
        highlightDraftStart: Double? = nil,
        highlightDraftDuration: Double? = nil,
        transcript: Transcript? = nil,
        editorState: MediaProjectSceneEditorState? = nil,
        scrubPositionSeconds: Double,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.sourceFileName = sourceFileName
        self.sourcePhotoLibraryIdentifier = sourcePhotoLibraryIdentifier
        self.sourceOriginalFilename = sourceOriginalFilename
        self.durationSeconds = durationSeconds
        self.sourceAspectRatio = sourceAspectRatio
        self.frameDurationSeconds = frameDurationSeconds
        self.cutMode = cutMode
        self.segmentLengthText = segmentLengthText
        self.editPrompt = editPrompt
        self.plannedRanges = plannedRanges
        self.highlightDraftStart = highlightDraftStart
        self.highlightDraftDuration = highlightDraftDuration
        self.transcript = transcript
        self.editorState = editorState
        self.scrubPositionSeconds = scrubPositionSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True when this scene has a usable local file path (or a Photos
    /// identifier the loader knows how to resolve). `false` for fresh
    /// scenes the user created from a snapshot before picking a source.
    var hasSource: Bool {
        sourcePath?.isEmpty == false || sourcePhotoLibraryIdentifier?.isEmpty == false
    }

    /// File URL for the per-scene source video, when the source lives
    /// as a local file. `nil` for Photos-only scenes (which the loader
    /// resolves via `sourcePhotoLibraryIdentifier`).
    var sourceURL: URL? {
        guard let sourcePath, !sourcePath.isEmpty else { return nil }
        return URL(fileURLWithPath: sourcePath)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case sourcePath, sourceFileName, sourcePhotoLibraryIdentifier, sourceOriginalFilename
        case durationSeconds, sourceAspectRatio, frameDurationSeconds
        case cutMode, segmentLengthText, editPrompt, plannedRanges
        case highlightDraftStart, highlightDraftDuration, transcript, editorState, scrubPositionSeconds
        case createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        // Per-scene source fields were added in v3 of the scene
        // schema. Decode-if-present keeps v2 projects loadable;
        // their scenes decode as "no per-scene source yet", and the
        // project-level source fills in at the view-model layer.
        self.sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        self.sourceFileName = try c.decodeIfPresent(String.self, forKey: .sourceFileName)
        self.sourcePhotoLibraryIdentifier = try c.decodeIfPresent(String.self, forKey: .sourcePhotoLibraryIdentifier)
        self.sourceOriginalFilename = try c.decodeIfPresent(String.self, forKey: .sourceOriginalFilename)
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        self.sourceAspectRatio = try c.decodeIfPresent(Double.self, forKey: .sourceAspectRatio)
        self.frameDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .frameDurationSeconds)
        self.cutMode = try c.decode(CutMode.self, forKey: .cutMode)
        self.segmentLengthText = try c.decode(String.self, forKey: .segmentLengthText)
        self.editPrompt = try c.decode(String.self, forKey: .editPrompt)
        self.plannedRanges = try c.decode([ClipRange].self, forKey: .plannedRanges)
        self.highlightDraftStart = try c.decodeIfPresent(Double.self, forKey: .highlightDraftStart)
        self.highlightDraftDuration = try c.decodeIfPresent(Double.self, forKey: .highlightDraftDuration)
        self.transcript = try c.decodeIfPresent(Transcript.self, forKey: .transcript)
        self.editorState = try c.decodeIfPresent(MediaProjectSceneEditorState.self, forKey: .editorState)
        self.scrubPositionSeconds = try c.decode(Double.self, forKey: .scrubPositionSeconds)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(sourcePath, forKey: .sourcePath)
        try c.encodeIfPresent(sourceFileName, forKey: .sourceFileName)
        try c.encodeIfPresent(sourcePhotoLibraryIdentifier, forKey: .sourcePhotoLibraryIdentifier)
        try c.encodeIfPresent(sourceOriginalFilename, forKey: .sourceOriginalFilename)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(sourceAspectRatio, forKey: .sourceAspectRatio)
        try c.encodeIfPresent(frameDurationSeconds, forKey: .frameDurationSeconds)
        try c.encode(cutMode, forKey: .cutMode)
        try c.encode(segmentLengthText, forKey: .segmentLengthText)
        try c.encode(editPrompt, forKey: .editPrompt)
        try c.encode(plannedRanges, forKey: .plannedRanges)
        try c.encodeIfPresent(highlightDraftStart, forKey: .highlightDraftStart)
        try c.encodeIfPresent(highlightDraftDuration, forKey: .highlightDraftDuration)
        try c.encodeIfPresent(transcript, forKey: .transcript)
        try c.encodeIfPresent(editorState, forKey: .editorState)
        try c.encode(scrubPositionSeconds, forKey: .scrubPositionSeconds)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

struct MediaProject: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var sourcePath: String
    var sourceFileName: String
    var durationSeconds: Double
    var sourceAspectRatio: Double
    var frameDurationSeconds: Double
    var cutMode: CutMode
    var segmentLengthText: String
    var editPrompt: String
    var plannedRanges: [ClipRange]
    /// Committed planned ranges. Populated by the project-level
    /// "Save" action, which snapshots the current planned ranges
    /// into this list. Persisted across app launches + into
    /// `.reelclip` files so the user can return to a project and
    /// see what they previously committed. Independent of
    /// `exportedClips`, which tracks the post-render
    /// `SegmentOutput` files (the rendered state). New in v2.0 —
    /// legacy projects decode with an empty array.
    var savedClips: [ClipRange]
    var scenes: [MediaProjectScene]
    var activeSceneId: UUID?
    var exportedClips: [StoredClipOutput]
    /// Optional permutation into the canonical scene-then-range list.
    /// Persisted only while its count matches the project clip count.
    var projectExportOrder: [Int]?
    /// Optional permutation into `savedClips`.
    var savedClipsOrder: [Int]?
    var scrubPositionSeconds: Double
    var transcript: Transcript?
    var createdAt: Date
    var updatedAt: Date
    /// PHAsset localIdentifier for local source recovery. Legacy reference-only
    /// `.reelclip` files use it; portable v3 packages strip it because they
    /// embed the source and should not leak sender-specific library IDs.
    var sourcePhotoLibraryIdentifier: String?
    /// User-picked export settings (resolution + frame rate).
    /// `nil` for projects created before the settings feature
    /// shipped — the view model layers in a tier-appropriate
    /// default on first read. Stored on the project (not the
    /// scene) so a project's settings follow the .reelclip
    /// file regardless of which scene is active.
    var exportSettings: ExportSettings?

    var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    var activeScene: MediaProjectScene? {
        if let activeSceneId,
           let scene = scenes.first(where: { $0.id == activeSceneId }) {
            return scene
        }

        return scenes.first
    }

    init(
        id: UUID,
        title: String,
        sourcePath: String,
        sourceFileName: String,
        durationSeconds: Double,
        sourceAspectRatio: Double,
        frameDurationSeconds: Double,
        cutMode: CutMode,
        segmentLengthText: String,
        editPrompt: String,
        plannedRanges: [ClipRange],
        scenes: [MediaProjectScene]? = nil,
        activeSceneId: UUID? = nil,
        exportedClips: [StoredClipOutput] = [],
        projectExportOrder: [Int]? = nil,
        savedClipsOrder: [Int]? = nil,
        savedClips: [ClipRange] = [],
        scrubPositionSeconds: Double,
        transcript: Transcript? = nil,
        sourcePhotoLibraryIdentifier: String? = nil,
        exportSettings: ExportSettings? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {

        self.id = id
        self.title = title
        self.sourcePath = sourcePath
        self.sourceFileName = sourceFileName
        self.durationSeconds = durationSeconds
        self.sourceAspectRatio = sourceAspectRatio
        self.frameDurationSeconds = frameDurationSeconds
        self.cutMode = cutMode
        self.segmentLengthText = segmentLengthText
        self.editPrompt = editPrompt
        self.plannedRanges = plannedRanges
        self.savedClips = savedClips
        let resolvedScenes: [MediaProjectScene]
        if let scenes, !scenes.isEmpty {
            resolvedScenes = scenes
        } else {
            // Legacy v1 projects (no scenes array at all) become a
            // single scene that inherits the project's source. The
            // user can add more scenes later, each with their own
            // source.
            resolvedScenes = [
                MediaProjectScene(
                    name: "Scene 1",
                    sourcePath: sourcePath,
                    sourceFileName: sourceFileName,
                    sourcePhotoLibraryIdentifier: sourcePhotoLibraryIdentifier,
                    sourceOriginalFilename: sourceFileName,
                    durationSeconds: durationSeconds,
                    sourceAspectRatio: sourceAspectRatio,
                    frameDurationSeconds: frameDurationSeconds,
                    cutMode: cutMode,
                    segmentLengthText: segmentLengthText,
                    editPrompt: editPrompt,
                    plannedRanges: plannedRanges,
                    scrubPositionSeconds: scrubPositionSeconds,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            ]
        }
        self.scenes = resolvedScenes
        self.activeSceneId = activeSceneId ?? resolvedScenes.first?.id
        self.exportedClips = exportedClips
        self.projectExportOrder = projectExportOrder
        self.savedClipsOrder = savedClipsOrder
        self.scrubPositionSeconds = scrubPositionSeconds
        self.transcript = transcript
        self.sourcePhotoLibraryIdentifier = sourcePhotoLibraryIdentifier
        // Tier-aware default if the project predates the export
        // settings feature (i.e. came from a legacy .reelclip
        // decode). New projects get a real value set at the
        // view-model layer when the source is loaded.
        self.exportSettings = exportSettings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourcePath
        case sourceFileName
        case durationSeconds
        case sourceAspectRatio
        case frameDurationSeconds
        case cutMode
        case segmentLengthText
        case editPrompt
        case plannedRanges
        case savedClips
        case scenes
        case activeSceneId
        case exportedClips
        case projectExportOrder
        case savedClipsOrder
        case scrubPositionSeconds
        case transcript
        case sourcePhotoLibraryIdentifier
        case exportSettings
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        let decodedSourcePath = try container.decode(String.self, forKey: .sourcePath)
        let decodedSourceFileName = try container.decode(String.self, forKey: .sourceFileName)
        let decodedDurationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        let decodedSourceAspectRatio = try container.decode(Double.self, forKey: .sourceAspectRatio)
        let decodedFrameDurationSeconds = try container.decode(Double.self, forKey: .frameDurationSeconds)
        self.sourcePath = decodedSourcePath
        self.sourceFileName = decodedSourceFileName
        self.durationSeconds = decodedDurationSeconds
        self.sourceAspectRatio = decodedSourceAspectRatio
        self.frameDurationSeconds = decodedFrameDurationSeconds
        self.exportedClips = try container.decodeIfPresent([StoredClipOutput].self, forKey: .exportedClips) ?? []
        self.projectExportOrder = try container.decodeIfPresent([Int].self, forKey: .projectExportOrder)
        self.savedClipsOrder = try container.decodeIfPresent([Int].self, forKey: .savedClipsOrder)
        self.transcript = try container.decodeIfPresent(Transcript.self, forKey: .transcript)
        let decodedSourcePhotoLibraryIdentifier = try container.decodeIfPresent(String.self, forKey: .sourcePhotoLibraryIdentifier)
        self.sourcePhotoLibraryIdentifier = decodedSourcePhotoLibraryIdentifier
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        let decodedScenes = try container.decodeIfPresent([MediaProjectScene].self, forKey: .scenes) ?? []
        let decodedActiveSceneId = try container.decodeIfPresent(UUID.self, forKey: .activeSceneId)
        let decodedActiveScene = decodedActiveSceneId.flatMap { id in
            decodedScenes.first(where: { $0.id == id })
        } ?? decodedScenes.first
        let legacyCutMode = try container.decodeIfPresent(CutMode.self, forKey: .cutMode)
        let legacySegmentLengthText = try container.decodeIfPresent(String.self, forKey: .segmentLengthText)
        let legacyEditPrompt = try container.decodeIfPresent(String.self, forKey: .editPrompt)
        let legacyPlannedRanges = try container.decodeIfPresent([ClipRange].self, forKey: .plannedRanges)
        let legacyScrubPositionSeconds = try container.decodeIfPresent(Double.self, forKey: .scrubPositionSeconds)
        // Decoded-if-present so projects saved before the "Save"
        // button existed (no `savedClips` field) stay loadable —
        // they just open with an empty saved row.
        let decodedSavedClips = try container.decodeIfPresent([ClipRange].self, forKey: .savedClips) ?? []

        self.cutMode = decodedActiveScene?.cutMode ?? legacyCutMode ?? .highlight
        self.segmentLengthText = decodedActiveScene?.segmentLengthText ?? legacySegmentLengthText ?? "30"
        self.editPrompt = decodedActiveScene?.editPrompt ?? legacyEditPrompt ?? "Make a fast reel"
        self.plannedRanges = decodedActiveScene?.plannedRanges ?? legacyPlannedRanges ?? []
        self.savedClips = decodedSavedClips
        self.scrubPositionSeconds = decodedActiveScene?.scrubPositionSeconds ?? legacyScrubPositionSeconds ?? 0
        // Decoded-if-present so projects saved before the export
        // settings feature shipped (no `exportSettings` field)
        // stay loadable. The view model layers in a tier default
        // on first read.
        self.exportSettings = try container.decodeIfPresent(ExportSettings.self, forKey: .exportSettings)

        if decodedScenes.isEmpty {
            // Legacy v1 decode path: a project saved before scenes
            // existed becomes a single scene that inherits the
            // project's source. The project-level source fields
            // remain the "active source" cache; the scene records
            // it for per-scene source switching.
            let legacyScene = MediaProjectScene(
                name: "Scene 1",
                sourcePath: decodedSourcePath,
                sourceFileName: decodedSourceFileName,
                sourcePhotoLibraryIdentifier: decodedSourcePhotoLibraryIdentifier,
                sourceOriginalFilename: decodedSourceFileName,
                durationSeconds: decodedDurationSeconds,
                sourceAspectRatio: decodedSourceAspectRatio,
                frameDurationSeconds: decodedFrameDurationSeconds,
                cutMode: cutMode,
                segmentLengthText: segmentLengthText,
                editPrompt: editPrompt,
                plannedRanges: plannedRanges,
                scrubPositionSeconds: scrubPositionSeconds,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            self.scenes = [legacyScene]
            self.activeSceneId = legacyScene.id
        } else {
            // v2 scenes saved before per-scene source fields existed
            // only make sense if they had a plan against the old
            // project-level source. Stamp that source onto planned
            // legacy scenes so a later source change in another scene
            // does not make them render against the wrong video.
            // Intentionally blank scenes stay source-less.
            self.scenes = decodedScenes.map { scene in
                guard !scene.hasSource, !scene.plannedRanges.isEmpty else { return scene }
                var resolved = scene
                resolved.sourcePath = decodedSourcePath
                resolved.sourceFileName = decodedSourceFileName
                resolved.sourcePhotoLibraryIdentifier = decodedSourcePhotoLibraryIdentifier
                resolved.sourceOriginalFilename = decodedSourceFileName
                resolved.durationSeconds = resolved.durationSeconds ?? decodedDurationSeconds
                resolved.sourceAspectRatio = resolved.sourceAspectRatio ?? decodedSourceAspectRatio
                resolved.frameDurationSeconds = resolved.frameDurationSeconds ?? decodedFrameDurationSeconds
                return resolved
            }
            self.activeSceneId = decodedActiveSceneId ?? decodedScenes.first?.id
        }
    }
}

struct MediaProjectStore {
    let workspace: MediaWorkspace

    private var indexURL: URL {
        workspace.projectsDirectory.appendingPathComponent("projects.json")
    }

    init(workspace: MediaWorkspace = MediaWorkspace()) {
        self.workspace = workspace
    }

    func loadProjects() throws -> [MediaProject] {
        guard workspace.fileManager.fileExists(atPath: indexURL.path) else {
            return []
        }

        let data = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([MediaProject].self, from: data)
            .sortedByRecentUpdate()
    }

    @discardableResult
    func upsert(_ project: MediaProject) throws -> [MediaProject] {
        var projects = try loadProjects()

        if let existingIndex = projects.firstIndex(where: { $0.id == project.id }) {
            projects[existingIndex] = project
        } else {
            projects.append(project)
        }

        try saveProjects(projects)
        return projects.sortedByRecentUpdate()
    }

    @discardableResult
    func deleteProject(id: UUID) throws -> [MediaProject] {
        let projects = try loadProjects().filter { $0.id != id }
        try saveProjects(projects)
        return projects.sortedByRecentUpdate()
    }

    func saveProjects(_ projects: [MediaProject]) throws {
        try workspace.prepareBaseDirectories()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(projects.sortedByRecentUpdate())
        try data.write(to: indexURL, options: [.atomic])
    }
}

private extension Array where Element == MediaProject {
    func sortedByRecentUpdate() -> [MediaProject] {
        sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }

            return lhs.updatedAt > rhs.updatedAt
        }
    }
}
