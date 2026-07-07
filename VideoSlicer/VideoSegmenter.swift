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

    /// Display title for this clip. Falls back to "Clip N" when the stored
    /// title is empty so the UI never shows a blank row.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Clip \(index + 1)" : trimmed
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
        tier: SubscriptionStore.Tier = .free
    ) async throws -> [SegmentOutput] {
        let duration = try await duration(for: sourceURL)
        let validRanges = Self.normalizedRanges(ranges, totalDuration: duration)

        guard !validRanges.isEmpty else {
            throw VideoSegmenterError.invalidDuration
        }

        let asset = AVURLAsset(url: sourceURL)
        let outputDirectory = try makeOutputDirectory()
        var outputs: [SegmentOutput] = []

        for (index, range) in validRanges.enumerated() {
            try Task.checkCancellation()

            // If the caller passed a title for this index, use it; otherwise
            // let SegmentOutput fall back to "Clip N" via displayTitle. We pass
            // nil here (not the fallback) so an empty user-cleared title
            // survives the round-trip — the fallback is purely a render concern.
            let rawTitle = clipTitles.flatMap { $0.indices.contains(index) ? $0[index] : nil }

            let outputURL = try await exportSegment(
                asset: asset,
                startSeconds: range.startSeconds,
                endSeconds: range.endSeconds,
                outputDirectory: outputDirectory,
                index: index,
                clipTitle: rawTitle,
                tier: tier
            )

            outputs.append(
                SegmentOutput(
                    index: index,
                    title: rawTitle,
                    url: outputURL,
                    startSeconds: range.startSeconds,
                    endSeconds: range.endSeconds
                )
            )

            await progress(Double(index + 1) / Double(validRanges.count))
        }

        return outputs
    }

    static func normalizedRanges(_ ranges: [ClipRange], totalDuration: Double) -> [ClipRange] {
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }

        return ranges
            .compactMap { range -> ClipRange? in
                guard range.startSeconds.isFinite, range.endSeconds.isFinite else { return nil }

                let start = min(max(range.startSeconds, 0), totalDuration)
                let end = min(max(range.endSeconds, 0), totalDuration)

                guard end - start > 0.05 else { return nil }
                return ClipRange(startSeconds: start, endSeconds: end)
            }
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
        let total = max(clips.count, 1)

        // Indicate "queueing in PhotoKit" — this is honest: performChanges
        // commits the batch atomically and only THEN does Photos start writing
        // to disk. We split the progress band at 0.5 so the UI moves visibly
        // while the user waits for the actual write.
        await progress(0.10)

        try await PHPhotoLibrary.shared().performChanges {
            for (index, clip) in clips.enumerated() {
                if Task.isCancelled { return }

                let request = PHAssetCreationRequest.forAsset()

                // Surface the user's clip title as the asset's original filename
                // so it shows up in Photos as "Surf Reel — Clip 1.mov" instead of
                // the temp filename "clip-1.mov". We sanitize to Photos-safe
                // characters and fall back to "clip-N" if the title is empty.
                let assetOptions = PHAssetResourceCreationOptions()
                let baseName = clip.displayTitle
                let fallback = "clip-\(index + 1)"
                let fileExtension = clip.url.pathExtension.isEmpty ? "mov" : clip.url.pathExtension
                assetOptions.originalFilename = FilenameSanitizer.sanitizedFileName(
                    from: baseName == "Clip \(index + 1)" ? fallback : baseName,
                    fallbackBase: fallback,
                    fileExtension: fileExtension
                )

                request.addResource(with: .video, fileURL: clip.url, options: assetOptions)

                if let localIdentifier = request.placeholderForCreatedAsset?.localIdentifier {
                    identifierCollector.set(localIdentifier, for: clip.id)
                }
                // NOTE: do NOT call `progress(...)` from inside the
                // performChanges block. The block runs synchronously and
                // returns before any MainActor work queued via fire-and-forget
                // Tasks can actually execute, so the user would see progress
                // jump from 0 → 1 with no intermediate steps (or stay at 0 if
                // the outer task completes first). Real write progress happens
                // after performChanges returns, so we update below.
            }
        }

        try Task.checkCancellation()
        // performChanges returned cleanly — Photos has accepted the batch and
        // is now writing the actual files. Push to 0.55 to reflect the
        // committed-but-not-yet-on-disk state.
        await progress(0.55)

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
        tier: SubscriptionStore.Tier
    ) async throws -> URL {
        // Free tier gets a 720p capped export with a watermark overlay. Paid
        // tiers render at native resolution with no overlay.
        let presetName: String
        var composition: AVMutableVideoComposition?
        switch tier {
        case .free:
            presetName = AVAssetExportPreset1280x720
            // Pass the segment's start/duration so the composition's
            // instruction timeRange matches the clip boundaries. Without
            // this, the composition spans the entire asset and overrides
            // `exportSession.timeRange`, exporting the full video.
            composition = await WatermarkRenderer.composition(
                for: asset,
                start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: endSeconds - startSeconds, preferredTimescale: 600)
            )
        case .creator, .studio:
            presetName = AVAssetExportPresetHighestQuality
            composition = nil
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw VideoSegmenterError.unableToCreateExporter
        }

        let outputFileType: AVFileType = exportSession.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        let fileExtension = outputFileType == .mp4 ? "mp4" : "mov"

        // Derive the on-disk filename from the clip title (e.g. "Surf Reel —
        // Clip 1.mp4"). Falls back to "clip-N" if no title was provided.
        // uniqueURL adds " (2)", " (3)"… if the file already exists so re-
        // exports of the same project don't silently overwrite the previous run.
        let fallbackBase = "clip-\(index + 1)"
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

    var values: [UUID: String] {
        lock.lock()
        defer { lock.unlock() }
        return identifiers
    }

    func set(_ identifier: String, for clipID: UUID) {
        lock.lock()
        identifiers[clipID] = identifier
        lock.unlock()
    }
}
