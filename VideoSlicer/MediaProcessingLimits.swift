import Foundation

/// Source / clip / analysis limits. The source duration cap and the export
/// resolution cap differ by subscription tier:
///
/// - Free       :  5 min sources, 720p export, watermark applied
/// - Creator    : 15 min sources, native resolution, no watermark
/// - Studio     : 30 min sources, native resolution, no watermark
///                   + priority render queue
///                   + SRT/VTT transcript export
enum MediaProcessingLimits {

    // MARK: - Tier limits

    /// Maximum source video duration we accept, by tier. Free tier wants a
    /// short bound so the user feels the gate; the longer tiers unlock the
    /// use cases the user is paying for (podcast clips, webinar edits).
    static func maximumSourceDurationSeconds(for tier: SubscriptionStore.Tier) -> Double {
        switch tier {
        case .free:    return 5.0 * 60.0
        case .creator: return 15.0 * 60.0
        case .studio:  return 30.0 * 60.0
        }
    }

    /// Maximum number of AI plans (AI-Assist + NL-Refine) per calendar month
    /// for free tier. Paid tiers are unlimited.
    static let monthlyFreeAIQuota = 3

    // MARK: - Universal caps (don't vary by tier)

    static let maximumPlannedClips = 180
    static let maximumAIAnalysisPoints = 120
    static let minimumAIClipDuration = 0.5

    // MARK: - Display helpers

    static func maximumSourceDurationLabel(for tier: SubscriptionStore.Tier) -> String {
        formatDuration(maximumSourceDurationSeconds(for: tier))
    }

    /// Tier-cased validity check. Throws `.sourceTooLong(maximumDuration:)`
    /// with the right per-tier limit so the error message can offer the
    /// upgrade path.
    static func validateSourceDuration(
        _ durationSeconds: Double,
        for tier: SubscriptionStore.Tier
    ) throws {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw VideoSegmenterError.invalidDuration
        }

        let maximum = maximumSourceDurationSeconds(for: tier)
        guard durationSeconds <= maximum else {
            throw MediaProcessingLimitError.sourceTooLong(maximumDuration: maximum)
        }
    }

    /// Backwards-compatible overload — assumes Free tier. Marked deprecated
    /// so call sites are forced onto the tier-aware API.
    @available(*, deprecated, message: "Use validateSourceDuration(_:for:) with a tier.")
    static func validateSourceDuration(_ durationSeconds: Double) throws {
        try validateSourceDuration(durationSeconds, for: .free)
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
            let label = MediaProcessingLimits.formatDuration(maximumDuration)
            return "This video is longer than the \(label) limit for your plan. Upgrade to Creator (15m) or Studio (30m), or trim the source first."
        case .tooManyPlannedClips(let count, let maximum):
            return "This plan would create \(count) clips. Increase the segment length or lower the requested clip count; the current safety limit is \(maximum) clips."
        }
    }
}
