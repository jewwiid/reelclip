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
        // Build the user message — feature pack is already compact JSON.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let featureJSON = String(
            data: (try? encoder.encode(features)) ?? Data(),
            encoding: .utf8
        ) ?? "{}"

        let instructions = """
        You plan short-form creator edits for Reels and TikTok. Use only the \
        supplied timeline features. Do not invent media outside the source \
        duration. Prefer energetic pacing, avoid duplicate ranges, and keep \
        clips inside the source duration.
        """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: """
            User request:
            \(prompt)

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
