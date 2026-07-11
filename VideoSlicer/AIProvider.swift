import Foundation

/// AI provider for the AI Assist cut planner.
///
/// As of the v72 180, ReelClip is strictly an iOS-Apple-native app:
/// AI runs on-device via Apple's `FoundationModels` framework
/// (iOS 26+, eligible devices only). No cloud providers, no
/// bring-your-own-API-key, no custom models. The enum is kept
/// (instead of a `Bool isAppleIntelligenceAvailable`) so future
/// on-device runtimes (Core ML models, etc.) can slot in as
/// additional cases without churn at every call site.
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case appleIntelligence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        }
    }

    var blurb: String {
        switch self {
        case .appleIntelligence:
            return "Free, on-device. Requires iPhone 15 Pro or later with Apple Intelligence enabled."
        }
    }

    /// Apple Intelligence is a system framework — no API key
    /// concept. Kept as a property for protocol conformance /
    /// future-proofing.
    var requiresAPIKey: Bool {
        switch self {
        case .appleIntelligence: return false
        }
    }

    /// No keychain account is needed for Apple Intelligence.
    /// Property kept for symmetry with the credential plumbing.
    var keychainAccount: String {
        switch self {
        case .appleIntelligence: return "apple-intelligence-no-key"
        }
    }

    /// No external signup URL — Apple Intelligence is a system
    /// capability.
    var signupURL: URL? {
        switch self {
        case .appleIntelligence: return nil
        }
    }

    /// System framework — no user-selectable model. Returns the
    /// Foundation Models identifier for display purposes only.
    var defaultModel: String {
        switch self {
        case .appleIntelligence: return "apple-foundation-model"
        }
    }

    /// Apple Intelligence does not currently accept raw video
    /// frames, so the planner stays on the text-only path.
    var supportsVision: Bool {
        switch self {
        case .appleIntelligence: return false
        }
    }
}

protocol AIEditProvider {
    var id: AIProvider { get }
    var displayName: String { get }
    /// `credential` is unused for Apple Intelligence — kept on
    /// the protocol so call sites don't need to branch on
    /// provider type.
    func planCuts(
        prompt: String,
        features: TimelineFeaturePack,
        credential: String?
    ) async throws -> [ClipRange]
    /// Apple Intelligence does not yet expose a vision pipeline
    /// for sampled video frames; the default text-only fallback
    /// applies.
    func planCutsWithVision(
        prompt: String,
        features: TimelineFeaturePack,
        frames: [VideoFrameSample],
        credential: String?
    ) async throws -> [ClipRange]
}

extension AIEditProvider {
    func planCutsWithVision(
        prompt: String,
        features: TimelineFeaturePack,
        frames: [VideoFrameSample],
        credential: String?
    ) async throws -> [ClipRange] {
        return try await planCuts(prompt: prompt, features: features, credential: credential)
    }
}

// MARK: - Timeline feature types

/// Compact representation of the source timeline that the AI
/// cut planner consumes. Previously lived alongside the cloud
/// provider implementations; relocated here so Apple Intelligence
/// (and any future on-device runtime) can share the same
/// payload shape.
struct TimelineFeaturePack: Codable, Equatable {
    var sourceDurationSeconds: Double
    var fallbackSegmentLengthSeconds: Double
    var requestedMaxClips: Int
    var targetPlatform: String
    var analysisPoints: [TimelineFeaturePoint]
    var fallbackRanges: [ClipRange]
    var videoFrames: [VideoFrameSample]
    /// Explicit user-selected scopes. An empty list means the whole source.
    /// Providers must never return a range outside these scopes when present.
    var selectionRanges: [ClipRange] = []
}

extension TimelineFeaturePack {
    /// Keep language-model requests bounded. The full timeline is useful for
    /// local analysis, but sending every point/range can exceed the on-device
    /// model context window.
    func compactForLanguageModel() -> TimelineFeaturePack {
        TimelineFeaturePack(
            sourceDurationSeconds: sourceDurationSeconds,
            fallbackSegmentLengthSeconds: fallbackSegmentLengthSeconds,
            requestedMaxClips: min(max(requestedMaxClips, 1), 32),
            targetPlatform: targetPlatform,
            analysisPoints: Self.compactAnalysisPoints(analysisPoints, maximumCount: 48),
            fallbackRanges: Array(fallbackRanges.prefix(32)),
            videoFrames: [],
            selectionRanges: Self.compactSelectionRanges(selectionRanges, maximumCount: 12)
        )
    }

    private static func compactAnalysisPoints(
        _ points: [TimelineFeaturePoint],
        maximumCount: Int
    ) -> [TimelineFeaturePoint] {
        guard points.count > maximumCount, maximumCount > 0 else { return points }

        let bucketSize = Int(ceil(Double(points.count) / Double(maximumCount)))
        return stride(from: 0, to: points.count, by: bucketSize).map { start in
            let end = min(start + bucketSize, points.count)
            let bucket = points[start..<end]
            let audioLevel = bucket.reduce(0.0) { $0 + $1.audioLevel } / Double(bucket.count)
            return TimelineFeaturePoint(
                startSeconds: bucket.first?.startSeconds ?? 0,
                endSeconds: bucket.last?.endSeconds ?? bucket.first?.endSeconds ?? 0,
                audioLevel: audioLevel,
                isQuiet: bucket.allSatisfy(\.isQuiet)
            )
        }
    }

    private static func compactSelectionRanges(
        _ ranges: [ClipRange],
        maximumCount: Int
    ) -> [ClipRange] {
        let sorted = ranges.sorted { $0.startSeconds < $1.startSeconds }
        guard sorted.count > maximumCount, maximumCount > 0 else { return sorted }

        let bucketSize = Int(ceil(Double(sorted.count) / Double(maximumCount)))
        return stride(from: 0, to: sorted.count, by: bucketSize).map { start in
            let end = min(start + bucketSize, sorted.count)
            let bucket = sorted[start..<end]
            return ClipRange(
                startSeconds: bucket.map(\.startSeconds).min() ?? 0,
                endSeconds: bucket.map(\.endSeconds).max() ?? 0
            )
        }
    }
}

/// Single audio analysis sample. Drives the planner's "where
/// are the quiet / loud regions" reasoning.
struct TimelineFeaturePoint: Codable, Equatable {
    var startSeconds: Double
    var endSeconds: Double
    var audioLevel: Double
    var isQuiet: Bool
}

/// A sampled video frame, base64-JPEG encoded. Apple
/// Intelligence does not currently consume vision frames, but
/// the type is kept on `TimelineFeaturePack` so future Core ML
/// runtimes can plug in without changing the planner.
struct VideoFrameSample: Codable, Equatable {
    var timeSeconds: Double
    var base64JPEG: String
}
