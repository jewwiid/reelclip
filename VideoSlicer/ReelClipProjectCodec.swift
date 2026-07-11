// `.reelclip` project codec.
//
// V3 projects are document packages containing a JSON manifest plus the
// original media needed to continue editing on another device. V1/v2 flat
// JSON projects remain readable through their Photos references.

import Foundation
import Photos

struct ReelClipImportResult {
    let project: MediaProject
    let sourceResolution: SourceResolution

    enum SourceResolution: Equatable {
        /// A portable package supplied all original scene media.
        case resolvedViaPackage(importedSourceCount: Int)
        /// Legacy project source found by exact Photos identifier.
        case resolvedViaPhotos(importedURL: URL, asset: PHAsset)
        /// Legacy project source found by original filename.
        case resolvedViaFilename(importedURL: URL, asset: PHAsset)
        /// The active source could not be resolved. Metadata still imports so
        /// the user can relink footage without losing the cut plan.
        case missing
    }
}

enum ReelClipProjectCodecError: LocalizedError {
    case unreadableProject
    case unsupportedSchema
    case missingManifest
    case manifestTooLarge
    case invalidPackage(String)
    case missingSceneSource(String)
    case missingRenderedClip(String)

    var errorDescription: String? {
        switch self {
        case .unreadableProject:
            return "Couldn't read the .reelclip project. It may be corrupted or from an incompatible build."
        case .unsupportedSchema:
            return "This .reelclip project was exported by a newer ReelClips version. Update the app to open it."
        case .missingManifest:
            return "This .reelclip package is missing manifest.json."
        case .manifestTooLarge:
            return "This .reelclip manifest is larger than ReelClips can safely open."
        case .invalidPackage(let reason):
            return "This .reelclip package is incomplete or unsafe: \(reason)"
        case .missingSceneSource(let sceneName):
            return "\(sceneName)'s original video is unavailable. Relink that scene before exporting the project."
        case .missingRenderedClip(let clipName):
            return "The rendered clip \"\(clipName)\" is unavailable. Remove it from Saved clips or render it again before exporting the project."
        }
    }
}

enum ReelClipProjectCodec {
    static let manifestFilename = "manifest.json"

    private static let mediaDirectoryName = "Media"
    private static let sourcesDirectoryName = "Sources"
    private static let renderedDirectoryName = "Rendered"
    private static let maximumManifestBytes = 20 * 1_024 * 1_024
    private static let maximumAttachmentCount = 1_000

    // MARK: - Export

    /// Creates a portable package at `packageURL`. Original media is hard-linked
    /// into the staging package when possible, avoiding a second multi-GB copy
    /// inside the app container. File-provider export then transfers the package
    /// to the user's chosen destination.
    @discardableResult
    static func writePortablePackage(
        _ project: MediaProject,
        to packageURL: URL,
        appVersion: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let parentURL = packageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let stagingURL = parentURL.appendingPathComponent(
            ".\(packageURL.lastPathComponent).\(UUID().uuidString).partial",
            isDirectory: true
        )
        try? fileManager.removeItem(at: stagingURL)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        var completed = false
        defer {
            if !completed {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        let mediaURL = stagingURL.appendingPathComponent(mediaDirectoryName, isDirectory: true)
        let sourcesURL = mediaURL.appendingPathComponent(sourcesDirectoryName, isDirectory: true)
        let renderedURL = mediaURL.appendingPathComponent(renderedDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: renderedURL, withIntermediateDirectories: true)

        var attachments: [ReelClipMediaAttachment] = []
        var attachmentIDByRoleAndPath: [String: UUID] = [:]

        func stageAttachment(
            from sourceURL: URL,
            role: ReelClipMediaAttachment.Role,
            originalFilename: String?
        ) throws -> UUID {
            let standardizedURL = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
            let deduplicationKey = "\(role.rawValue)|\(standardizedURL.path)"
            if let existing = attachmentIDByRoleAndPath[deduplicationKey] {
                return existing
            }

            let values = try standardizedURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey
            ])
            guard values.isRegularFile == true else {
                throw ReelClipProjectCodecError.invalidPackage(
                    "\(standardizedURL.lastPathComponent) is not a regular media file."
                )
            }
            let byteCount = Int64(values.fileSize ?? 0)
            guard byteCount > 0 else {
                throw ReelClipProjectCodecError.invalidPackage(
                    "\(standardizedURL.lastPathComponent) is empty."
                )
            }

            let attachmentID = UUID()
            let requestedName = originalFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeOriginalName = requestedName.flatMap { $0.isEmpty ? nil : $0 }
                ?? standardizedURL.lastPathComponent
            let originalName = safeOriginalName as NSString
            let safeFilename = FilenameSanitizer.sanitizedFileName(
                from: originalName.deletingPathExtension,
                fallbackBase: role == .source ? "source" : "clip",
                fileExtension: originalName.pathExtension.isEmpty
                    ? standardizedURL.pathExtension
                    : originalName.pathExtension
            )
            let stagedFilename = "\(attachmentID.uuidString)-\(safeFilename)"
            let destinationDirectory = role == .source ? sourcesURL : renderedURL
            let destinationURL = destinationDirectory.appendingPathComponent(stagedFilename)

            do {
                try fileManager.linkItem(at: standardizedURL, to: destinationURL)
            } catch {
                // Temp and Application Support normally share an APFS volume,
                // so this is usually a metadata-only hard link. Copy is the
                // compatibility fallback for unusual file-provider layouts.
                try fileManager.copyItem(at: standardizedURL, to: destinationURL)
            }

            let relativeDirectory = role == .source ? sourcesDirectoryName : renderedDirectoryName
            attachments.append(
                ReelClipMediaAttachment(
                    id: attachmentID,
                    role: role,
                    relativePath: "\(mediaDirectoryName)/\(relativeDirectory)/\(stagedFilename)",
                    originalFilename: safeOriginalName,
                    byteCount: byteCount
                )
            )
            attachmentIDByRoleAndPath[deduplicationKey] = attachmentID
            return attachmentID
        }

        var sceneSourceLinks: [ReelClipSceneSourceLink] = []
        for scene in project.scenes {
            guard scene.hasSource else { continue }
            let candidateURL = scene.sourceURL
                ?? (scene.id == project.activeSceneId ? project.sourceURL : nil)
            guard let candidateURL,
                  fileManager.fileExists(atPath: candidateURL.path) else {
                throw ReelClipProjectCodecError.missingSceneSource(scene.name)
            }
            let attachmentID = try stageAttachment(
                from: candidateURL,
                role: .source,
                originalFilename: scene.sourceOriginalFilename ?? scene.sourceFileName
            )
            sceneSourceLinks.append(
                ReelClipSceneSourceLink(sceneID: scene.id, attachmentID: attachmentID)
            )
        }

        let activeSceneAttachmentID = project.activeSceneId.flatMap { activeID in
            sceneSourceLinks.first(where: { $0.sceneID == activeID })?.attachmentID
        }
        let projectSourceAttachmentID: UUID?
        if let activeSceneAttachmentID {
            projectSourceAttachmentID = activeSceneAttachmentID
        } else if let firstSceneAttachmentID = sceneSourceLinks.first?.attachmentID {
            // The active scene may intentionally be blank. Keep a valid
            // project-level fallback without pretending that blank scene owns
            // the footage.
            projectSourceAttachmentID = firstSceneAttachmentID
        } else if !project.sourcePath.isEmpty,
                  fileManager.fileExists(atPath: project.sourceURL.path) {
            projectSourceAttachmentID = try stageAttachment(
                from: project.sourceURL,
                role: .source,
                originalFilename: project.sourceFileName
            )
        } else {
            projectSourceAttachmentID = nil
        }

        guard projectSourceAttachmentID != nil else {
            throw ReelClipProjectCodecError.missingSceneSource(
                project.activeScene?.name ?? "The active scene"
            )
        }

        var storedClipLinks: [ReelClipStoredClipLink] = []
        for clip in project.exportedClips {
            let clipURL = URL(fileURLWithPath: clip.path)
            guard clipURL.isFileURL,
                  clipURL.path.hasPrefix("/"),
                  fileManager.fileExists(atPath: clipURL.path) else {
                throw ReelClipProjectCodecError.missingRenderedClip(
                    clip.title.isEmpty ? "Clip \(clip.index)" : clip.title
                )
            }
            let attachmentID = try stageAttachment(
                from: clipURL,
                role: .renderedClip,
                originalFilename: clipURL.lastPathComponent
            )
            storedClipLinks.append(
                ReelClipStoredClipLink(clipID: clip.id, attachmentID: attachmentID)
            )
        }

        guard attachments.count <= maximumAttachmentCount else {
            throw ReelClipProjectCodecError.invalidPackage("too many media attachments")
        }

        // Absolute sandbox paths are never written to the portable manifest.
        var portableProject = project
        portableProject.sourcePath = ""
        portableProject.sourcePhotoLibraryIdentifier = nil
        portableProject.scenes = portableProject.scenes.map { scene in
            var portableScene = scene
            portableScene.sourcePath = nil
            portableScene.sourcePhotoLibraryIdentifier = nil
            return portableScene
        }
        portableProject.exportedClips = portableProject.exportedClips.map { clip in
            var portableClip = clip
            portableClip.photoLibraryLocalIdentifier = nil
            return portableClip
        }

        let projectSourceSize = projectSourceAttachmentID.flatMap { id in
            attachments.first(where: { $0.id == id })?.byteCount
        }
        let payload = ReelClipProjectFile(
            project: portableProject,
            sourcePhotoLibraryIdentifier: nil,
            sourceOriginalFilename: project.activeScene?.sourceOriginalFilename ?? project.sourceFileName,
            sourceFileSize: projectSourceSize
        )
        let media = ReelClipProjectMediaManifest(
            attachments: attachments,
            projectSourceAttachmentID: projectSourceAttachmentID,
            sceneSourceLinks: sceneSourceLinks,
            storedClipLinks: storedClipLinks
        )
        let envelope = ReelClipProjectEnvelope(
            payload: payload,
            appVersion: appVersion,
            media: media
        )
        let manifestData = try encodeEnvelope(envelope)
        guard manifestData.count <= maximumManifestBytes else {
            throw ReelClipProjectCodecError.manifestTooLarge
        }
        try manifestData.write(
            to: stagingURL.appendingPathComponent(manifestFilename),
            options: [.atomic]
        )

        if fileManager.fileExists(atPath: packageURL.path) {
            try fileManager.removeItem(at: packageURL)
        }
        try fileManager.moveItem(at: stagingURL, to: packageURL)
        completed = true
        return packageURL
    }

    /// Flat encoding remains available for tests and migration tooling. App UI
    /// exports use `writePortablePackage` so handoffs carry their media.
    static func encode(
        _ project: MediaProject,
        sourceAsset: PHAsset? = nil,
        sourceFileSize: Int64? = nil,
        appVersion: String
    ) throws -> Data {
        let photoID = sourceAsset?.localIdentifier ?? project.sourcePhotoLibraryIdentifier
        let originalFilename = sourceAsset.flatMap(originalFilename(for:)) ?? project.sourceFileName
        let payload = ReelClipProjectFile(
            project: project,
            sourcePhotoLibraryIdentifier: photoID,
            sourceOriginalFilename: originalFilename,
            sourceFileSize: sourceFileSize
        )
        return try encodeEnvelope(
            ReelClipProjectEnvelope(payload: payload, appVersion: appVersion)
        )
    }

    // MARK: - Import

    static func decode(
        contentsOf url: URL,
        workspace: MediaWorkspace = MediaWorkspace()
    ) async throws -> ReelClipImportResult {
        try await MediaImportPreparation.ensureFileIsLocal(url) { _ in }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            return try decodePackage(at: url, workspace: workspace)
        }
        return try await decode(try Data(contentsOf: url), workspace: workspace)
    }

    /// Decodes legacy v1/v2 flat JSON and reference-only v3 data.
    static func decode(
        _ data: Data,
        workspace: MediaWorkspace = MediaWorkspace()
    ) async throws -> ReelClipImportResult {
        let envelope = try decodeEnvelope(data)
        guard envelope.media == nil else {
            throw ReelClipProjectCodecError.invalidPackage(
                "portable project media is missing; import the complete .reelclip package"
            )
        }
        return try await decodeLegacyEnvelope(envelope, workspace: workspace)
    }

    private static func decodePackage(
        at packageURL: URL,
        workspace: MediaWorkspace
    ) throws -> ReelClipImportResult {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ReelClipProjectCodecError.missingManifest
        }
        let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let envelope = try decodeEnvelope(manifestData)
        guard envelope.schemaVersion >= 3, let media = envelope.media else {
            throw ReelClipProjectCodecError.invalidPackage("portable media index is missing")
        }
        guard media.attachments.count <= maximumAttachmentCount else {
            throw ReelClipProjectCodecError.invalidPackage("too many media attachments")
        }

        let attachmentPairs = media.attachments.map { ($0.id, $0) }
        let attachmentsByID = Dictionary(attachmentPairs, uniquingKeysWith: { first, _ in first })
        guard attachmentsByID.count == media.attachments.count else {
            throw ReelClipProjectCodecError.invalidPackage("duplicate attachment identifiers")
        }

        let referencedIDs = Set(
            media.sceneSourceLinks.map(\.attachmentID)
                + media.storedClipLinks.map(\.attachmentID)
                + [media.projectSourceAttachmentID].compactMap { $0 }
        )
        guard referencedIDs.allSatisfy({ attachmentsByID[$0] != nil }) else {
            throw ReelClipProjectCodecError.invalidPackage("a media reference has no attachment")
        }

        let payloadSceneIDs = Set((envelope.payload.scenes ?? []).map(\.id))
        let sceneLinkIDs = media.sceneSourceLinks.map(\.sceneID)
        guard Set(sceneLinkIDs).count == sceneLinkIDs.count else {
            throw ReelClipProjectCodecError.invalidPackage("a scene has multiple source links")
        }
        guard media.sceneSourceLinks.allSatisfy({ link in
            payloadSceneIDs.contains(link.sceneID)
                && attachmentsByID[link.attachmentID]?.role == .source
        }) else {
            throw ReelClipProjectCodecError.invalidPackage("a scene source link is invalid")
        }
        let scenesRequiringMedia = (envelope.payload.scenes ?? []).filter { scene in
            scene.durationSeconds != nil
                || scene.sourceFileName != nil
                || scene.sourcePhotoLibraryIdentifier != nil
        }
        let linkedSceneIDSet = Set(sceneLinkIDs)
        if let missingScene = scenesRequiringMedia.first(where: { !linkedSceneIDSet.contains($0.id) }) {
            throw ReelClipProjectCodecError.invalidPackage("\(missingScene.name) has no embedded source")
        }

        let payloadClipIDs = Set(envelope.payload.exportedClips.map(\.id))
        let clipLinkIDs = media.storedClipLinks.map(\.clipID)
        guard Set(clipLinkIDs).count == clipLinkIDs.count else {
            throw ReelClipProjectCodecError.invalidPackage("a rendered clip has multiple media links")
        }
        guard media.storedClipLinks.allSatisfy({ link in
            payloadClipIDs.contains(link.clipID)
                && attachmentsByID[link.attachmentID]?.role == .renderedClip
        }) else {
            throw ReelClipProjectCodecError.invalidPackage("a rendered clip link is invalid")
        }
        let linkedClipIDSet = Set(clipLinkIDs)
        if let missingClip = envelope.payload.exportedClips.first(where: { !linkedClipIDSet.contains($0.id) }) {
            throw ReelClipProjectCodecError.invalidPackage(
                "rendered clip \(missingClip.index) has no embedded media"
            )
        }
        if let projectSourceAttachmentID = media.projectSourceAttachmentID,
           attachmentsByID[projectSourceAttachmentID]?.role != .source {
            throw ReelClipProjectCodecError.invalidPackage("the project source points to rendered media")
        }

        let referencedAttachments = media.attachments.filter { referencedIDs.contains($0.id) }
        var packagedURLsByAttachmentID: [UUID: URL] = [:]
        for attachment in referencedAttachments {
            packagedURLsByAttachmentID[attachment.id] = try validatedAttachmentURL(
                attachment,
                in: packageURL,
                fileManager: workspace.fileManager
            )
        }

        let packagedSourceURLs = referencedAttachments.compactMap { attachment -> URL? in
            guard attachment.role == .source else { return nil }
            return packagedURLsByAttachmentID[attachment.id]
        }
        let sourceImportBytes = try workspace.additionalBytesRequiredForSourceImports(packagedSourceURLs)
        let renderedImportBytes = referencedAttachments
            .filter { $0.role == .renderedClip }
            .reduce(Int64(0)) { partial, attachment in
                let (sum, overflow) = partial.addingReportingOverflow(max(attachment.byteCount, 0))
                return overflow ? Int64.max : sum
            }
        let (totalImportBytes, totalOverflow) = sourceImportBytes.addingReportingOverflow(renderedImportBytes)
        try workspace.validateAvailableCapacity(
            additionalBytes: totalOverflow ? Int64.max : totalImportBytes
        )

        var importedURLsByAttachmentID: [UUID: URL] = [:]
        var createdSourceURLs: [URL] = []
        var renderedImportDirectory: URL?
        do {
            for attachment in referencedAttachments {
                guard let packagedURL = packagedURLsByAttachmentID[attachment.id] else {
                    throw ReelClipProjectCodecError.invalidPackage("an attachment could not be opened")
                }
                switch attachment.role {
                case .source:
                    let imported = try workspace.importSourceCopyResult(from: packagedURL)
                    importedURLsByAttachmentID[attachment.id] = imported.url
                    if imported.wasCreated {
                        createdSourceURLs.append(imported.url)
                    }
                case .renderedClip:
                    let outputDirectory: URL
                    if let renderedImportDirectory {
                        outputDirectory = renderedImportDirectory
                    } else {
                        outputDirectory = try workspace.makeExportDirectory()
                        renderedImportDirectory = outputDirectory
                    }
                    importedURLsByAttachmentID[attachment.id] = try workspace.importPortableRenderedClip(
                        from: packagedURL,
                        into: outputDirectory
                    )
                }
            }
        } catch {
            for createdSourceURL in createdSourceURLs {
                workspace.removeImportedSource(at: createdSourceURL)
            }
            if let renderedImportDirectory {
                try? workspace.fileManager.removeItem(at: renderedImportDirectory)
            }
            throw error
        }

        var payload = envelope.payload
        var scenes = payload.scenes ?? []
        var linkedSceneIDs = Set<UUID>()
        for link in media.sceneSourceLinks {
            guard linkedSceneIDs.insert(link.sceneID).inserted else {
                throw ReelClipProjectCodecError.invalidPackage("a scene has multiple source links")
            }
            guard let attachment = attachmentsByID[link.attachmentID],
                  attachment.role == .source,
                  let importedURL = importedURLsByAttachmentID[link.attachmentID],
                  let sceneIndex = scenes.firstIndex(where: { $0.id == link.sceneID }) else {
                throw ReelClipProjectCodecError.invalidPackage("a scene source link is invalid")
            }
            scenes[sceneIndex].sourcePath = importedURL.path
            scenes[sceneIndex].sourceFileName = importedURL.lastPathComponent
            scenes[sceneIndex].sourceOriginalFilename = attachment.originalFilename
        }

        let unlinkedSourceScene = scenes.first { scene in
            let hasPortableSourceMetadata = scene.durationSeconds != nil
                || scene.sourceFileName != nil
                || scene.sourcePhotoLibraryIdentifier != nil
            return hasPortableSourceMetadata && !linkedSceneIDs.contains(scene.id)
        }
        if let unlinkedSourceScene {
            throw ReelClipProjectCodecError.invalidPackage(
                "\(unlinkedSourceScene.name) has no embedded source"
            )
        }
        payload.scenes = scenes

        var linkedClipIDs = Set<UUID>()
        var exportedClips = payload.exportedClips
        for link in media.storedClipLinks {
            guard linkedClipIDs.insert(link.clipID).inserted else {
                throw ReelClipProjectCodecError.invalidPackage("a rendered clip has multiple media links")
            }
            guard let attachment = attachmentsByID[link.attachmentID],
                  attachment.role == .renderedClip,
                  let importedURL = importedURLsByAttachmentID[link.attachmentID],
                  let clipIndex = exportedClips.firstIndex(where: { $0.id == link.clipID }) else {
                throw ReelClipProjectCodecError.invalidPackage("a rendered clip link is invalid")
            }
            exportedClips[clipIndex].originalPath = importedURL.path
        }
        if let unlinkedClip = exportedClips.first(where: { !linkedClipIDs.contains($0.id) }) {
            throw ReelClipProjectCodecError.invalidPackage(
                "rendered clip \(unlinkedClip.index) has no embedded media"
            )
        }
        payload.exportedClips = exportedClips

        if let projectSourceAttachmentID = media.projectSourceAttachmentID,
           attachmentsByID[projectSourceAttachmentID]?.role != .source {
            throw ReelClipProjectCodecError.invalidPackage("the project source points to rendered media")
        }

        let projectSourceURL: URL? = media.projectSourceAttachmentID.flatMap { attachmentID in
            guard attachmentsByID[attachmentID]?.role == .source else { return nil }
            return importedURLsByAttachmentID[attachmentID]
        } ?? payload.activeSceneId.flatMap { activeID in
            scenes.first(where: { $0.id == activeID })?.sourceURL
        } ?? scenes.compactMap(\.sourceURL).first

        guard let projectSourceURL else {
            throw ReelClipProjectCodecError.invalidPackage("the active source is missing")
        }
        let project = payload.toMediaProject(
            sourcePath: projectSourceURL.path,
            sourceFileName: projectSourceURL.lastPathComponent
        )
        let importedSourceCount = Set(
            referencedAttachments
                .filter { $0.role == .source }
                .map(\.id)
        ).count
        return ReelClipImportResult(
            project: project,
            sourceResolution: .resolvedViaPackage(importedSourceCount: importedSourceCount)
        )
    }

    // MARK: - Legacy source resolution

    private static func decodeLegacyEnvelope(
        _ envelope: ReelClipProjectEnvelope,
        workspace: MediaWorkspace
    ) async throws -> ReelClipImportResult {
        var payload = envelope.payload
        var scenes = payload.scenes ?? []
        var sceneResolutions: [UUID: ReelClipImportResult.SourceResolution] = [:]

        for index in scenes.indices {
            let scene = scenes[index]
            let hasReference = scene.sourcePhotoLibraryIdentifier != nil
                || scene.sourceOriginalFilename != nil
                || scene.sourceFileName != nil
            guard hasReference else {
                scenes[index].sourcePath = nil
                continue
            }
            let resolution = await resolveSource(
                photoIdentifier: scene.sourcePhotoLibraryIdentifier,
                originalFilename: scene.sourceOriginalFilename ?? scene.sourceFileName,
                expectedFileSize: nil,
                workspace: workspace
            )
            sceneResolutions[scene.id] = resolution
            if let importedURL = resolution.importedURL {
                scenes[index].sourcePath = importedURL.path
                scenes[index].sourceFileName = importedURL.lastPathComponent
            } else {
                // Never trust or retain the sender's absolute sandbox path.
                scenes[index].sourcePath = nil
            }
        }

        var primaryResolution: ReelClipImportResult.SourceResolution = .missing
        if let activeSceneID = payload.activeSceneId,
           let activeResolution = sceneResolutions[activeSceneID] {
            primaryResolution = activeResolution
        }

        if primaryResolution.importedURL == nil {
            primaryResolution = await resolveSource(
                photoIdentifier: payload.sourcePhotoLibraryIdentifier,
                originalFilename: payload.sourceOriginalFilename,
                expectedFileSize: payload.sourceFileSize,
                workspace: workspace
            )
        }

        if let primaryURL = primaryResolution.importedURL {
            for index in scenes.indices where scenes[index].sourcePath == nil && !scenes[index].hasSource {
                // V1 scenes had no per-scene references and shared the single
                // project source. Preserve that migration behavior.
                scenes[index].sourcePath = primaryURL.path
                scenes[index].sourceFileName = primaryURL.lastPathComponent
            }
        }
        payload.scenes = scenes

        let activeSceneURL = payload.activeSceneId.flatMap { activeID in
            scenes.first(where: { $0.id == activeID })?.sourceURL
        }
        let sourceURL = activeSceneURL
            ?? scenes.compactMap(\.sourceURL).first
            ?? primaryResolution.importedURL
        let sourcePath = sourceURL?.path ?? ""
        let sourceFileName = sourceURL?.lastPathComponent ?? payload.sourceOriginalFilename ?? ""
        let project = payload.toMediaProject(
            sourcePath: sourcePath,
            sourceFileName: sourceFileName
        )
        return ReelClipImportResult(
            project: project,
            sourceResolution: sourceURL == nil ? .missing : primaryResolution
        )
    }

    private static func resolveSource(
        photoIdentifier: String?,
        originalFilename: String?,
        expectedFileSize: Int64?,
        workspace: MediaWorkspace
    ) async -> ReelClipImportResult.SourceResolution {
        if let photoIdentifier,
           let asset = fetchAsset(localIdentifier: photoIdentifier),
           let url = try? await copyAssetToImports(asset: asset, workspace: workspace) {
            return .resolvedViaPhotos(importedURL: url, asset: asset)
        }

        if let originalFilename {
            let assets = fetchAssetsByFilename(originalFilename)
            let match = assets.first(where: { asset in
                guard let expectedFileSize else { return true }
                return matchesAssetSize(asset: asset, expected: expectedFileSize)
            }) ?? assets.first
            if let match,
               let url = try? await copyAssetToImports(asset: match, workspace: workspace) {
                return .resolvedViaFilename(importedURL: url, asset: match)
            }
        }
        return .missing
    }

    private static func fetchAsset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    private static func fetchAssetsByFilename(_ filename: String) -> [PHAsset] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetchResult = PHAsset.fetchAssets(with: .video, options: fetchOptions)
        var matches: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            if PHAssetResource.assetResources(for: asset).contains(where: { $0.originalFilename == filename }) {
                matches.append(asset)
            }
        }
        return matches
    }

    private static func matchesAssetSize(asset: PHAsset, expected: Int64) -> Bool {
        let width = asset.pixelWidth
        let height = asset.pixelHeight
        let duration = asset.duration.rounded(.up)
        guard width > 0, height > 0, duration > 0 else { return false }
        let estimated = Int64(width) * Int64(height) * Int64(duration) * 15
        return abs(estimated - expected) <= expected / 2
    }

    private static func copyAssetToImports(
        asset: PHAsset,
        workspace: MediaWorkspace
    ) async throws -> URL {
        try workspace.prepareBaseDirectories()
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo })
                ?? resources.first else {
            throw ReelClipProjectCodecError.invalidPackage("the Photos asset has no video resource")
        }
        let filename = resource.originalFilename.isEmpty
            ? "imported-\(asset.localIdentifier.prefix(8)).mov"
            : resource.originalFilename
        let destinationURL = FilenameSanitizer.uniqueURL(
            for: filename,
            in: workspace.importsDirectory
        )
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(
                    for: resource,
                    toFile: destinationURL,
                    options: options
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            try? workspace.fileManager.removeItem(at: destinationURL)
            throw error
        }
        return destinationURL
    }

    // MARK: - Manifest validation

    private static func encodeEnvelope(_ envelope: ReelClipProjectEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    private static func decodeEnvelope(_ data: Data) throws -> ReelClipProjectEnvelope {
        guard data.count <= maximumManifestBytes else {
            throw ReelClipProjectCodecError.manifestTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: ReelClipProjectEnvelope
        do {
            envelope = try decoder.decode(ReelClipProjectEnvelope.self, from: data)
        } catch {
            throw ReelClipProjectCodecError.unreadableProject
        }
        guard (1...ReelClipProjectEnvelope.currentSchemaVersion).contains(envelope.schemaVersion) else {
            throw ReelClipProjectCodecError.unsupportedSchema
        }
        if envelope.schemaVersion >= 3,
           envelope.formatIdentifier != ReelClipProjectEnvelope.expectedFormatIdentifier {
            throw ReelClipProjectCodecError.unreadableProject
        }
        return envelope
    }

    private static func validatedAttachmentURL(
        _ attachment: ReelClipMediaAttachment,
        in packageURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let relativePath = attachment.relativePath
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ReelClipProjectCodecError.invalidPackage("an attachment path is invalid")
        }

        let candidateURL = components.reduce(packageURL) { partial, component in
            partial.appendingPathComponent(String(component))
        }
        var traversedURL = packageURL
        for component in components {
            traversedURL.appendPathComponent(String(component))
            let values = try traversedURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ReelClipProjectCodecError.invalidPackage("an attachment path contains a symbolic link")
            }
        }
        let packageRoot = packageURL.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedCandidate = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedCandidate.path.hasPrefix(packageRoot + "/") else {
            throw ReelClipProjectCodecError.invalidPackage("an attachment points outside the project")
        }

        let values = try resolvedCandidate.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ReelClipProjectCodecError.invalidPackage("an attachment is not a regular file")
        }
        let actualByteCount = Int64(values.fileSize ?? 0)
        guard attachment.byteCount > 0, actualByteCount == attachment.byteCount else {
            throw ReelClipProjectCodecError.invalidPackage(
                "\(attachment.originalFilename) did not transfer completely"
            )
        }
        guard fileManager.fileExists(atPath: resolvedCandidate.path) else {
            throw ReelClipProjectCodecError.invalidPackage(
                "\(attachment.originalFilename) is missing"
            )
        }
        return resolvedCandidate
    }

    private static func originalFilename(for asset: PHAsset) -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo })?.originalFilename
            ?? resources.first?.originalFilename
    }
}

private extension ReelClipImportResult.SourceResolution {
    var importedURL: URL? {
        switch self {
        case .resolvedViaPackage:
            return nil
        case .resolvedViaPhotos(let importedURL, _),
             .resolvedViaFilename(let importedURL, _):
            return importedURL
        case .missing:
            return nil
        }
    }
}
