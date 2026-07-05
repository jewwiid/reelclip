import Foundation

enum MediaProcessingLimits {
    static let maximumSourceDurationSeconds = 30.0 * 60.0
    static let maximumPlannedClips = 180
    static let maximumAIAnalysisPoints = 120
    static let minimumAIClipDuration = 0.5

    static var maximumSourceDurationLabel: String {
        formatDuration(maximumSourceDurationSeconds)
    }

    static func validateSourceDuration(_ durationSeconds: Double) throws {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw VideoSegmenterError.invalidDuration
        }

        guard durationSeconds <= maximumSourceDurationSeconds else {
            throw MediaProcessingLimitError.sourceTooLong(maximumDuration: maximumSourceDurationSeconds)
        }
    }

    static func validatedClipPlan(
        _ ranges: [ClipRange],
        totalDuration: Double,
        frameDuration: Double,
        minimumDuration: Double = minimumAIClipDuration
    ) throws -> [ClipRange] {
        let normalized = VideoSegmenter.normalizedRanges(ranges, totalDuration: totalDuration)
            .map { range in
                ClipRangeEditor.updatedRange(
                    range,
                    totalDuration: totalDuration,
                    frameDuration: frameDuration,
                    minimumDuration: minimumDuration
                )
            }
            .filter { $0.duration >= minimumDuration }

        guard !normalized.isEmpty else {
            throw VideoSegmenterError.invalidDuration
        }

        guard normalized.count <= maximumPlannedClips else {
            throw MediaProcessingLimitError.tooManyPlannedClips(
                count: normalized.count,
                maximum: maximumPlannedClips
            )
        }

        return normalized
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let rounded = Int(seconds.rounded())
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let remainingSeconds = rounded % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        }

        return "\(remainingSeconds)s"
    }
}

enum MediaProcessingLimitError: LocalizedError, Equatable {
    case sourceTooLong(maximumDuration: Double)
    case tooManyPlannedClips(count: Int, maximum: Int)

    var errorDescription: String? {
        switch self {
        case .sourceTooLong(let maximumDuration):
            return "This video is longer than the current \(MediaProcessingLimits.formatDuration(maximumDuration)) safety limit. Use a shorter source clip for this build."
        case .tooManyPlannedClips(let count, let maximum):
            return "This plan would create \(count) clips. Increase the segment length or lower the requested clip count; the current safety limit is \(maximum) clips."
        }
    }
}
