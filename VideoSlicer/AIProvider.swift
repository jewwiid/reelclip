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
    /// Timestamped on-device transcript context. This lets the language model
    /// match semantic requests (topic, quote, hook, conclusion) to moments
    /// without receiving raw audio or uploading media.
    var transcriptSnippets: [TimelineTranscriptSnippet] = []
    /// Deterministic interpretation of the user's request. Foundation Models
    /// uses this to rank moments; ReelClip validates the hard constraints after
    /// generation so count and duration are never left to model inference.
    var editIntent: AIEditIntent = .automatic(fallbackDuration: 10)
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
            transcriptSnippets: Self.compactTranscriptSnippets(
                transcriptSnippets,
                maximumCount: 24,
                maximumCharacters: 160
            ),
            editIntent: editIntent,
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

    private static func compactTranscriptSnippets(
        _ snippets: [TimelineTranscriptSnippet],
        maximumCount: Int,
        maximumCharacters: Int
    ) -> [TimelineTranscriptSnippet] {
        guard !snippets.isEmpty, maximumCount > 0 else { return [] }
        let strideSize = max(1, Int(ceil(Double(snippets.count) / Double(maximumCount))))
        return stride(from: 0, to: snippets.count, by: strideSize)
            .prefix(maximumCount)
            .map { index in
                var snippet = snippets[index]
                snippet.text = String(snippet.text.prefix(maximumCharacters))
                return snippet
            }
    }
}

/// Structured ReelClip contract resolved from a natural-language AI request.
/// Exact values are deterministic requirements; the model remains free to
/// choose *where* those clips come from.
struct AIEditIntent: Codable, Equatable {
    var requestedClipCount: Int?
    var targetClipDurationSeconds: Double
    var requiresExactCount: Bool
    var requiresExactDuration: Bool

    static func automatic(fallbackDuration: Double) -> AIEditIntent {
        AIEditIntent(
            requestedClipCount: nil,
            targetClipDurationSeconds: max(fallbackDuration, 0.5),
            requiresExactCount: false,
            requiresExactDuration: false
        )
    }

    var expectedClipCount: Int? {
        requiresExactCount ? requestedClipCount : nil
    }

    var expectedTotalDuration: Double? {
        guard requiresExactCount,
              requiresExactDuration,
              let requestedClipCount else { return nil }
        return Double(requestedClipCount) * targetClipDurationSeconds
    }

    var summary: String? {
        var parts: [String] = []
        if let expectedClipCount {
            parts.append("\(expectedClipCount) clip\(expectedClipCount == 1 ? "" : "s")")
        }
        if requiresExactDuration {
            let duration = targetClipDurationSeconds == targetClipDurationSeconds.rounded()
                ? "\(Int(targetClipDurationSeconds))s"
                : String(format: "%.1fs", targetClipDurationSeconds)
            parts.append("\(duration) each")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum AIEditIntentParser {
    static func parse(
        prompt: String,
        fallbackDuration: Double,
        maximumClipCount: Int = MediaProcessingLimits.maximumPlannedClips
    ) -> AIEditIntent {
        let query = ClipQueryParser.parse(prompt)
        let count = query?.count ?? standaloneCount(in: prompt)
        let duration = query?.durationSeconds ?? standaloneDuration(in: prompt)
        let cleanedCount = count.map { min(max($0, 1), maximumClipCount) }
        let cleanedDuration = duration.map { min(max($0, 0.5), 300) }

        return AIEditIntent(
            requestedClipCount: cleanedCount,
            targetClipDurationSeconds: cleanedDuration ?? max(fallbackDuration, 0.5),
            requiresExactCount: cleanedCount != nil,
            requiresExactDuration: cleanedDuration != nil
        )
    }

    private static func standaloneCount(in prompt: String) -> Int? {
        firstNumber(
            in: prompt,
            pattern: #"(?i)\b(\d+)\s+(?:clips?|cuts?|segments?)\b"#
        ).map(Int.init)
    }

    private static func standaloneDuration(in prompt: String) -> Double? {
        guard let match = firstNumber(
            in: prompt,
            pattern: #"(?i)\b(?:clips?\s+)?(\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m)\b"#
        ) else { return nil }
        let lower = prompt.lowercased()
        let isMinutes = lower.range(of: #"\d+(?:\.\d+)?\s*(?:minutes?|mins?|m)\b"#, options: .regularExpression) != nil
        return isMinutes ? match * 60 : match
    }

    private static func firstNumber(in text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let numberRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[numberRange])
    }
}

enum AIEditIntentError: LocalizedError, Equatable {
    case insufficientSource(required: Double, available: Double)
    case couldNotSatisfyCount(requested: Int)

    var errorDescription: String? {
        switch self {
        case .insufficientSource(let required, let available):
            return "This AI edit needs \(Int(required.rounded()))s of footage, but only \(Int(available.rounded()))s is available. Reduce the clip count or duration."
        case .couldNotSatisfyCount(let requested):
            return "Apple Intelligence found moments, but ReelClip could not place exactly \(requested) non-overlapping clips. Reduce the clip count or duration."
        }
    }
}

/// Converts model-selected candidate moments into a valid ReelClip plan. The
/// model ranks content; this solver owns exact count, exact duration, source
/// bounds, scope containment, and overlap prevention.
enum AIEditPlanResolver {
    static func resolve(
        candidates: [ClipRange],
        features: TimelineFeaturePack
    ) throws -> [ClipRange] {
        let intent = features.editIntent
        guard intent.requiresExactCount || intent.requiresExactDuration else {
            return candidates
        }

        let scopes = normalizedScopes(features)
        let availableDuration = scopes.reduce(0.0) { $0 + $1.duration }
        if let required = intent.expectedTotalDuration,
           required > availableDuration + 0.001 {
            throw AIEditIntentError.insufficientSource(
                required: required,
                available: availableDuration
            )
        }

        let desiredCount = intent.expectedClipCount ?? max(candidates.count, 1)
        let targetDuration = intent.requiresExactDuration
            ? intent.targetClipDurationSeconds
            : min(
                intent.targetClipDurationSeconds,
                availableDuration / Double(max(desiredCount, 1))
            )
        var resolved: [ClipRange] = []

        func appendCandidate(_ candidate: ClipRange) {
            guard resolved.count < desiredCount,
                  let fitted = fittedRange(
                    around: candidate,
                    duration: targetDuration,
                    scopes: scopes
                  ),
                  !resolved.contains(where: { overlaps($0, fitted) }) else {
                return
            }
            resolved.append(fitted)
        }

        // Preserve the model's priority order first, then use ReelClip's audio
        // signals and deterministic fallback grid only to fill missing slots.
        candidates.forEach(appendCandidate)
        features.analysisPoints
            .filter { !$0.isQuiet }
            .sorted { $0.audioLevel > $1.audioLevel }
            .map {
                ClipRange(
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.endSeconds,
                    reason: "Strong timeline signal"
                )
            }
            .forEach(appendCandidate)
        features.fallbackRanges.forEach(appendCandidate)

        if resolved.count < desiredCount {
            for scope in scopes {
                var start = scope.startSeconds
                while start + targetDuration <= scope.endSeconds + 0.001,
                      resolved.count < desiredCount {
                    appendCandidate(ClipRange(
                        startSeconds: start,
                        endSeconds: start + targetDuration,
                        reason: "ReelClip fallback placement"
                    ))
                    start += targetDuration
                }
            }
        }

        if intent.requiresExactCount, resolved.count != desiredCount {
            throw AIEditIntentError.couldNotSatisfyCount(requested: desiredCount)
        }

        return resolved
            .prefix(desiredCount)
            .sorted { $0.startSeconds < $1.startSeconds }
    }

    private static func normalizedScopes(_ features: TimelineFeaturePack) -> [ClipRange] {
        let sourceDuration = features.sourceDurationSeconds
        let raw = features.selectionRanges.isEmpty
            ? [ClipRange(startSeconds: 0, endSeconds: sourceDuration)]
            : features.selectionRanges
        return raw.compactMap { range in
            let start = min(max(range.startSeconds, 0), sourceDuration)
            let end = min(max(range.endSeconds, 0), sourceDuration)
            guard end - start >= 0.5 else { return nil }
            return ClipRange(startSeconds: start, endSeconds: end)
        }
    }

    private static func fittedRange(
        around candidate: ClipRange,
        duration: Double,
        scopes: [ClipRange]
    ) -> ClipRange? {
        let midpoint = (candidate.startSeconds + candidate.endSeconds) / 2
        let scope = scopes
            .filter { $0.duration + 0.001 >= duration }
            .max { lhs, rhs in
                overlapDuration(candidate, lhs) < overlapDuration(candidate, rhs)
            }
        guard let scope else { return nil }

        let unclampedStart = midpoint - duration / 2
        let start = min(max(unclampedStart, scope.startSeconds), scope.endSeconds - duration)
        return ClipRange(
            startSeconds: start,
            endSeconds: start + duration,
            reason: candidate.reason
        )
    }

    private static func overlapDuration(_ lhs: ClipRange, _ rhs: ClipRange) -> Double {
        max(0, min(lhs.endSeconds, rhs.endSeconds) - max(lhs.startSeconds, rhs.startSeconds))
    }

    private static func overlaps(_ lhs: ClipRange, _ rhs: ClipRange) -> Bool {
        lhs.startSeconds < rhs.endSeconds - 0.001
            && rhs.startSeconds < lhs.endSeconds - 0.001
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

struct TimelineTranscriptSnippet: Codable, Equatable {
    var startSeconds: Double
    var endSeconds: Double
    var text: String
}

/// A sampled video frame, base64-JPEG encoded. Apple
/// Intelligence does not currently consume vision frames, but
/// the type is kept on `TimelineFeaturePack` so future Core ML
/// runtimes can plug in without changing the planner.
struct VideoFrameSample: Codable, Equatable {
    var timeSeconds: Double
    var base64JPEG: String
}
