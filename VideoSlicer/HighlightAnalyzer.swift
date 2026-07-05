@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Vision

struct HighlightSettings: Equatable {
    var clipDuration: Double = 2.0
    var minClipDuration: Double = 1.0
    var sampleInterval: Double = 1.0
    var maxClips: Int = 12
    var prioritizeFaces = true
}

struct HighlightCandidate: Equatable {
    let timeSeconds: Double
    let score: Double
}

enum HighlightAnalyzerError: LocalizedError {
    case unableToReadFrames

    var errorDescription: String? {
        switch self {
        case .unableToReadFrames:
            return "The video frames could not be analyzed."
        }
    }
}

struct HighlightAnalyzer {
    private let coreMLScorer: CoreMLHighlightScorer

    init(coreMLScorer: CoreMLHighlightScorer = CoreMLHighlightScorer()) {
        self.coreMLScorer = coreMLScorer
    }

    func ranges(
        for sourceURL: URL,
        fallbackSegmentLength: Double,
        settings: HighlightSettings
    ) async throws -> [ClipRange] {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        guard totalSeconds.isFinite, totalSeconds > 0 else {
            throw VideoSegmenterError.invalidDuration
        }

        let candidates = try await candidates(for: asset, totalDuration: totalSeconds, settings: settings)
        let plannedRanges = Self.planRanges(totalDuration: totalSeconds, candidates: candidates, settings: settings)

        if plannedRanges.isEmpty {
            return SmartCutAnalyzer.equalRanges(totalDuration: totalSeconds, segmentLength: fallbackSegmentLength)
        }

        return plannedRanges
    }

    static func settings(from intent: CreatorEditIntent) -> HighlightSettings {
        HighlightSettings(
            clipDuration: intent.clipDuration,
            minClipDuration: intent.minClipDuration,
            sampleInterval: intent.pacing == .fast ? 0.75 : 1.0,
            maxClips: intent.maxClips,
            prioritizeFaces: intent.prioritizeFaces
        )
    }

    static func planRanges(
        totalDuration: Double,
        candidates: [HighlightCandidate],
        settings: HighlightSettings
    ) -> [ClipRange] {
        guard totalDuration.isFinite, totalDuration > 0 else { return [] }
        guard settings.clipDuration > 0, settings.minClipDuration > 0, settings.maxClips > 0 else { return [] }

        var selected: [ClipRange] = []
        let sortedCandidates = candidates.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.timeSeconds < rhs.timeSeconds
            }
            return lhs.score > rhs.score
        }

        for candidate in sortedCandidates {
            guard selected.count < settings.maxClips else { break }

            let range = centeredRange(
                around: candidate.timeSeconds,
                totalDuration: totalDuration,
                clipDuration: settings.clipDuration
            )

            guard range.duration >= settings.minClipDuration else { continue }
            guard !selected.contains(where: { overlaps($0, range) }) else { continue }

            selected.append(range)
        }

        return selected.sorted { $0.startSeconds < $1.startSeconds }
    }

    private func candidates(
        for asset: AVAsset,
        totalDuration: Double,
        settings: HighlightSettings
    ) async throws -> [HighlightCandidate] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 320, height: 320)

        var candidates: [HighlightCandidate] = []
        var previousProfile: FrameProfile?
        var time = max(settings.sampleInterval / 2, 0.1)

        while time < totalDuration {
            try Task.checkCancellation()

            let cmTime = CMTime(seconds: time, preferredTimescale: 600)

            do {
                let image = try generator.copyCGImage(at: cmTime, actualTime: nil)
                let profile = try analyzeFrame(image, previousProfile: previousProfile, prioritizeFaces: settings.prioritizeFaces)
                previousProfile = profile
                candidates.append(HighlightCandidate(timeSeconds: time, score: profile.score))
            } catch {
                if candidates.isEmpty {
                    throw HighlightAnalyzerError.unableToReadFrames
                }
            }

            time += max(settings.sampleInterval, 0.25)
        }

        return candidates
    }

    private func analyzeFrame(
        _ image: CGImage,
        previousProfile: FrameProfile?,
        prioritizeFaces: Bool
    ) throws -> FrameProfile {
        let visualStats = FrameProfile.visualStats(for: image)
        let faceScore = prioritizeFaces ? try detectFaceScore(in: image) : 0
        let motionScore = previousProfile.map { min(abs(visualStats.meanLuma - $0.meanLuma) * 2.5, 1) } ?? 0

        let handcraftedScore = (visualStats.brightnessScore * 0.25)
            + (visualStats.sharpnessScore * 0.30)
            + (faceScore * (prioritizeFaces ? 0.30 : 0.10))
            + (motionScore * 0.15)
        let features = HighlightScoreFeatures(
            brightnessScore: visualStats.brightnessScore,
            sharpnessScore: visualStats.sharpnessScore,
            faceScore: faceScore,
            motionScore: motionScore,
            handcraftedScore: min(max(handcraftedScore, 0), 1)
        )
        let score = coreMLScorer.score(features: features) ?? features.handcraftedScore

        return FrameProfile(
            meanLuma: visualStats.meanLuma,
            brightnessScore: visualStats.brightnessScore,
            sharpnessScore: visualStats.sharpnessScore,
            faceScore: faceScore,
            motionScore: motionScore,
            score: min(max(score, 0), 1)
        )
    }

    private func detectFaceScore(in image: CGImage) throws -> Double {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let results = request.results, !results.isEmpty else {
            return 0
        }

        let largestFaceArea = results
            .map { $0.boundingBox.width * $0.boundingBox.height }
            .max() ?? 0

        return min(0.5 + Double(largestFaceArea) * 2.0, 1.0)
    }

    private static func centeredRange(around time: Double, totalDuration: Double, clipDuration: Double) -> ClipRange {
        let halfDuration = clipDuration / 2
        let start = max(0, min(time - halfDuration, totalDuration))
        let end = min(totalDuration, max(start + clipDuration, time + halfDuration))

        if end > totalDuration {
            let adjustedStart = max(0, totalDuration - clipDuration)
            return ClipRange(startSeconds: adjustedStart, endSeconds: totalDuration)
        }

        return ClipRange(startSeconds: start, endSeconds: end)
    }

    private static func overlaps(_ lhs: ClipRange, _ rhs: ClipRange) -> Bool {
        lhs.startSeconds < rhs.endSeconds && rhs.startSeconds < lhs.endSeconds
    }
}

private struct FrameProfile {
    let meanLuma: Double
    let brightnessScore: Double
    let sharpnessScore: Double
    let faceScore: Double
    let motionScore: Double
    let score: Double

    static func visualStats(for image: CGImage) -> (meanLuma: Double, brightnessScore: Double, sharpnessScore: Double) {
        let width = 32
        let height = 32
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return (meanLuma: 0.5, brightnessScore: 0.5, sharpnessScore: 0)
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luma = [Double](repeating: 0, count: width * height)
        var lumaSum = 0.0

        for index in 0..<(width * height) {
            let offset = index * bytesPerPixel
            let red = Double(pixels[offset]) / 255.0
            let green = Double(pixels[offset + 1]) / 255.0
            let blue = Double(pixels[offset + 2]) / 255.0
            let value = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
            luma[index] = value
            lumaSum += value
        }

        let meanLuma = lumaSum / Double(width * height)
        let brightnessScore = 1.0 - min(abs(meanLuma - 0.52) * 2.0, 1.0)
        var edgeSum = 0.0
        var edgeCount = 0

        for row in 1..<height {
            for column in 1..<width {
                let index = row * width + column
                let left = row * width + column - 1
                let up = (row - 1) * width + column
                edgeSum += abs(luma[index] - luma[left]) + abs(luma[index] - luma[up])
                edgeCount += 2
            }
        }

        let sharpnessScore = min((edgeSum / Double(max(edgeCount, 1))) * 8.0, 1.0)
        return (meanLuma: meanLuma, brightnessScore: brightnessScore, sharpnessScore: sharpnessScore)
    }
}
