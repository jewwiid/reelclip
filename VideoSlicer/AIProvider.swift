import Foundation

/// User-selectable provider for the AI Assist cut planner.
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case appleIntelligence
    case minimax
    case claude
    case openai
    case gemini
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .minimax: return "MiniMax"
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .ollama: return "Ollama (local)"
        }
    }

    var blurb: String {
        switch self {
        case .appleIntelligence: return "Free, on-device. Requires iPhone 15 Pro or later."
        case .minimax: return "Cheap chat completions, JSON output."
        case .claude: return "Best structured output. Prompt caching cuts repeat costs."
        case .openai: return "GPT-4o / 4.1, reliable vision-capable model."
        case .gemini: return "Native video understanding. Premium quality."
        case .ollama: return "Self-hosted. Free, runs on your machine."
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .appleIntelligence, .ollama: return false
        case .minimax, .claude, .openai, .gemini: return true
        }
    }

    var keychainAccount: String {
        switch self {
        case .appleIntelligence: return "apple-intelligence-no-key"
        case .minimax: return "minimax-api-key"
        case .claude: return "anthropic-api-key"
        case .openai: return "openai-api-key"
        case .gemini: return "gemini-api-key"
        case .ollama: return "ollama-endpoint"
        }
    }

    /// URL users should visit to create an account / grab a key.
    var signupURL: URL? {
        switch self {
        case .appleIntelligence: return nil
        case .minimax: return URL(string: "https://api.minimax.io")
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .ollama: return URL(string: "https://ollama.com")
        }
    }

    /// Default model id for this provider. Users can override later.
    var defaultModel: String {
        switch self {
        case .appleIntelligence: return "apple-foundation-model"
        case .minimax: return "MiniMax-M3"
        case .claude: return "claude-4-5-sonnet"
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.5-pro"
        case .ollama: return "llama3.2-vision"
        }
    }

    /// True when the provider's default model accepts image inputs alongside
    /// text. Vision-capable providers receive sampled video frames via
    /// `planCutsWithVision`; non-vision providers fall back to text-only.
    var supportsVision: Bool {
        switch self {
        case .openai, .claude, .gemini: return true
        case .minimax, .ollama, .appleIntelligence: return false
        }
    }
}

protocol AIEditProvider {
    var id: AIProvider { get }
    var displayName: String { get }
    /// `credential` is the raw value stored in the Keychain for this provider —
    /// either the API key (cloud providers) or the endpoint URL (Ollama).
    /// For Apple Intelligence this is ignored.
    func planCuts(
        prompt: String,
        features: TimelineFeaturePack,
        credential: String?
    ) async throws -> [ClipRange]
    /// Vision-capable providers override this to send frames to the model.
    /// Default implementation falls back to text-only `planCuts`.
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
