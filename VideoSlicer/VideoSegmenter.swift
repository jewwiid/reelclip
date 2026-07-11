@preconcurrency import AVFoundation
import Foundation
import Photos

struct SegmentOutput: Identifiable, Equatable {
    let id: UUID
    let index: Int
    var title: String
    let url: URL
    let startSeconds: Double
    let endSeconds: Double
    let photoLibraryLocalIdentifier: String?

    init(
        id: UUID = UUID(),
        index: Int,
        title: String? = nil,
        url: URL,
        startSeconds: Double,
        endSeconds: Double,
        photoLibraryLocalIdentifier: String? = nil
    ) {
        self.id = id
        self.index = index
        // Persist whatever the caller passed in (including the empty string) so
        // a user-cleared title survives a project save/load round-trip — the
        // UI then renders the computed fallback for empty/missing titles.
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.url = url
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.photoLibraryLocalIdentifier = photoLibraryLocalIdentifier
    }

    /// Display title for this clip. Falls back to "Clip 01" when the stored
    /// title is empty so the UI never shows a blank row.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultTitle(for: index) : trimmed
    }

    static func defaultTitle(for index: Int, totalCount: Int? = nil) -> String {
        "Clip \(paddedClipNumber(for: index, totalCount: totalCount))"
    }

    static func defaultFileBase(for index: Int, totalCount: Int? = nil) -> String {
        "clip-\(paddedClipNumber(for: index, totalCount: totalCount))"
    }

    private static func paddedClipNumber(for index: Int, totalCount: Int? = nil) -> String {
        let displayIndex = max(0, index) + 1
        let largestIndex = max(displayIndex, totalCount ?? displayIndex)
        let width = max(2, String(largestIndex).count)
        return String(format: "%0*d", width, displayIndex)
    }

    var timeRangeLabel: String {
        "\(Self.formatTime(startSeconds)) - \(Self.formatTime(endSeconds))"
    }

    func withPhotoLibraryLocalIdentifier(_ identifier: String?) -> SegmentOutput {
        SegmentOutput(
            id: id,
            index: index,
            title: title,
            url: url,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            photoLibraryLocalIdentifier: identifier
        )
    }

    func withTitle(_ newTitle: String) -> SegmentOutput {
        SegmentOutput(
            id: id,
            index: index,
            title: newTitle,
            url: url,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            photoLibraryLocalIdentifier: photoLibraryLocalIdentifier
        )
    }

    private static func formatTime(_ seconds: Double) -> String {
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

enum VideoSegmenterError: LocalizedError {
    case invalidDuration
    case invalidSegmentLength
    case unableToCreateExporter
    case exportFailed(String)
    case photoLibraryAccessDenied
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            return "The selected video duration could not be read."
        case .invalidSegmentLength:
            return "Segment length must be at least 1 second."
        case .unableToCreateExporter:
            return "The video could not be prepared for export."
        case .exportFailed(let message):
            return message
        case .photoLibraryAccessDenied:
            return "Photo library access is needed to save the generated clips."
        case .cancelled:
            return "Processing was cancelled."
        }
    }
}

struct VideoSegmenter {
    private let workspace: MediaWorkspace
    private let fileManager: FileManager

    init(workspace: MediaWorkspace = MediaWorkspace()) {
        self.workspace = workspace
        self.fileManager = workspace.fileManager
    }

    func duration(for sourceURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)

        guard seconds.isFinite, seconds > 0 else {
            throw VideoSegmenterError.invalidDuration
        }

        return seconds
    }

    func segmentVideo(
        sourceURL: URL,
        segmentLength: Double,
        progress: @escaping @MainActor (Double) -> Void,
        tier: SubscriptionStore.Tier = .free
    ) async throws -> [SegmentOutput] {
        guard segmentLength.isFinite, segmentLength >= 1 else {
            throw VideoSegmenterError.invalidSegmentLength
        }

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        guard totalSeconds.isFinite, totalSeconds > 0 else {
            throw VideoSegmenterError.invalidDuration
        }

        let ranges = Self.normalizedRanges(
            SmartCutAnalyzer.equalRanges(totalDuration: totalSeconds, segmentLength: segmentLength),
            totalDuration: totalSeconds
        )
        return try await segmentVideo(
            sourceURL: sourceURL,
            ranges: ranges,
            progress: progress,
            tier: tier
        )
    }

    func segmentVideo(
        sourceURL: URL,
        ranges: [ClipRange],
        clipTitles: [String]? = nil,
        progress: @escaping @MainActor (Double) -> Void,
        tier: SubscriptionStore.Tier = .free,
        settings: ExportSettings = ExportSettings(resolution: .source, frameRate: .source)
    ) async throws -> [SegmentOutput] {
        let duration = try await duration(for: sourceURL)
        let validRanges = Self.normalizedRanges(ranges, totalDuration: duration)

        guard !validRanges.isEmpty else {
            throw VideoSegmenterError.invalidDuration
        }

        let asset = AVURLAsset(url: sourceURL)
        var outputDirectory: URL?
        var didComplete = false
        defer {
            // A failed or cancelled batch may have already written several
            // clips. Remove that private batch directory so repeated exports
            // cannot slowly consume the device with orphaned files.
            if !didComplete, let outputDirectory {
                try? fileManager.removeItem(at: outputDirectory)
            }
        }

        let createdOutputDirectory = try makeOutputDirectory()
        outputDirectory = createdOutputDirectory
        var outputs: [SegmentOutput] = []

        for (index, range) in validRanges.enumerated() {
            try Task.checkCancellation()

            // If the caller passed a title for this index, use it; otherwise
            // let SegmentOutput fall back to "Clip 01" via displayTitle. We pass
            // nil here (not the fallback) so an empty user-cleared title
            // survives the round-trip — the fallback is purely a render concern.
            let rawTitle = clipTitles.flatMap { $0.indices.contains(index) ? $0[index] : nil }

            let exportedURL = try await exportSegment(
                asset: asset,
                startSeconds: range.startSeconds,
                endSeconds: range.endSeconds,
                outputDirectory: createdOutputDirectory,
                index: index,
                clipTitle: rawTitle,
                tier: tier,
                settings: settings
            )

            // Append the animated outro for Creator+ tier. Free tier keeps
            // its existing corner-pill watermark and skips the outro so
            // free users don't get a "real video editor" outro that hides
            // the watermark CTA. If the outro render fails for any reason
            // we fall back to the segment URL — losing the outro is better
            // than failing the whole export.
            let finalURL: URL
            if Self.shouldAppendOutro(forTier: tier) {
                if let outroedURL = try? await appendOutro(
                    to: exportedURL,
                    in: createdOutputDirectory,
                    index: index
                ) {
                    finalURL = outroedURL
                    // Remove the intermediate segment-without-outro file —
                    // its content is fully contained in the outroed file.
                    try? fileManager.removeItem(at: exportedURL)
                } else {
                    finalURL = exportedURL
                }
            } else {
                finalURL = exportedURL
            }

            outputs.append(
                SegmentOutput(
                    index: index,
                    title: rawTitle,
                    url: finalURL,
                    startSeconds: range.startSeconds,
                    endSeconds: range.endSeconds
                )
            )

            await progress(Double(index + 1) / Double(validRanges.count))
        }

        didComplete = true
        return outputs
    }

    /// Renders one selected source range for the pre-project trim flow. This
    /// is deliberately separate from `segmentVideo`: a source preparation is
    /// not a user-facing export and must never inherit watermark/outro policy.
    func renderSourceTrim(
        sourceURL: URL,
        range: ClipRange,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> SegmentOutput {
        let duration = try await duration(for: sourceURL)
        guard let validRange = Self.normalizedRanges([range], totalDuration: duration).first else {
            throw VideoSegmenterError.invalidDuration
        }

        let asset = AVURLAsset(url: sourceURL)
        var outputDirectory: URL?
        var didComplete = false
        defer {
            if !didComplete, let outputDirectory {
                try? fileManager.removeItem(at: outputDirectory)
            }
        }

        let createdOutputDirectory = try makeOutputDirectory()
        outputDirectory = createdOutputDirectory
        await progress(0)

        // `exportSegment` resolves the requested source-quality settings.
        // Creator is used only to keep this private intermediary clean; this
        // code path does not grant a paid export to the user.
        let exportedURL = try await exportSegment(
            asset: asset,
            startSeconds: validRange.startSeconds,
            endSeconds: validRange.endSeconds,
            outputDirectory: createdOutputDirectory,
            index: 0,
            clipTitle: nil,
            tier: .creator,
            settings: ExportSettings(resolution: .source, frameRate: .source)
        )

        didComplete = true
        await progress(1)
        return SegmentOutput(
            index: 0,
            url: exportedURL,
            startSeconds: validRange.startSeconds,
            endSeconds: validRange.endSeconds
        )
    }

    static func normalizedRanges(_ ranges: [ClipRange], totalDuration: Double) -> [ClipRange] {
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }

        return ranges
            .compactMap { range -> ClipRange? in
                guard range.startSeconds.isFinite, range.endSeconds.isFinite else { return nil }

                let start = min(max(range.startSeconds, 0), totalDuration)
                let end = min(max(range.endSeconds, 0), totalDuration)

                guard end - start > 0.05 else { return nil }
                return ClipRange(startSeconds: start, endSeconds: end, reason: range.reason)
            }
    }

    /// Concatenate a list of source ranges into a single MP4 file using
    /// `AVMutableComposition`. Used by the transcript "Process" button —
    /// the caller runs silence detection (or any other range-selection
    /// strategy) on the source, then hands the resulting non-silent
    /// ranges here. The composition plays them back-to-back with no
    /// transitions, no fade, no padding — strictly `range[i]` followed
    /// by `range[i+1]`, in order. The output is a single MP4 ready for
    /// the user to preview / save to Photos.
    ///
    /// Notes:
    /// - Uses `AVAssetExportPresetHighestQuality` so the output quality
    ///   matches the source. (Passthrough preset doesn't work on
    ///   compositions — only on direct asset exports.)
    /// - Inserts video + audio tracks separately so the original audio
    ///   survives the join. Tracks are sourced from the asset's natural
    ///   track id; if the source has no audio track the export still
    ///   succeeds as silent video.
    /// - The output filename is `tightened-<timestamp>.mp4` so it never
    ///   collides with the planned-clip segmenter output filenames.
    /// - Progress is reported as 0→1 over the export; the caller is
    ///   responsible for pre-flight progress (e.g. silence detection)
    ///   before this is invoked.
    func concatenateRangesToSingleMP4(
        sourceURL: URL,
        ranges: [ClipRange],
        progress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> URL {
        try Task.checkCancellation()
        await progress(0)

        let asset = AVURLAsset(url: sourceURL)
        let totalDuration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(totalDuration)

        let validRanges = Self.normalizedRanges(ranges, totalDuration: totalSeconds)
        guard !validRanges.isEmpty else {
            throw VideoSegmenterError.invalidDuration
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first else {
            throw VideoSegmenterError.invalidDuration
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoSegmenterError.unableToCreateExporter
        }
        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        // Carry the source's preferred transform so orientation matches.
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        compositionVideoTrack.preferredTransform = preferredTransform

        var cursor = CMTime.zero
        let timescale: CMTimeScale = 600

        for (index, range) in validRanges.enumerated() {
            try Task.checkCancellation()
            let start = CMTime(seconds: range.startSeconds, preferredTimescale: timescale)
            let end = CMTime(seconds: range.endSeconds, preferredTimescale: timescale)
            let rangeDuration = CMTimeSubtract(end, start)

            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: start, duration: rangeDuration),
                of: videoTrack,
                at: cursor
            )

            // Audio is optional — some sources may be silent. Skip the
            // insert cleanly rather than throwing so the output still
            // exports the joined video.
            if let compositionAudioTrack, let audioTrack = audioTracks.first {
                do {
                    try compositionAudioTrack.insertTimeRange(
                        CMTimeRange(start: start, duration: rangeDuration),
                        of: audioTrack,
                        at: cursor
                    )
                } catch {
                    // No-op: audio track is best-effort. Video export still works.
                    _ = compositionAudioTrack
                }
            }

            cursor = CMTimeAdd(cursor, rangeDuration)

            // 0 → 0.9 across the inserts (composition work); 0.9 → 1.0 is the export phase.
            let insertProgress = Double(index + 1) / Double(validRanges.count) * 0.9
            await progress(insertProgress)
        }

        let outputDirectory = try makeOutputDirectory()
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileName = FilenameSanitizer.sanitizedFileName(
            from: "tightened-\(timestamp)",
            fallbackBase: "tightened",
            fileExtension: "mp4"
        )
        let outputURL = FilenameSanitizer.uniqueURL(for: fileName, in: outputDirectory)

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoSegmenterError.unableToCreateExporter
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        let exportBox = ExportSessionBox(exportSession)
        let continuationBox = ExportContinuationBox()

        let finalURL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                continuationBox.set(continuation)

                exportSession.exportAsynchronously {
                    let session = exportBox.session

                    switch session.status {
                    case .completed:
                        continuation.resume(returning: outputURL)
                    case .cancelled:
                        continuation.resume(throwing: VideoSegmenterError.cancelled)
                    case .failed:
                        let message = session.error?.localizedDescription ?? "Unknown export failure"
                        continuation.resume(throwing: VideoSegmenterError.exportFailed(message))
                    default:
                        let message = "Unexpected export status: \(session.status.rawValue)"
                        continuation.resume(throwing: VideoSegmenterError.exportFailed(message))
                    }
                    continuationBox.resume(.success(outputURL))
                }
            }
        } onCancel: {
            exportBox.session.cancelExport()
        }

        await progress(1.0)
        return finalURL
    }

    func saveToPhotoLibrary(
        _ clips: [SegmentOutput],
        progress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> [UUID: String] {
        try Task.checkCancellation()

        await progress(0.05) // pre-flight (permission + directory)

        let status = await requestPhotoLibraryAddAccess()

        guard status == .authorized || status == .limited else {
            throw VideoSegmenterError.photoLibraryAccessDenied
        }

        let identifierCollector = PhotoLibraryIdentifierCollector()

        // Indicate "queueing in PhotoKit" — this is honest: performChanges
        // commits the batch atomically and only THEN does Photos start writing
        // to disk. We split the progress band at 0.5 so the UI moves visibly
        // while the user waits for the actual write.
        await progress(0.10)

        // Resolve the user's "ReelClip" album BEFORE entering the
        // performChanges block — PhotoKit's collection change requests
        // can only be created (or fetched) inside the block, but we
        // want to know up front whether the album already exists so
        // we can either reuse it or create it. The cached identifier
        // is the fast path; we re-resolve on miss in case the user
        // deleted the album from Photos between exports.
        let existingAlbum = ReelClipPhotoAlbum.resolve()

        try await PHPhotoLibrary.shared().performChanges {
            for clip in clips {
                if Task.isCancelled { return }

                let request = PHAssetCreationRequest.forAsset()

                // Surface the user's clip title as the asset's original filename
                // so it shows up in Photos as "Surf Reel - Clip 01.mov" instead of
                // the generated fallback filename. We sanitize to Photos-safe
                // characters and fall back to "clip-01" if sanitizing empties it.
                let assetOptions = PHAssetResourceCreationOptions()
                let baseName = clip.displayTitle
                let fallback = SegmentOutput.defaultFileBase(for: clip.index)
                let fileExtension = clip.url.pathExtension.isEmpty ? "mov" : clip.url.pathExtension
                assetOptions.originalFilename = FilenameSanitizer.sanitizedFileName(
                    from: baseName,
                    fallbackBase: fallback,
                    fileExtension: fileExtension
                )

                request.addResource(with: .video, fileURL: clip.url, options: assetOptions)

                if let placeholder = request.placeholderForCreatedAsset {
                    identifierCollector.set(placeholder, for: clip.id)
                }
                // NOTE: do NOT call `progress(...)` from inside the
                // performChanges block. The block runs synchronously and
                // returns before any MainActor work queued via fire-and-forget
                // Tasks can actually execute, so the user would see progress
                // jump from 0 → 1 with no intermediate steps (or stay at 0 if
                // the outer task completes first). Real write progress happens
                // after performChanges returns, so we update below.
            }

            // Now add the freshly created assets to the user's "ReelClip"
            // album. The change request is staged alongside the asset
            // creations inside the same atomic performChanges block, so
            // the album membership is consistent with the asset
            // existence — no risk of an "asset exists but not in album"
            // or "in album but not yet written" intermediate state.
            //
            // Three cases:
            //   1. Cached album id + album still exists → fetch by id
            //   2. No cache / album deleted → create a new "ReelClip" album
            //   3. Cached id but lookup failed → fall back to title match
            //      on a fresh fetch (user may have deleted + recreated
            //      the album from another device)
            let assetPlaceholders: [PHObjectPlaceholder] = identifierCollector.placeholders
            if let albumChangeRequest = ReelClipPhotoAlbum.makeChangeRequest(
                cached: existingAlbum
            ) {
                albumChangeRequest.addAssets(assetPlaceholders as NSArray)
            }
            // If makeChangeRequest returns nil, the album path silently
            // skipped — clips still land in the user's default library.
        }

        try Task.checkCancellation()
        // performChanges returned cleanly — Photos has accepted the batch and
        // is now writing the actual files. Push to 0.55 to reflect the
        // committed-but-not-yet-on-disk state.
        await progress(0.55)

        // Cache the resolved album id for next time so we don't have to
        // do the title-search again. If we just created the album, the
        // change request's placeholderForCreatedAssetCollection carries
        // the new localIdentifier; otherwise we re-resolve by id or
        // by title to pick up the (possibly-different) live identifier.
        if let resolved = ReelClipPhotoAlbum.resolve() {
            ReelClipPhotoAlbum.persist(resolved)
        }

        // For now we report success at 0.95 so the UI moves; the final 1.0
        // is set by the caller once notification + persistence complete. If
        // we ever wire up `PHPhotoLibrary.registerChangeObserver` to track
        // per-asset upload bytes, this is where the real granular updates
        // would go.
        await progress(0.95)
        return identifierCollector.values
    }

    func removeTemporaryFiles(for clips: [SegmentOutput]) {
        workspace.removeDirectories(for: clips)
    }

    private func exportSegment(
        asset: AVAsset,
        startSeconds: Double,
        endSeconds: Double,
        outputDirectory: URL,
        index: Int,
        clipTitle: String?,
        tier: SubscriptionStore.Tier,
        settings: ExportSettings
    ) async throws -> URL {
        // Resolve the project-saved settings against the user's
        // current tier. Free is silently pinned to 720p + source
        // fps; paid tiers honour the saved choice (or fall back
        // to source-quality defaults if no settings were saved).
        let resolved = settings.resolved(for: tier)
        let presetName = resolved.resolution.presetName

        // Watermark logic. The corner-pill "Made with ReelClip" overlay is
        // NOT used here — the animated Outro (appended post-export for
        // Free tier) replaces it as the watermark. Creator tier gets a
        // completely clean export.
        //
        // We still build a composition when needed so the frameDuration /
        // preset resolution override below takes effect.
        var composition: AVMutableVideoComposition?
        // Intentionally no watermark composition is set for either tier.

        // If the user picked a non-source frame rate, apply it via
        // the composition's frame duration. `source` leaves the
        // time-base untouched (composition is nil OR carries the
        // source's natural track time-base).
        if let frameDuration = resolved.frameRate.frameDuration,
           composition == nil {
            // Build a minimal composition just to set frameDuration
            // for the encoder. Source resolution is implicit because
            // the preset is HighestQuality / matches source dims.
            let minimal = AVMutableVideoComposition()
            minimal.frameDuration = frameDuration
            composition = minimal
        } else if let frameDuration = resolved.frameRate.frameDuration,
                  composition != nil {
            // Watermark composition already exists; layer the
            // frameDuration on top so the watermark track matches
            // the user's chosen fps.
            composition?.frameDuration = frameDuration
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw VideoSegmenterError.unableToCreateExporter
        }

        let outputFileType: AVFileType = exportSession.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        let fileExtension = outputFileType == .mp4 ? "mp4" : "mov"

        // Derive the on-disk filename from the clip title (e.g. "Surf Reel -
        // Clip 01.mp4"). Falls back to "clip-01" if no title was provided.
        // uniqueURL adds " (2)", " (3)"… if the file already exists so re-
        // exports of the same project don't silently overwrite the previous run.
        let fallbackBase = SegmentOutput.defaultFileBase(for: index)
        let titleForNaming: String = {
            guard let clipTitle else { return fallbackBase }
            let trimmed = clipTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallbackBase : trimmed
        }()
        let desiredFileName = FilenameSanitizer.sanitizedFileName(
            from: titleForNaming,
            fallbackBase: fallbackBase,
            fileExtension: fileExtension
        )
        let outputURL = FilenameSanitizer.uniqueURL(for: desiredFileName, in: outputDirectory)

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        let timescale: CMTimeScale = 600
        let start = CMTime(seconds: startSeconds, preferredTimescale: timescale)
        let duration = CMTime(seconds: endSeconds - startSeconds, preferredTimescale: timescale)

        try Task.checkCancellation()

        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputFileType
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.timeRange = CMTimeRange(start: start, duration: duration)
        if let composition {
            exportSession.videoComposition = composition
        }

        let exportBox = ExportSessionBox(exportSession)
        let continuationBox = ExportContinuationBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuationBox.set(continuation)

                exportSession.exportAsynchronously {
                    let session = exportBox.session

                    switch session.status {
                    case .completed:
                        if Task.isCancelled {
                            continuationBox.resume(.failure(VideoSegmenterError.cancelled))
                        } else {
                            continuationBox.resume(.success(outputURL))
                        }
                    case .failed, .cancelled:
                        let message = session.error?.localizedDescription ?? "Video export did not complete."
                        continuationBox.resume(.failure(VideoSegmenterError.exportFailed(message)))
                    default:
                        continuationBox.resume(.failure(VideoSegmenterError.exportFailed("Video export ended unexpectedly.")))
                    }
                }
            }
        } onCancel: {
            exportBox.session.cancelExport()
            continuationBox.resume(.failure(VideoSegmenterError.cancelled))
        }
    }

    private func makeOutputDirectory() throws -> URL {
        try workspace.makeExportDirectory()
    }

    private func requestPhotoLibraryAddAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Outro

    /// Whether the animated outro should be appended for a given tier.
    /// Free tier gets the outro as its watermark (it replaces the old
    /// corner-pill "Made with ReelClip" badge); Creator tier gets a
    /// completely clean export.
    static func shouldAppendOutro(forTier tier: SubscriptionStore.Tier) -> Bool {
        switch tier {
        case .free:    return true
        case .creator: return false
        }
    }

    /// Concatenate an exported segment clip with the animated outro into a
    /// single MP4 next to the original. Returns nil when the source clip
    /// has no video track or the outro render fails — callers fall back to
    /// the original URL.
    ///
    /// The function builds an `AVMutableComposition` with two video tracks
    /// (segment + outro) and a single audio track (segment only — outro is
    /// silent), then exports via `AVAssetExportSession` at the source
    /// resolution. Render size and frame duration come from the source
    /// clip's video track so the outro matches what the user picked.
    private func appendOutro(
        to segmentURL: URL,
        in outputDirectory: URL,
        index: Int
    ) async throws -> URL? {
        let segmentAsset = AVURLAsset(url: segmentURL)
        let segmentVideoTracks: [AVAssetTrack]
        do {
            segmentVideoTracks = try await segmentAsset.loadTracks(withMediaType: .video)
        } catch {
            return nil
        }
        guard let segmentVideoTrack = segmentVideoTracks.first else { return nil }

        let segmentAudioTracks: [AVAssetTrack]
        do {
            segmentAudioTracks = try await segmentAsset.loadTracks(withMediaType: .audio)
        } catch {
            return nil
        }

        let naturalSize: CGSize
        let transform: CGAffineTransform
        let frameDuration: CMTime
        do {
            naturalSize = try await segmentVideoTrack.load(.naturalSize)
            transform = try await segmentVideoTrack.load(.preferredTransform)
            let nominalFrameRate = try await segmentVideoTrack.load(.nominalFrameRate)
            // Clamp nominalFrameRate into a sane range (some encoders report
            // 0 or absurd values); fall back to 30 fps when unusable.
            let fps: Float
            if nominalFrameRate.isFinite, nominalFrameRate > 1, nominalFrameRate < 240 {
                fps = nominalFrameRate
            } else {
                fps = 30
            }
            frameDuration = CMTime(value: 1, timescale: CMTimeScale(roundf(fps)))
        } catch {
            return nil
        }

        // Use the *rendered* frame size (after preferredTransform) so the
        // outro matches the visible canvas, not the storage orientation.
        let orientedFrame = naturalSize.applying(transform)
        let renderSize = CGSize(
            width: abs(orientedFrame.width),
            height: abs(orientedFrame.height)
        )
        guard
            renderSize.width > 0, renderSize.height > 0,
            renderSize.width.isFinite, renderSize.height.isFinite
        else { return nil }

        let segmentDuration = try await segmentAsset.load(.duration)

        // Build the outro composition (3s black background + animation tool).
        // Its animation clock is offset to the end of the segment so the
        // logo can never render over the user's clip.
        guard let outroResult = await OutroRenderer.composition(
            renderSize: renderSize,
            frameDuration: frameDuration,
            overlayStartTime: segmentDuration
        ) else { return nil }

        let outroComposition = outroResult.composition
        let outroVideoComposition = outroResult.videoComposition
        guard
            let outroVideoTrack = outroComposition.tracks(withMediaType: .video).first
        else { return nil }

        // Build a fresh composition that holds segment + outro end-to-end.
        let combined = AVMutableComposition()
        guard
            let combinedSegmentTrack = combined.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ),
            let combinedOutroTrack = combined.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else { return nil }

        let timescale: CMTimeScale = 600
        let segmentStart = CMTime(value: 0, timescale: timescale)
        let outroStart = CMTimeAdd(segmentStart, segmentDuration)

        do {
            try combinedSegmentTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: segmentDuration),
                of: segmentVideoTrack,
                at: .zero
            )
            try combinedOutroTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: OutroRenderer.duration),
                of: outroVideoTrack,
                at: outroStart
            )
        } catch {
            return nil
        }

        // Audio: only the segment has audio. Outro is silent.
        if let segmentAudioTrack = segmentAudioTracks.first,
           let combinedAudioTrack = combined.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? combinedAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: segmentDuration),
                of: segmentAudioTrack,
                at: .zero
            )
        }

        // Video composition: two instructions so the segment keeps its
        // original transform and the outro gets the Core Animation overlay.
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration

        let segmentInstruction = AVMutableVideoCompositionInstruction()
        segmentInstruction.timeRange = CMTimeRange(
            start: .zero,
            duration: segmentDuration
        )
        let segmentLayerInstruction = AVMutableVideoCompositionLayerInstruction(
            assetTrack: combinedSegmentTrack
        )
        segmentLayerInstruction.setTransform(transform, at: .zero)
        segmentInstruction.layerInstructions = [segmentLayerInstruction]

        let outroInstruction = AVMutableVideoCompositionInstruction()
        outroInstruction.timeRange = CMTimeRange(
            start: outroStart,
            duration: OutroRenderer.duration
        )
        let outroLayerInstruction = AVMutableVideoCompositionLayerInstruction(
            assetTrack: combinedOutroTrack
        )
        outroInstruction.layerInstructions = [outroLayerInstruction]

        videoComposition.instructions = [segmentInstruction, outroInstruction]
        // Carry the outro's animation tool across — that's where the
        // Core Animation overlay lives.
        videoComposition.animationTool = outroVideoComposition.animationTool

        // Output file. Use the same extension as the source segment so the
        // downstream photo-save path doesn't have to special-case MP4 vs MOV.
        let sourceExtension = segmentURL.pathExtension.isEmpty ? "mov" : segmentURL.pathExtension
        let suffix = "-with-outro"
        let baseName = segmentURL.deletingPathExtension().lastPathComponent + suffix
        let desiredFileName = FilenameSanitizer.sanitizedFileName(
            from: baseName,
            fallbackBase: SegmentOutput.defaultFileBase(for: index) + suffix,
            fileExtension: sourceExtension
        )
        let outputURL = FilenameSanitizer.uniqueURL(for: desiredFileName, in: outputDirectory)
        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(
            asset: combined,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            return nil
        }

        let outputFileType: AVFileType = exportSession.supportedFileTypes.contains(.mp4)
            ? .mp4
            : .mov
        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputFileType
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.videoComposition = videoComposition

        let exportBox = ExportSessionBox(exportSession)
        let continuationBox = ExportContinuationBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuationBox.set(continuation)

                exportSession.exportAsynchronously {
                    let session = exportBox.session

                    switch session.status {
                    case .completed:
                        if Task.isCancelled {
                            continuationBox.resume(.failure(VideoSegmenterError.cancelled))
                        } else {
                            continuationBox.resume(.success(outputURL))
                        }
                    case .failed, .cancelled:
                        let message = session.error?.localizedDescription ?? "Video export did not complete."
                        continuationBox.resume(.failure(VideoSegmenterError.exportFailed(message)))
                    default:
                        continuationBox.resume(.failure(VideoSegmenterError.exportFailed("Video export ended unexpectedly.")))
                    }
                }
            }
        } onCancel: {
            exportBox.session.cancelExport()
            continuationBox.resume(.failure(VideoSegmenterError.cancelled))
        }
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

private final class ExportContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var didFinish = false

    func set(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(throwing: VideoSegmenterError.cancelled)
            return
        }

        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ result: Result<URL, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }

        didFinish = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

private final class PhotoLibraryIdentifierCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [UUID: String] = [:]
    /// Insertion-order list of placeholders collected during the
    /// performChanges block. The collector is intentionally @unchecked
    /// Sendable because we only mutate under `lock` and the only
    /// thread that reads `placeholders` is the performChanges block
    /// itself (single-threaded by Apple's contract). We store the
    /// placeholders themselves (not the local identifiers) so the
    /// album change request can pass them straight to `addAssets`
    /// inside the same atomic block.
    private var placeholderList: [PHObjectPlaceholder] = []

    var values: [UUID: String] {
        lock.lock()
        defer { lock.unlock() }
        return identifiers
    }

    var placeholders: [PHObjectPlaceholder] {
        lock.lock()
        defer { lock.unlock() }
        return placeholderList
    }

    func set(_ placeholder: PHObjectPlaceholder, for clipID: UUID) {
        lock.lock()
        identifiers[clipID] = placeholder.localIdentifier
        placeholderList.append(placeholder)
        lock.unlock()
    }
}
