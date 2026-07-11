@preconcurrency import AVFoundation
import Foundation

enum MediaProxyError: LocalizedError {
    case missingVideoTrack
    case unsupportedExport
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "The source has no playable video track."
        case .unsupportedExport:
            return "This video cannot be converted into a ReelClip preview proxy."
        case .exportFailed(let message):
            return "Proxy generation failed: \(message)"
        }
    }
}

/// Generates a disposable 720p H.264 preview while keeping the original source
/// untouched. Callers must never pass the returned URL into export/planning
/// APIs; source-time ranges remain authoritative against the original URL.
struct MediaProxyGenerator: @unchecked Sendable {
    private static let minimumSourceBytes: Int64 = 256 * 1024 * 1024
    private static let maximumProxyDimension = 1280.0

    let workspace: MediaWorkspace

    func shouldGenerateProxy(for sourceURL: URL) async throws -> Bool {
        if workspace.fileSize(at: sourceURL) >= Self.minimumSourceBytes {
            return true
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaProxyError.missingVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let orientedSize = naturalSize.applying(transform)
        return max(abs(orientedSize.width), abs(orientedSize.height)) > Self.maximumProxyDimension
    }

    func generateProxy(
        for sourceURL: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        if let cached = workspace.cachedProxyURL(for: sourceURL) {
            await progress(1)
            return cached
        }

        try Task.checkCancellation()
        let sourceBytes = workspace.fileSize(at: sourceURL)
        let estimatedProxyBytes = max(
            min(Int64(Double(sourceBytes) * 0.25), sourceBytes),
            128 * 1024 * 1024
        )
        try workspace.validateAvailableCapacity(additionalBytes: estimatedProxyBytes)

        let finalURL = try workspace.proxyURL(for: sourceURL)
        let temporaryURL = workspace.proxiesDirectory
            .appendingPathComponent("\(UUID().uuidString).proxy-building.mp4")
        try? workspace.fileManager.removeItem(at: temporaryURL)

        let asset = AVURLAsset(url: sourceURL)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw MediaProxyError.missingVideoTrack
        }
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset1280x720
        ), session.supportedFileTypes.contains(.mp4) else {
            throw MediaProxyError.unsupportedExport
        }

        session.outputURL = temporaryURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.canPerformMultiplePassesOverSourceMediaData = false

        let sessionBox = MediaProxyExportSessionBox(session)
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let progressTask = Task {
                        while !Task.isCancelled {
                            await progress(Double(sessionBox.session.progress))
                            let status = sessionBox.session.status
                            if status == .completed || status == .failed || status == .cancelled {
                                return
                            }
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }

                    sessionBox.session.exportAsynchronously {
                        progressTask.cancel()
                        switch sessionBox.session.status {
                        case .completed:
                            do {
                                if workspace.fileManager.fileExists(atPath: finalURL.path) {
                                    try workspace.fileManager.removeItem(at: temporaryURL)
                                } else {
                                    try workspace.fileManager.moveItem(at: temporaryURL, to: finalURL)
                                }
                                continuation.resume(returning: finalURL)
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        case .cancelled:
                            continuation.resume(throwing: CancellationError())
                        case .failed:
                            continuation.resume(throwing: MediaProxyError.exportFailed(
                                sessionBox.session.error?.localizedDescription ?? "Unknown encoder error"
                            ))
                        default:
                            continuation.resume(throwing: MediaProxyError.exportFailed(
                                "Unexpected export state \(sessionBox.session.status.rawValue)"
                            ))
                        }
                    }
                }
            } onCancel: {
                sessionBox.session.cancelExport()
            }

            await progress(1)
            return result
        } catch {
            try? workspace.fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

private final class MediaProxyExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
