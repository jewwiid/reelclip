import Foundation

/// Adapter that exposes the existing `MiniMaxEditPlanner` through the new
/// `AIEditProvider` protocol. Kept separate so the original planner code
/// (and its tests, if any) keep working unchanged.
struct MiniMaxEditProvider: AIEditProvider {
    let id: AIProvider = .minimax
    let displayName: String = "MiniMax"

    private let planner: MiniMaxEditPlanner

    init(planner: MiniMaxEditPlanner) {
        self.planner = planner
    }

    func planCuts(
        prompt: String,
        features: TimelineFeaturePack,
        credential: String?
    ) async throws -> [ClipRange] {
        guard let key = credential, !key.isEmpty else {
            throw MiniMaxEditPlannerError.missingAPIKey
        }
        // Inject the credential into the injected planner's config so
        // custom endpoint, model, urlSession, and requestTimeout are
        // preserved. The previous code discarded the injected planner
        // and hardcoded model="MiniMax-M3", ignoring user overrides.
        let scoped = MiniMaxEditPlanner(
            apiKey: key,
            model: planner.model,
            endpoint: planner.endpoint,
            urlSession: planner.urlSession,
            requestTimeout: planner.requestTimeout
        )
        return try await scoped.planCuts(prompt: prompt, features: features)
    }
}
