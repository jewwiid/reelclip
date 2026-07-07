// `.reelclip` file format — JSON envelope describing a saved ReelClip project.
//
// Designed to be portable across installs and machines: a `.reelclip` file is
// a small JSON snapshot (KB scale) that REFERENCES the source video via its
// Photos library localIdentifier. The actual video bytes stay in Photos. If
// the recipient doesn't have the source video, the project still loads —
// the planned ranges are visible, just in a "source missing" state that
// prompts the user to re-pick a matching video.
//
// Schema versioning lives at the envelope level so we can ship breaking
// changes without bricking existing user files.

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// The custom UTI for ReelClip project files. Declared in Info.plist under
/// `UTExportedTypeDeclarations` so iOS knows the `.reelclip` extension and
/// routes taps in Files / share sheets back to us.
extension UTType {
    static let reelClipProject = UTType(exportedAs: "com.reelclip.project")
}

/// Top-level JSON envelope. Versioned so we can evolve the schema safely.
struct ReelClipProjectEnvelope: Codable {
    static let currentSchemaVersion = 1

    /// Schema version of `payload`. Bump when changing `ReelClipProjectFile`
    /// in a non-backward-compatible way; readers can refuse unknown versions
    /// rather than silently mis-parse.
    let schemaVersion: Int
    /// ReelClip app version that wrote this file (informational, used in
    /// "imported from older version" warnings if shape drifts).
    let appVersion: String
    /// ISO 8601 — when the envelope was written. Useful for sorting in
    /// Files even if the project payload lacks a createdAt.
    let exportedAt: Date
    let payload: ReelClipProjectFile

    init(payload: ReelClipProjectFile, appVersion: String) {
        self.schemaVersion = ReelClipProjectEnvelope.currentSchemaVersion
        self.appVersion = appVersion
        self.exportedAt = Date()
        self.payload = payload
    }
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

    var plannedRanges: [ClipRange]
    var exportedClips: [ReelClipStoredClip]
    var scrubPositionSeconds: Double
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
    /// Relative filename of the exported clip (e.g. "clip-1.mov"). The
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

        self.plannedRanges = project.plannedRanges
        self.exportedClips = project.exportedClips.map(ReelClipStoredClip.init)
        self.scrubPositionSeconds = project.scrubPositionSeconds
        self.createdAt = project.createdAt
        self.updatedAt = project.updatedAt
        self.sourcePhotoLibraryIdentifier = sourcePhotoLibraryIdentifier
        self.sourceOriginalFilename = sourceOriginalFilename
        self.sourceFileSize = sourceFileSize
        // Highlight resume state isn't part of MediaProject today; we
        // leave the optionals nil. A later migration can populate them
        // once the viewmodel publishes them.
        self.highlightDraftStart = nil
        self.highlightDraftDuration = nil
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
            plannedRanges: plannedRanges,
            exportedClips: exportedClips.map { $0.toStoredClip() },
            scrubPositionSeconds: scrubPositionSeconds,
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