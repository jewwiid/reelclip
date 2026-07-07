import Foundation

/// Factory for instantiating the correct `AIEditProvider` based on the
/// user's selection. Centralised so `SettingsView` and `VideoSplitterViewModel`
/// agree on the same selection logic.
enum AIProviderRegistry {
    /// Returns the provider implementation for the given selection. Apple
    /// Intelligence is unavailable on pre-iOS 26 devices — the call site
    /// should fall back to another provider or surface a friendly error.
    static func provider(
        for selection: AIProvider,
        minimax: MiniMaxEditProvider = MiniMaxEditProvider(planner: MiniMaxEditPlanner(apiKey: ""))
    ) -> AIEditProvider? {
        switch selection {
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(iOS 26, *) {
                return AppleIntelligenceEditProvider()
            }
            #endif
            return nil
        case .minimax:
            return minimax
        case .claude:
            return ClaudeEditProvider()
        case .openai:
            return OpenAIEditProvider.openAI()
        case .gemini:
            return GeminiEditProvider()
        case .ollama:
            return OpenAIEditProvider.ollama()
        }
    }

    /// Resolves the provider for a user's selection, with a smart fallback
    /// when the requested one is unavailable (e.g. Apple Intelligence on
    /// an unsupported device). Returns `nil` if no provider can be
    /// resolved — the caller should surface a friendly error instead of
    /// crashing.
    static func resolvedProvider(
        for selection: AIProvider,
        minimax: MiniMaxEditProvider
    ) -> (provider: AIEditProvider, didFallback: Bool, fallbackFrom: AIProvider?)? {
        if let p = provider(for: selection, minimax: minimax) {
            return (p, false, nil)
        }
        // Apple Intelligence on an unsupported device → fall back to MiniMax
        // (or whatever the user has a key for).
        if selection == .appleIntelligence, let p = provider(for: .minimax, minimax: minimax) {
            return (p, true, .appleIntelligence)
        }
        // Last resort: MiniMax
        if let p = provider(for: .minimax, minimax: minimax) {
            return (p, true, selection)
        }
        return nil
    }
}
