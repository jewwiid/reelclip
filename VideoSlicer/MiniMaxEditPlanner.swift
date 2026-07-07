import Foundation

protocol AIEditPlanner {
    func planCuts(prompt: String, features: TimelineFeaturePack) async throws -> [ClipRange]
}

struct TimelineFeaturePack: Codable, Equatable {
    var sourceDurationSeconds: Double
    var fallbackSegmentLengthSeconds: Double
    var requestedMaxClips: Int
    var targetPlatform: String
    var analysisPoints: [TimelineFeaturePoint]
    var fallbackRanges: [ClipRange]
    var videoFrames: [VideoFrameSample]
}

struct VideoFrameSample: Codable, Equatable {
    var timeSeconds: Double
    var base64JPEG: String
}

struct TimelineFeaturePoint: Codable, Equatable {
    var startSeconds: Double
    var endSeconds: Double
    var audioLevel: Double
    var isQuiet: Bool
}

enum MiniMaxEditPlannerError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidRequest
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse
    case noUsableClips

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a MiniMax API key before using AI Assist."
        case .invalidRequest:
            return "The MiniMax request could not be prepared."
        case .requestFailed(let statusCode, let message):
            return "MiniMax returned \(statusCode): \(message)"
        case .invalidResponse:
            return "MiniMax did not return a valid clip plan."
        case .noUsableClips:
            return "MiniMax did not return any usable clips."
        }
    }
}

final class MiniMaxEditPlanner: AIEditPlanner {
    /// Default per-request timeout. Bumped to 120s to absorb slow first-request
    /// latency on iOS simulator clones (DNS + TLS handshake can take 30-60s on
    /// the first call when the simulator boots cold). 45s was too tight even
    /// for healthy networks — real-world p99 latency on MiniMax chat completions
    /// sits in the 8-15s band, so 120s gives 8-15x headroom.
    static let defaultRequestTimeout: TimeInterval = 120

    private let apiKey: String
    /// Exposed so `MiniMaxEditProvider` can reuse the configured model
    /// when injecting credentials at call time.
    let model: String
    let endpoint: URL
    let urlSession: URLSession
    let requestTimeout: TimeInterval

    init(
        apiKey: String,
        model: String = "MiniMax-M3",
        endpoint: URL = URL(string: "https://api.minimax.io/v1/chat/completions")!,
        urlSession: URLSession = MiniMaxEditPlanner.makeDefaultSession(),
        requestTimeout: TimeInterval = MiniMaxEditPlanner.defaultRequestTimeout
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.requestTimeout = requestTimeout
    }

    /// URLSessionConfiguration that won't time out faster than `requestTimeout`.
    /// The `.shared` session uses a 60s default which would override a higher
    /// `request.timeoutInterval` on the per-request level. We need our own config
    /// so 120s ceiling actually holds.
    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = defaultRequestTimeout
        config.timeoutIntervalForResource = defaultRequestTimeout
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }

    func planCuts(prompt: String, features: TimelineFeaturePack) async throws -> [ClipRange] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MiniMaxEditPlannerError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try requestBody(prompt: prompt, features: features)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiniMaxEditPlannerError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MiniMaxEditPlannerError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        let content = try Self.assistantContent(from: data)
        let ranges = try Self.ranges(fromAssistantContent: content)
        let validated = try MediaProcessingLimits.validatedClipPlan(
            ranges,
            totalDuration: features.sourceDurationSeconds,
            frameDuration: 1.0 / 30.0
        )

        guard !validated.isEmpty else {
            throw MiniMaxEditPlannerError.noUsableClips
        }

        return validated
    }

    private func requestBody(prompt: String, features: TimelineFeaturePack) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let featureJSON = String(data: try encoder.encode(features), encoding: .utf8) ?? "{}"
        let userPrompt = """
        User request:
        \(prompt)

        Timeline feature pack:
        \(featureJSON)

        Return only JSON in this schema:
        {"clips":[{"start":0.0,"end":2.0,"reason":"short reason"}]}

        Do not include reasoning, markdown, code fences, <think> tags, or explanatory text.
        """

        let body = ChatRequest(
            model: model,
            messages: [
                ChatMessage(
                    role: "system",
                    content: """
                    You plan short-form creator edits for Reels and TikTok. Use only the supplied timeline features. Do not invent media outside the source duration. Prefer energetic pacing, avoid duplicate ranges, keep clips inside the source duration, and return only strict JSON. Never include reasoning, markdown, code fences,  think tags, or explanatory text.
                    """
                ),
                ChatMessage(role: "user", content: userPrompt)
            ],
            temperature: 0.2,
            maxTokens: 1200,
            // Disable model reasoning/thinking so the response is direct JSON.
            // Without this, MiniMax-M3 spends the entire max_tokens budget on
            // internal think tags and returns finish_reason=length with no usable JSON.
            // Allowed values per MiniMax API: "adaptive", "disabled".
            thinking: ThinkingConfig(type: "disabled")
        )

        return try JSONEncoder().encode(body)
    }

    static func ranges(fromAssistantContent content: String) throws -> [ClipRange] {
        guard let response = clipPlanResponse(from: content) else {
            throw MiniMaxEditPlannerError.invalidResponse
        }

        let ranges = response.clips.map { clip in
            ClipRange(startSeconds: clip.start, endSeconds: clip.end, reason: clip.reason)
        }

        guard !ranges.isEmpty else {
            throw MiniMaxEditPlannerError.noUsableClips
        }

        return ranges
    }

    private static func assistantContent(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)

        guard let content = response.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MiniMaxEditPlannerError.invalidResponse
        }

        return content
    }

    private static func clipPlanResponse(from content: String) -> ClipPlanResponse? {
        let decoder = JSONDecoder()
        let candidates = jsonObjectCandidates(from: content)

        for candidate in candidates.reversed() {
            guard let data = candidate.data(using: .utf8),
                  let response = try? decoder.decode(ClipPlanResponse.self, from: data),
                  !response.clips.isEmpty
            else {
                continue
            }

            return response
        }

        return nil
    }

    private static func jsonObjectCandidates(from content: String) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates = [trimmed]
        var startIndex: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for index in trimmed.indices {
            let character = trimmed[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
                continue
            }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let objectStart = startIndex {
                    candidates.append(String(trimmed[objectStart...index]))
                    startIndex = nil
                }
            }
        }

        return candidates
    }

    private static func errorMessage(from data: Data) -> String {
        if let error = try? JSONDecoder().decode(APIErrorResponse.self, from: data),
           let message = error.error?.message {
            return message
        }

        return String(data: data, encoding: .utf8) ?? "Request failed."
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int
    let thinking: ThinkingConfig?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case thinking
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(thinking, forKey: .thinking)
    }

    init(model: String, messages: [ChatMessage], temperature: Double, maxTokens: Int, thinking: ThinkingConfig? = nil) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.thinking = thinking
    }
}

private struct ThinkingConfig: Encodable {
    let type: String  // "disabled" | "adaptive"
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage
    }
}

private struct ClipPlanResponse: Decodable {
    let clips: [PlannedClip]
}

private struct PlannedClip: Decodable {
    let start: Double
    let end: Double
    let reason: String?
}

private struct APIErrorResponse: Decodable {
    let error: APIError?

    struct APIError: Decodable {
        let message: String?
    }
}
