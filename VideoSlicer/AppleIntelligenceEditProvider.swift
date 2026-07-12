import Foundation
import FoundationModels

/// On-device provider backed by Apple's `FoundationModels` framework (iOS 26+).
/// Free, no network, no API key. Constrained JSON output via `@Generable`.
@available(iOS 26, *)
struct AppleIntelligenceEditProvider: AIEditProvider {
    let id: AIProvider = .appleIntelligence
    let displayName: String = "Apple Intelligence"

    private let model: SystemLanguageModel

    init() {
        self.model = SystemLanguageModel.default
    }

    func planCuts(
        prompt: String,
        features: TimelineFeaturePack,
        credential: String?
    ) async throws -> [ClipRange] {
        switch model.availability {
        case .available:
            break
        case .unavailable(.appleIntelligenceNotEnabled):
            throw AppleIntelligenceEditError.notEnabled
        case .unavailable(.modelNotReady):
            throw AppleIntelligenceEditError.modelNotReady
        case .unavailable(.deviceNotEligible):
            throw AppleIntelligenceEditError.deviceNotEligible
        case .unavailable:
            throw AppleIntelligenceEditError.unavailable
        }
        guard model.supportsLocale(Locale.current) else {
            throw AppleIntelligenceEditError.unsupportedLocale
        }

        let compactFeatures = features.compactForLanguageModel()

        // Build the user message from a bounded feature pack. Apple
        // Intelligence is text-only, so raw video frames are omitted.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let featureJSON = String(
            data: (try? encoder.encode(compactFeatures)) ?? Data(),
            encoding: .utf8
        ) ?? "{}"
        let boundedPrompt = String(prompt.prefix(2_000))

        let instructions = """
        You plan short-form creator edits for Reels and TikTok. Use only the \
        supplied timeline features. Do not invent media outside the source \
        duration. Use transcriptSnippets when present to match the user's \
        requested topic, quote, hook, or conclusion to timestamped speech. \
        Prefer energetic pacing, avoid duplicate ranges, and keep \
        clips inside the source duration. Treat editIntent fields marked exact \
        as hard requirements: return the requested clip count and make every \
        clip the target duration. ReelClip validates these requirements after \
        generation, so focus on ranking the strongest moments. If \
        selectionRanges is non-empty, \
        every returned clip must be fully contained inside one of those ranges. \
        Never select outside the user's highlighted or curated ranges. The \
        feature pack may contain sampled summaries rather than every source \
        point. When editIntent does not request an exact count, return a small, \
        useful set rather than exhausting the requested maximum.
        """

        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        let response = try await session.respond(
            to: """
            User request:
            \(boundedPrompt)

            Timeline feature pack:
            \(featureJSON)
            """,
            generating: ClipPlanSchema.self
        )

        return response.content.clips.map {
            ClipRange(startSeconds: $0.start, endSeconds: $0.end, reason: $0.reason)
        }
    }
}

@available(iOS 26, *)
enum AppleIntelligenceEditError: LocalizedError {
    case notEnabled
    case modelNotReady
    case deviceNotEligible
    case unsupportedLocale
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "Apple Intelligence is turned off. Enable it in Settings, then try again."
        case .modelNotReady:
            return "Apple Intelligence is still preparing its on-device model. Try again when the download is complete."
        case .deviceNotEligible:
            return "This device cannot run Apple Intelligence editing."
        case .unsupportedLocale:
            return "Apple Intelligence does not currently support this device language."
        case .unavailable:
            return "Apple Intelligence is temporarily unavailable. Try again later."
        }
    }
}

@available(iOS 26, *)
@Generable
struct ClipPlanSchema {
    @Guide(description: "List of clip ranges within the source duration")
    var clips: [ClipSchema]
}

@available(iOS 26, *)
@Generable
struct ClipSchema {
    @Guide(description: "Start time in seconds, must be >= 0")
    var start: Double
    @Guide(description: "End time in seconds, must be > start and within source duration")
    var end: Double
    @Guide(description: "One short sentence explaining why this clip")
    var reason: String
}
