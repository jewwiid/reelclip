import Foundation

/// OpenAI Chat Completions provider. Works with OpenAI's hosted models AND any
/// OpenAI-compatible endpoint (Ollama, LM Studio, vLLM) by overriding `endpoint`.
struct OpenAIEditProvider: AIEditProvider {
    let id: AIProvider
    let displayName: String

    private let model: String
    private let endpoint: URL
    private let urlSession: URLSession

    init(
        provider: AIProvider,
        model: String,
        endpoint: URL,
        urlSession: URLSession = OpenAIEditProvider.makeSession()
    ) {
        self.id = provider
        self.displayName = provider.displayName
        self.model = model
        self.endpoint = endpoint
        self.urlSession = urlSession
    }

    static func openAI(model: String = "gpt-4o") -> OpenAIEditProvider {
        OpenAIEditProvider(
            provider: .openai,
            model: model,
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!
        )
    }

    static func ollama(model: String = "llama3.2-vision", host: String = "http://localhost:11434") -> OpenAIEditProvider? {
        guard let url = URL(string: "\(host)/v1/chat/completions") else {
            return nil
        }
        return OpenAIEditProvider(
            provider: .ollama,
            model: model,
            endpoint: url
        )
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }

    func planCuts(
        prompt: String,
        features: TimelineFeaturePack,
        credential: String?
    ) async throws -> [ClipRange] {
        // Ollama runs locally and does not require an API key. The
        // endpoint URL is already baked into the provider at init time
        // via `ollama(host:)`. For OpenAI, a credential is required.
        let isOllama = id == .ollama
        if !isOllama {
            guard let key = credential, !key.isEmpty else {
                throw OpenAIEditProviderError.missingCredential
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let featureJSON = String(
            data: (try? encoder.encode(features)) ?? Data(),
            encoding: .utf8
        ) ?? "{}"

        let systemPrompt = """
        You plan short-form creator edits for Reels and TikTok. Use only the \
        supplied timeline features. Do not invent media outside the source \
        duration. Prefer energetic pacing, avoid duplicate ranges, keep clips \
        inside the source duration, and return only strict JSON in the schema \
        {\"clips\":[{\"start\":0.0,\"end\":2.0,\"reason\":\"...\"}]}. Never include \
        reasoning, markdown, code fences, or explanatory text.
        """

        let userPrompt = """
        User request:
        \(prompt)

        Timeline feature pack:
        \(featureJSON)
        """

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 1200,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Ollama doesn't need an Authorization header — it runs locally.
        // OpenAI requires a Bearer token.
        if !isOllama, let key = credential {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIEditProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIEditProviderError.requestFailed(
                statusCode: http.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Request failed"
            )
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              let contentData = content.data(using: .utf8) else {
            throw OpenAIEditProviderError.invalidResponse
        }
        let plan = try JSONDecoder().decode(ClipPlanResponse.self, from: contentData)
        return plan.clips.map { ClipRange(startSeconds: $0.start, endSeconds: $0.end, reason: $0.reason) }
    }

    /// Vision-capable path for GPT-4o. Builds a multi-content user message
    /// with the prompt text followed by one `image_url` block per sampled
    /// frame (as a base64 data URL). Falls back to text-only `planCuts`
    /// when `frames` is empty.
    func planCutsWithVision(
        prompt: String,
        features: TimelineFeaturePack,
        frames: [VideoFrameSample],
        credential: String?
    ) async throws -> [ClipRange] {
        guard !frames.isEmpty else {
            return try await planCuts(prompt: prompt, features: features, credential: credential)
        }

        let isOllama = id == .ollama
        if !isOllama {
            guard let key = credential, !key.isEmpty else {
                throw OpenAIEditProviderError.missingCredential
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let featureJSON = String(
            data: (try? encoder.encode(features)) ?? Data(),
            encoding: .utf8
        ) ?? "{}"

        let systemPrompt = Self.visionSystemPrompt

        // Build the multi-content user message: text first, then one
        // image_url block per frame. Each frame's timestamp is noted in
        // the text block so the model can correlate frames with the
        // audio feature pack timeline.
        let frameTimestamps = frames.map { String(format: "%.2f", $0.timeSeconds) }.joined(separator: ", ")
        let userText = """
        User request:
        \(prompt)

        Sampled frame timestamps (seconds): \(frameTimestamps)

        Audio energy / timeline feature pack:
        \(featureJSON)
        """

        var content: [[String: Any]] = [["type": "text", "text": userText]]
        for frame in frames {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(frame.base64JPEG)"]
            ])
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 1200,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": content]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if !isOllama, let key = credential {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIEditProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIEditProviderError.requestFailed(
                statusCode: http.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Request failed"
            )
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let contentString = decoded.choices.first?.message.content,
              let contentData = contentString.data(using: .utf8) else {
            throw OpenAIEditProviderError.invalidResponse
        }
        let plan = try JSONDecoder().decode(ClipPlanResponse.self, from: contentData)
        return plan.clips.map { ClipRange(startSeconds: $0.start, endSeconds: $0.end, reason: $0.reason) }
    }

    static let visionSystemPrompt = """
    You are planning short-form clips for Reels and TikTok. You are given:
    1. Sampled frames from the source video (as images, with timestamps)
    2. Audio energy levels across the timeline
    3. The user's edit intent

    Look at the frames to identify: faces, action, text on screen, scene \
    changes, emotional moments. Combine visual analysis with audio levels to \
    pick the best segments. Do not invent media outside the source duration. \
    Return strict JSON: \
    {\"clips\":[{\"start\":0.0,\"end\":2.5,\"reason\":\"...\"}]}. Never include \
    reasoning, markdown, code fences, or explanatory text outside the JSON.
    """

    private struct OpenAIResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct ClipPlanResponse: Decodable {
        let clips: [PlannedClip]
    }

    private struct PlannedClip: Decodable {
        let start: Double
        let end: Double
        let reason: String?
    }
}

enum OpenAIEditProviderError: LocalizedError, Equatable {
    case missingCredential
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredential: return "Add an API key or endpoint before continuing."
        case .requestFailed(let statusCode, let message): return "Request returned \(statusCode): \(message)"
        case .invalidResponse: return "The response did not contain a valid clip plan."
        }
    }
}
