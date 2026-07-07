// `.reelclip` file codec — encodes an in-app MediaProject into the
// shareable JSON envelope, and decodes an incoming file back into a
// MediaProject. Handles the "source video may be missing on the recipient"
// case gracefully by looking up the PHAsset via localIdentifier and
// falling back to a "source missing" placeholder that the UI surfaces
// with a re-pick prompt.

import Foundation
import Photos
import UIKit

/// Result of decoding a `.reelclip` file. `project` is always populated;
/// `sourceResolution` describes how the source video was resolved so the
/// UI can show a banner when the recipient has to re-pick.
struct ReelClipImportResult {
    let project: MediaProject
    let sourceResolution: SourceResolution

    enum SourceResolution: Equatable {
        /// Found via PHAsset localIdentifier and copied into the recipient's
        /// imports directory — full editing capability.
        case resolvedViaPhotos(importedURL: URL, asset: PHAsset)
        /// Recipient has a video with the same original filename in their
        /// Photos library; we used that. Filename-only matches are weaker
        /// than identifier matches so the UI shows a "verify this is the
        /// right clip" hint.
        case resolvedViaFilename(importedURL: URL, asset: PHAsset)
        /// Source not found in the recipient's library. The project loads
        /// but the planned ranges can't be previewed until the user picks
        /// a replacement video.
        case missing
    }
}

enum ReelClipProjectCodec {
    static func encode(_ project: MediaProject,
                       sourceAsset: PHAsset? = nil,
                       sourceFileSize: Int64? = nil,
                       appVersion: String) throws -> Data {
        let photoId = sourceAsset?.localIdentifier
        // Use `PHAssetResource.assetResources(for:).originalFilename` (public API)
        // instead of KVC `value(forKey: "filename")` which is a private API and
        // risks App Store rejection + silent breakage on iOS updates.
        var originalFilename: String {
            if let asset = sourceAsset {
                let resources = PHAssetResource.assetResources(for: asset)
                if let name = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo })?.originalFilename {
                    return name
                }
                if let name = resources.first?.originalFilename {
                    return name
                }
            }
            return project.sourceFileName
        }
        let fileSize: Int64? = {
            if let sourceFileSize { return sourceFileSize }
            guard let asset = sourceAsset else { return nil }
            // Estimate from pixel dimensions × duration instead of KVC on
            // PHAssetResource.fileSize (private API).
            let pixelWidth = asset.pixelWidth
            let pixelHeight = asset.pixelHeight
            let durationSeconds = asset.duration.rounded(.up)
            if pixelWidth > 0 && pixelHeight > 0 && durationSeconds > 0 {
                // Rough estimate: pixels × duration × 0.5 bytes/pixel/frame @ 30fps
                return Int64(pixelWidth) * Int64(pixelHeight) * Int64(durationSeconds) * 15
            }
            return nil
        }()

        let payload = ReelClipProjectFile(
            project: project,
            sourcePhotoLibraryIdentifier: photoId,
            sourceOriginalFilename: originalFilename,
            sourceFileSize: fileSize
        )
        let envelope = ReelClipProjectEnvelope(payload: payload, appVersion: appVersion)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    /// Decode bytes read from a `.reelclip` file into an importable project.
    /// The source video resolution happens inside this call — caller just
    /// gets a fully-formed `ReelClipImportResult`.
    ///
    /// This function is async so the PHAsset resource copy (which can take
    /// seconds for iCloud assets) runs off the caller's thread. The previous
    /// synchronous version used `DispatchSemaphore.wait()` which deadlocked
    /// the main thread when called from `@MainActor` context.
    static func decode(_ data: Data,
                       workspace: MediaWorkspace = MediaWorkspace()) async throws -> ReelClipImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: ReelClipProjectEnvelope
        do {
            envelope = try decoder.decode(ReelClipProjectEnvelope.self, from: data)
        } catch {
            throw NSError(
                domain: "ReelClipProjectCodec",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't read the .reelclip file — it may be from a newer ReelClip version or corrupted."]
            )
        }
        guard (1...ReelClipProjectEnvelope.currentSchemaVersion).contains(envelope.schemaVersion) else {
            throw NSError(
                domain: "ReelClipProjectCodec",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "This .reelclip file was exported from a newer ReelClip version. Update the app to open it."]
            )
        }

        let payload = envelope.payload
        let resolution = await resolveSource(payload: payload, workspace: workspace)
        let sourcePath: String
        let sourceFileName: String
        let cutMode: CutMode?
        switch resolution {
        case .resolvedViaPhotos(let url, _), .resolvedViaFilename(let url, _):
            sourcePath = url.path
            sourceFileName = url.lastPathComponent
            cutMode = nil
        case .missing:
            // Empty placeholder path — UI shows a "source missing, pick
            // a replacement" banner and the user can re-link.
            sourcePath = ""
            sourceFileName = payload.sourceOriginalFilename ?? ""
            cutMode = nil
        }
        let project = payload.toMediaProject(sourcePath: sourcePath, sourceFileName: sourceFileName, cutMode: cutMode)
        return ReelClipImportResult(project: project, sourceResolution: resolution)
    }

    // MARK: - Source resolution

    private static func resolveSource(payload: ReelClipProjectFile,
                                      workspace: MediaWorkspace) async -> ReelClipImportResult.SourceResolution {
        // 1) Exact PHAsset match by localIdentifier — strongest signal.
        if let id = payload.sourcePhotoLibraryIdentifier,
           let asset = fetchAsset(localIdentifier: id) {
            if let url = try? await copyAssetToImports(asset: asset, workspace: workspace) {
                return .resolvedViaPhotos(importedURL: url, asset: asset)
            }
        }

        // 2) Filename + size fallback — PHAsset.filename is queryable via
        //    a metadata fetch. Cheaper than fetching the underlying file.
        if let name = payload.sourceOriginalFilename {
            let assets = fetchAssetsByFilename(name)
            // Prefer size match if we have one.
            let match = assets.first(where: { asset in
                guard let expectedSize = payload.sourceFileSize else { return true }
                return matchesAssetSize(asset: asset, expected: expectedSize)
            }) ?? assets.first
            if let asset = match,
               let url = try? await copyAssetToImports(asset: asset, workspace: workspace) {
                return .resolvedViaFilename(importedURL: url, asset: asset)
            }
        }

        return .missing
    }

    private static func fetchAsset(localIdentifier: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return result.firstObject
    }

    private static func fetchAssetsByFilename(_ filename: String) -> [PHAsset] {
        // PHAsset doesn't index filename. Search by creation date and
        // filter via the filename key. Limited but better than nothing.
        // For now, return empty — a later iteration can implement a
        // metadata scan via PHAssetResource.assetResources(for:).
        return []
    }

    private static func matchesAssetSize(asset: PHAsset, expected: Int64) -> Bool {
        // Estimate from pixel dimensions × duration instead of KVC on
        // PHAssetResource.fileSize (private API).
        let pixelWidth = asset.pixelWidth
        let pixelHeight = asset.pixelHeight
        let durationSeconds = asset.duration.rounded(.up)
        guard pixelWidth > 0, pixelHeight > 0, durationSeconds > 0 else { return false }
        let estimated = Int64(pixelWidth) * Int64(pixelHeight) * Int64(durationSeconds) * 15
        // Allow 50% tolerance since this is an estimate, not exact bytes.
        let tolerance = expected / 2
        return abs(estimated - expected) <= tolerance
    }

    /// Copy the PHAsset's underlying video resource into the workspace's
    /// imports directory. Async so the caller can `await` it without
    /// blocking — the previous synchronous version used
    /// `DispatchSemaphore.wait()` which deadlocked the main thread when
    /// the PHAssetResourceManager callback fired on the main queue.
    private static func copyAssetToImports(asset: PHAsset,
                                           workspace: MediaWorkspace) async throws -> URL {
        try workspace.prepareBaseDirectories()
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo })
                ?? resources.first else {
            throw NSError(domain: "ReelClipProjectCodec", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Source video has no video resource."])
        }
        let filename = (resource.originalFilename as String?) ?? "imported-\(asset.localIdentifier.prefix(8)).mov"
        let dest = FilenameSanitizer.uniqueURL(for: filename, in: workspace.importsDirectory)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: dest,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return dest
    }
}