import Foundation

/// Factory for the on-device `AIEditProvider`.
///
/// As of the v72 180, ReelClip is strictly Apple-native — only
/// Apple Intelligence (Foundation Models) is supported. The
/// registry now resolves a single provider; the
/// `minimax:` parameter and `resolvedProvider(…)` fallback chain
/// are retained as protocol surfaces so future on-device
/// runtimes (Core ML, custom model files) can slot in without
/// churn at every call site.
enum AIProviderRegistry {
    /// Returns the provider implementation for the given selection.
    /// Apple Intelligence is unavailable on pre-iOS 26 devices —
    /// the call site should surface a friendly "Apple Intelligence
    /// required" error or prompt the user to update.
    static func provider(
        for selection: AIProvider
    ) -> AIEditProvider? {
        switch selection {
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(iOS 26, *) {
                return AppleIntelligenceEditProvider()
            }
            #endif
            return nil
        }
    }

    /// Resolves the provider for a user's selection. Returns `nil`
    /// if the on-device runtime is unavailable (pre-iOS 26 device
    /// or Apple Intelligence not enabled in Settings). Callers
    /// should surface a friendly "requires iPhone 15 Pro or later"
    /// error in that case.
    static func resolvedProvider(
        for selection: AIProvider
    ) -> (provider: AIEditProvider, didFallback: Bool, fallbackFrom: AIProvider?)? {
        if let p = provider(for: selection) {
            return (p, false, nil)
        }
        return nil
    }
}
