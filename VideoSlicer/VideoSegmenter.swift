@preconcurrency import AVFoundation
import Foundation
import Photos

struct SegmentOutput: Identifiable, Equatable {
    let id: UUID
    let index: Int
    let url: URL
    let startSeconds: Double
    let endSeconds: Double
    let photoLibraryLocalIdentifier: String?

    init(
        id: UUID = UUID(),
        index: Int,
        url: URL,
        startSeconds: Double,
        endSeconds: Double,
        photoLibraryLocalIdentifier: String? = nil
    ) {
        self.id = id
        self.index = index
        self.url = url
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.photoLibraryLocalIdentifier = photoLibraryLocalIdentifier
    }

    var title: String {
        "Clip \(index + 1)"
    }

    var timeRangeLabel: String {
        "\(Self.formatTime(startSeconds)) - \(Self.formatTime(endSeconds))"
    }

    func withPhotoLibraryLocalIdentifier(_ identifier: String?) -> SegmentOutput {
        SegmentOutput(
            id: id,
            index: index,
            url: url,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            photoLibraryLocalIdentifier: identifier
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
        progress: @escaping @MainActor (Double) -> Void
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
        return try await segmentVideo(sourceURL: sourceURL, ranges: ranges, progress: progress)
    }

    func segmentVideo(
        sourceURL: URL,
        ranges: [ClipRange],
        progress: @escaping @MainActor (Double) -> Void
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

            let outputURL = try await exportSegment(
                asset: asset,
                startSeconds: range.startSeconds,
                endSeconds: range.endSeconds,
                outputDirectory: outputDirectory,
                index: index
            )

            outputs.append(
                SegmentOutput(
                    index: index,
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

    func saveToPhotoLibrary(_ clips: [SegmentOutput]) async throws -> [UUID: String] {
        try Task.checkCancellation()

        let status = await requestPhotoLibraryAddAccess()

        guard status == .authorized || status == .limited else {
            throw VideoSegmenterError.photoLibraryAccessDenied
        }

        let identifierCollector = PhotoLibraryIdentifierCollector()

        try await PHPhotoLibrary.shared().performChanges {
            for clip in clips {
                if Task.isCancelled { return }

                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: clip.url, options: nil)

                if let localIdentifier = request.placeholderForCreatedAsset?.localIdentifier {
                    identifierCollector.set(localIdentifier, for: clip.id)
                }
            }
        }

        try Task.checkCancellation()
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
        index: Int
    ) async throws -> URL {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoSegmenterError.unableToCreateExporter
        }

        let outputFileType: AVFileType = exportSession.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        let fileExtension = outputFileType == .mp4 ? "mp4" : "mov"
        let outputURL = outputDirectory.appendingPathComponent("clip-\(index + 1).\(fileExtension)")

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
