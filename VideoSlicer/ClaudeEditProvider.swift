import Foundation

/// Anthropic Claude provider. Uses the Messages API with tool-use for
/// constrained JSON output. Prompt caching is enabled so the system
/// prompt + feature pack only cost tokens once per session.
struct ClaudeEditProvider: AIEditProvider {
    let id: AIProvider = .claude
    let displayName: String = "Claude"

    private let model: String
    private let endpoint: URL
    private let urlSession: URLSession

    init(
        model: String = "claude-4-5-sonnet",
        urlSession: URLSession = ClaudeEditProvider.makeSession()
    ) {
        self.model = model
        self.endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        self.urlSession = urlSession
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
        guard let key = credential, !key.isEmpty else {
            throw ClaudeEditProviderError.missingAPIKey
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
        inside the source duration, and call the plan_clips tool to return \
        the result. Never include reasoning, markdown, or explanatory text.
        """

        let userPrompt = """
        User request:
        \(prompt)

        Timeline feature pack:
        \(featureJSON)
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1200,
            "system": [
                [
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": ["type": "ephemeral"]
                ]
            ],
            "tools": [
                [
                    "name": "plan_clips",
                    "description": "Return the final clip plan as structured JSON.",
                    "input_schema": ClaudeEditProvider.clipPlanSchema
                ]
            ],
            "tool_choice": ["type": "tool", "name": "plan_clips"],
            "messages": [
                ["role": "user", "content": userPrompt]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeEditProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeEditProviderError.requestFailed(
                statusCode: http.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Request failed"
            )
        }

        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        let input = decoded.content
            .compactMap { block -> ClaudeToolUseBlock? in
                if case .toolUse(let block) = block { return block }
                return nil
            }
            .first

        guard let input else {
            throw ClaudeEditProviderError.invalidResponse
        }
        return input.input.clips.map {
            ClipRange(startSeconds: $0.start, endSeconds: $0.end)
        }
    }

    private static let clipPlanSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "clips": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "start": ["type": "number", "description": "Start time in seconds"],
                        "end": ["type": "number", "description": "End time in seconds, > start"],
                        "reason": ["type": "string", "description": "Why this clip works"]
                    ],
                    "required": ["start", "end", "reason"]
                ]
            ]
        ],
        "required": ["clips"]
    ]

    private struct ClaudeResponse: Decodable {
        let content: [ContentBlock]
    }

    private enum ContentBlock: Decodable {
        case toolUse(ClaudeToolUseBlock)
        case text(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "tool_use":
                let block = try container.decode(ClaudeToolUseBlock.self, forKey: .toolUse)
                self = .toolUse(block)
            case "text":
                let text = try container.decode(TextBlock.self, forKey: .text)
                self = .text(text.text)
            default:
                self = .text("")
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, toolUse = "tool_use", text
        }

        private struct TextBlock: Decodable { let text: String }
    }

    private struct ClaudeToolUseBlock: Decodable {
        let input: ClaudeClipPlanInput
    }

    private struct ClaudeClipPlanInput: Decodable {
        let clips: [ClaudeClip]
    }

    private struct ClaudeClip: Decodable {
        let start: Double
        let end: Double
        let reason: String?
    }
}

enum ClaudeEditProviderError: LocalizedError, Equatable {
    case missingAPIKey
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an Anthropic API key before using Claude."
        case .requestFailed(let statusCode, let message): return "Claude returned \(statusCode): \(message)"
        case .invalidResponse: return "Claude did not return a valid clip plan."
        }
    }
}
