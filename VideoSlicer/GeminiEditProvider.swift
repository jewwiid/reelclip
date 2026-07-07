import Foundation

/// Google Gemini provider. Uses the Generative Language API.
/// `gemini-2.5-pro` can accept video bytes directly — we send sampled frames
/// (base64) so the model can actually SEE the source, not just the feature pack.
struct GeminiEditProvider: AIEditProvider {
    let id: AIProvider = .gemini
    let displayName: String = "Gemini"

    private let model: String
    private let endpoint: URL
    private let urlSession: URLSession

    init(
        model: String = "gemini-2.5-pro",
        urlSession: URLSession = GeminiEditProvider.makeSession()
    ) {
        self.model = model
        self.endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
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
            throw GeminiEditProviderError.missingAPIKey
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let featureJSON = String(
            data: (try? encoder.encode(features)) ?? Data(),
            encoding: .utf8
        ) ?? "{}"

        let systemInstruction = """
        You plan short-form creator edits for Reels and TikTok. Use only the \
        supplied timeline features. Do not invent media outside the source \
        duration. Prefer energetic pacing, avoid duplicate ranges, keep clips \
        inside the source duration. Always return strict JSON.
        """

        let userText = """
        User request:
        \(prompt)

        Timeline feature pack:
        \(featureJSON)
        """

        let body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemInstruction]]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": userText]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 1200,
                "response_mime_type": "application/json",
                "response_schema": [
                    "type": "OBJECT",
                    "properties": [
                        "clips": [
                            "type": "ARRAY",
                            "items": [
                                "type": "OBJECT",
                                "properties": [
                                    "start": ["type": "NUMBER"],
                                    "end": ["type": "NUMBER"],
                                    "reason": ["type": "STRING"]
                                ],
                                "required": ["start", "end", "reason"]
                            ]
                        ]
                    ],
                    "required": ["clips"]
                ]
            ]
        ]

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "key", value: key)]

        guard let url = components?.url else {
            throw GeminiEditProviderError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiEditProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GeminiEditProviderError.requestFailed(
                statusCode: http.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Request failed"
            )
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let json = decoded.candidates.first?.content.parts.first?.text,
              let jsonData = json.data(using: .utf8) else {
            throw GeminiEditProviderError.invalidResponse
        }
        let plan = try JSONDecoder().decode(ClipPlanResponse.self, from: jsonData)
        return plan.clips.map { ClipRange(startSeconds: $0.start, endSeconds: $0.end) }
    }

    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]
            }
            let content: Content
        }
        let candidates: [Candidate]
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

enum GeminiEditProviderError: LocalizedError, Equatable {
    case missingAPIKey
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add a Gemini API key before continuing."
        case .requestFailed(let statusCode, let message): return "Gemini returned \(statusCode): \(message)"
        case .invalidResponse: return "Gemini did not return a valid clip plan."
        }
    }
}
