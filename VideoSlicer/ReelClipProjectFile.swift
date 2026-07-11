// `.reelclip` project format.
//
// Schema v3 is a document package that contains `manifest.json`, original
// scene source media, and any rendered clips still present in the project.
// Packages remain editable when handed to another device or editor because
// import rewrites every media reference into the recipient's private
// workspace. V1/v2 flat JSON files remain readable and use their Photos
// identifiers as a best-effort legacy fallback.

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// The custom UTI for ReelClip project files. Declared in Info.plist under
/// `UTExportedTypeDeclarations` so iOS knows the `.reelclip` extension and
/// routes taps in Files / share sheets back to us.
extension UTType {
    static let reelClipProject = UTType(
        exportedAs: "com.reelclip.project",
        conformingTo: .package
    )
}

/// Top-level JSON envelope. Versioned so we can evolve the schema safely.
struct ReelClipProjectEnvelope: Codable {
    static let currentSchemaVersion = 3
    static let expectedFormatIdentifier = "app.reelclip.project"

    /// Schema version of `payload`. Bump when changing `ReelClipProjectFile`
    /// in a non-backward-compatible way; readers can refuse unknown versions
    /// rather than silently mis-parse.
    let schemaVersion: Int
    /// Stable magic value that prevents unrelated JSON packages from being
    /// mistaken for ReelClips projects. Nil only on legacy v1/v2 files.
    let formatIdentifier: String?
    /// ReelClip app version that wrote this file (informational, used in
    /// "imported from older version" warnings if shape drifts).
    let appVersion: String
    /// ISO 8601 — when the envelope was written. Useful for sorting in
    /// Files even if the project payload lacks a createdAt.
    let exportedAt: Date
    let payload: ReelClipProjectFile
    /// Present for portable v3 packages. Nil for legacy flat JSON files.
    let media: ReelClipProjectMediaManifest?

    init(
        payload: ReelClipProjectFile,
        appVersion: String,
        media: ReelClipProjectMediaManifest? = nil
    ) {
        self.schemaVersion = ReelClipProjectEnvelope.currentSchemaVersion
        self.formatIdentifier = ReelClipProjectEnvelope.expectedFormatIdentifier
        self.appVersion = appVersion
        self.exportedAt = Date()
        self.payload = payload
        self.media = media
    }
}

/// Attachment table for a portable `.reelclip` package. Relationships live in
/// explicit arrays rather than absolute paths so the manifest never leaks a
/// sender's sandbox UUID and can be remapped safely on import.
struct ReelClipProjectMediaManifest: Codable, Equatable {
    var attachments: [ReelClipMediaAttachment]
    var projectSourceAttachmentID: UUID?
    var sceneSourceLinks: [ReelClipSceneSourceLink]
    var storedClipLinks: [ReelClipStoredClipLink]
}

struct ReelClipMediaAttachment: Codable, Equatable, Identifiable {
    enum Role: String, Codable {
        case source
        case renderedClip
    }

    let id: UUID
    let role: Role
    /// POSIX-style path relative to the package root, for example
    /// `Media/Sources/<uuid>-source.mov`.
    let relativePath: String
    let originalFilename: String
    let byteCount: Int64
}

struct ReelClipSceneSourceLink: Codable, Equatable {
    let sceneID: UUID
    let attachmentID: UUID
}

struct ReelClipStoredClipLink: Codable, Equatable {
    let clipID: UUID
    let attachmentID: UUID
}

/// The actual project snapshot. Fields are additive — when adding new state
/// decode-if-present so old envelopes keep loading. Removing/renaming fields
/// is a schema bump.
struct ReelClipProjectFile: Codable {
    /// The MediaProject data, re-encoded with stable keys for forward
    /// compatibility (the in-app `MediaProject` may evolve independently).
    var id: UUID
    var title: String
    var durationSeconds: Double
    var sourceAspectRatio: Double
    var frameDurationSeconds: Double
    var cutModeRaw: String
    var segmentLengthText: String
    var editPrompt: String
    var plannedRanges: [ClipRange]
    /// Committed planned ranges. Optional on the wire so older
    /// `.reelclip` files (pre-v2.0) decode cleanly — recipients
    /// fall back to an empty array and the user can re-save in
    /// the current build to populate it.
    var savedClips: [ClipRange]?
    var scenes: [MediaProjectScene]?
    var activeSceneId: UUID?
    var exportedClips: [ReelClipStoredClip]
    var projectExportOrder: [Int]?
    var savedClipsOrder: [Int]?
    var scrubPositionSeconds: Double
    var transcript: Transcript?
    var exportSettings: ExportSettings?
    var createdAt: Date
    var updatedAt: Date

    // Source video references — none of these are required. Recipients try
    // them in order: localIdentifier (Photos), original filename (Photos
    // search by filename), then fall back to "source missing" with a
    // user-prompt to re-pick.
    var sourcePhotoLibraryIdentifier: String?
    var sourceOriginalFilename: String?
    /// File size hint, useful when matching by filename — two videos with
    /// the same name but different sizes shouldn't both match.
    var sourceFileSize: Int64?

    // Highlight-mode resume state — so users can pick up a chain where
    // they left off.
    var highlightDraftStart: Double?
    var highlightDraftDuration: Double?
}

/// One saved clip inside a project. References the exported clip by
/// relative filename (NOT absolute path) so the file is portable across
/// devices. The recipient rewrites the path to their own sandbox on import.
/// Also references the clip via Photos `localIdentifier` as a fallback.
struct ReelClipStoredClip: Codable {
    var id: UUID
    var index: Int
    var title: String
    /// Relative filename of the exported clip (e.g. "clip-01.mov"). The
    /// recipient rewrites this to their own exports directory on import.
    /// Storing absolute sandbox paths leaked the sender's container UUID
    /// and was always invalid on the recipient.
    var originalPath: String
    var startSeconds: Double
    var endSeconds: Double
    var photoLibraryLocalIdentifier: String?
}

// MARK: - MediaProject <-> ReelClipProjectFile bridging

extension ReelClipProjectFile {
    /// Build a file-ready snapshot from an in-app `MediaProject`.
    /// Source references are best-effort: we don't have direct access to
    /// the PHAsset here, so the caller is expected to populate
    /// `sourcePhotoLibraryIdentifier` from the picked video's asset.
    init(project: MediaProject,
         sourcePhotoLibraryIdentifier: String? = nil,
         sourceOriginalFilename: String? = nil,
         sourceFileSize: Int64? = nil) {
        self.id = project.id
        self.title = project.title
        self.durationSeconds = project.durationSeconds
        self.sourceAspectRatio = project.sourceAspectRatio
        self.frameDurationSeconds = project.frameDurationSeconds
        self.cutModeRaw = project.cutMode.rawValue
        self.segmentLengthText = project.segmentLengthText
        self.editPrompt = project.editPrompt
        self.plannedRanges = project.plannedRanges
        self.savedClips = project.savedClips
        self.scenes = project.scenes
        self.activeSceneId = project.activeSceneId
        self.exportedClips = project.exportedClips.map(ReelClipStoredClip.init)
        self.projectExportOrder = project.projectExportOrder
        self.savedClipsOrder = project.savedClipsOrder
        self.scrubPositionSeconds = project.scrubPositionSeconds
        self.transcript = project.transcript
        self.exportSettings = project.exportSettings
        self.createdAt = project.createdAt
        self.updatedAt = project.updatedAt
        self.sourcePhotoLibraryIdentifier = sourcePhotoLibraryIdentifier
        self.sourceOriginalFilename = sourceOriginalFilename
        self.sourceFileSize = sourceFileSize
        self.highlightDraftStart = project.activeScene?.highlightDraftStart
        self.highlightDraftDuration = project.activeScene?.highlightDraftDuration
    }

    /// Reconstitute an in-app `MediaProject` from a file snapshot.
    /// `sourcePath` / `sourceFileName` are filled by the importer based
    /// on whether the source video was found in Photos.
    func toMediaProject(sourcePath: String,
                        sourceFileName: String,
                        cutMode: CutMode? = nil) -> MediaProject {
        let resolvedCutMode = cutMode
            ?? CutMode(rawValue: cutModeRaw)
            ?? .fixed
        return MediaProject(
            id: id,
            title: title,
            sourcePath: sourcePath,
            sourceFileName: sourceFileName,
            durationSeconds: durationSeconds,
            sourceAspectRatio: sourceAspectRatio,
            frameDurationSeconds: frameDurationSeconds,
            cutMode: resolvedCutMode,
            segmentLengthText: segmentLengthText,
            editPrompt: editPrompt,
            plannedRanges: plannedRanges,
            scenes: scenes,
            activeSceneId: activeSceneId,
            exportedClips: exportedClips.map { $0.toStoredClip() },
            projectExportOrder: projectExportOrder,
            savedClipsOrder: savedClipsOrder,
            savedClips: savedClips ?? [],
            scrubPositionSeconds: scrubPositionSeconds,
            transcript: transcript,
            sourcePhotoLibraryIdentifier: sourcePhotoLibraryIdentifier,
            exportSettings: exportSettings,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

extension ReelClipStoredClip {
    init(_ stored: StoredClipOutput) {
        self.id = stored.id
        self.index = stored.index
        self.title = stored.title
        // Store only the relative filename, NOT the absolute sandbox path.
        // The sender's absolute path is invalid on the recipient's device
        // and leaks the sender's container UUID.
        self.originalPath = (stored.path as NSString).lastPathComponent
        self.startSeconds = stored.startSeconds
        self.endSeconds = stored.endSeconds
        self.photoLibraryLocalIdentifier = stored.photoLibraryLocalIdentifier
    }

    func toStoredClip() -> StoredClipOutput {
        StoredClipOutput(
            id: id,
            index: index,
            title: title,
            // `originalPath` is a relative filename. Callers that need
            // an absolute URL should resolve it against their workspace's
            // exports directory.
            path: originalPath,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            photoLibraryLocalIdentifier: photoLibraryLocalIdentifier
        )
    }
}
