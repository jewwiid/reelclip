@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import UIKit

struct MediaThumbnail: Identifiable, Equatable {
    let id = UUID()
    let timeSeconds: Double
    let image: UIImage

    static func == (lhs: MediaThumbnail, rhs: MediaThumbnail) -> Bool {
        lhs.id == rhs.id && lhs.timeSeconds == rhs.timeSeconds
    }
}

enum MediaPreviewGeneratorError: LocalizedError {
    case unableToGenerateThumbnails

    var errorDescription: String? {
        switch self {
        case .unableToGenerateThumbnails:
            return "Video thumbnails could not be generated."
        }
    }
}

struct MediaPreviewGenerator {
    static func displayAspectRatio(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> Double? {
        let transformedSize = naturalSize.applying(preferredTransform)
        let width = Double(abs(transformedSize.width))
        let height = Double(abs(transformedSize.height))

        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return width / height
    }

    func thumbnails(
        for sourceURL: URL,
        durationSeconds: Double,
        targetCount: Int = 10,
        maximumSize: CGSize = CGSize(width: 240, height: 240)
    ) async throws -> [MediaThumbnail] {
        guard durationSeconds.isFinite, durationSeconds > 0, targetCount > 0 else {
            return []
        }

        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        let times = Self.sampleTimes(durationSeconds: durationSeconds, targetCount: targetCount)
        var thumbnails: [MediaThumbnail] = []

        for time in times {
            try Task.checkCancellation()

            let cmTime = CMTime(seconds: time, preferredTimescale: 600)

            do {
                let image = try generator.copyCGImage(at: cmTime, actualTime: nil)
                thumbnails.append(MediaThumbnail(timeSeconds: time, image: UIImage(cgImage: image)))
            } catch {
                continue
            }
        }

        guard !thumbnails.isEmpty else {
            throw MediaPreviewGeneratorError.unableToGenerateThumbnails
        }

        return thumbnails
    }

    static func sampleTimes(durationSeconds: Double, targetCount: Int) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 0, targetCount > 0 else { return [] }

        if targetCount == 1 {
            return [min(durationSeconds / 2, max(durationSeconds - 0.05, 0))]
        }

        let lastUsableTime = max(durationSeconds - 0.05, 0)
        let step = durationSeconds / Double(targetCount)

        return (0..<targetCount).map { index in
            min((Double(index) * step) + (step / 2), lastUsableTime)
        }
    }
}
