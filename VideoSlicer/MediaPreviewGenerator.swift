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
        // Do not allow AVFoundation to satisfy a sample by stepping
        // backward to t=0. Midpoint samples avoid the common black
        // decode-only first frame while preserving the full timeline span.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        let times = Self.sampleTimes(
            durationSeconds: durationSeconds,
            targetCount: targetCount
        )

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

        return Self.replacingLeadingBlackThumbnails(thumbnails)
    }

    /// Return one midpoint sample per timeline cell. The first sample is
    /// deliberately after t=0 so AVAssetImageGenerator does not hand the UI
    /// a decode-only black opening frame. The filmstrip still maps that image
    /// back to the first cell, so no leading time is lost.
    static func sampleTimes(durationSeconds: Double, targetCount: Int) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }
        guard targetCount > 0 else { return [] }

        if targetCount == 1 {
            return [min(durationSeconds / 2, max(durationSeconds - 0.05, 0))]
        }

        let lastUsableTime = max(durationSeconds - 0.05, 0)
        let step = durationSeconds / Double(targetCount)
        return (0..<targetCount).map { index in
            min((Double(index) * step) + (step / 2), lastUsableTime)
        }
    }

    private static func replacingLeadingBlackThumbnails(_ thumbnails: [MediaThumbnail]) -> [MediaThumbnail] {
        guard let firstVisible = thumbnails.first(where: { thumbnail in
            guard let image = thumbnail.image.cgImage else { return true }
            return !isNearlyBlack(image)
        }) else {
            return thumbnails
        }

        var reachedVisibleFrame = false
        return thumbnails.map { thumbnail in
            guard !reachedVisibleFrame,
                  let image = thumbnail.image.cgImage,
                  isNearlyBlack(image)
            else {
                reachedVisibleFrame = true
                return thumbnail
            }

            return MediaThumbnail(
                timeSeconds: thumbnail.timeSeconds,
                image: firstVisible.image
            )
        }
    }

    private static func isNearlyBlack(_ image: CGImage) -> Bool {
        let sampleWidth = 8
        let sampleHeight = 8
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        // Inspect the centre crop instead of the entire transformed image.
        // Vertical videos often have black side bars; including those bars
        // makes a real opening frame look black and causes the timeline to
        // replace it with the wrong leading sample.
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let cropWidth = max(imageWidth * 0.60, 1)
        let cropHeight = max(imageHeight * 0.80, 1)
        let cropRect = CGRect(
            x: max((imageWidth - cropWidth) / 2, 0),
            y: max((imageHeight - cropHeight) / 2, 0),
            width: min(cropWidth, imageWidth),
            height: min(cropHeight, imageHeight)
        )
        let sampledImage = image.cropping(to: cropRect) ?? image

        context.interpolationQuality = .low
        context.draw(sampledImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var totalLuma = 0.0
        var brightPixelCount = 0

        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let red = Double(pixels[index]) / 255.0
            let green = Double(pixels[index + 1]) / 255.0
            let blue = Double(pixels[index + 2]) / 255.0
            let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            totalLuma += luma
            if luma > 0.12 {
                brightPixelCount += 1
            }
        }

        let averageLuma = totalLuma / Double(sampleWidth * sampleHeight)
        let brightPixelRatio = Double(brightPixelCount) / Double(sampleWidth * sampleHeight)
        return averageLuma < 0.045 && brightPixelRatio < 0.08
    }
}
