import Foundation

/// Google Gemini client (generativelanguage.googleapis.com, REST). Lets students
/// test the tutor on Google AI Studio's free-tier API keys. Same prompt contract
/// as Claude — the JSON annotations/chips payload is provider-agnostic.
enum GeminiService {
    private struct Part: Encodable {
        var text: String?
        var inline_data: InlineData?

        struct InlineData: Encodable {
            let mime_type = "image/png"
            let data: String
        }

        static func from(_ content: AIContent) -> Part {
            switch content {
            case .text(let value):
                return Part(text: value)
            case .imagePNG(let data):
                return Part(inline_data: InlineData(data: data.base64EncodedString()))
            }
        }
    }

    private struct Content: Encodable {
        let role: String   // "user" | "model"
        let parts: [Part]
    }

    private struct RequestBody: Encodable {
        struct SystemInstruction: Encodable { let parts: [Part] }
        struct GenerationConfig: Encodable { let maxOutputTokens: Int; let temperature: Double }
        let system_instruction: SystemInstruction
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    private struct ResponseBody: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]?
            }
            let content: Content?
        }
        let candidates: [Candidate]?
    }

    static func send(system: String, messages: [AIMessage], maxTokens: Int = 1500, temperature: Double = 0.3) async throws -> String {
        guard let apiKey = AIConfig.geminiKey else { throw AIServiceError.missingKey(.gemini) }
        let model = AIConfig.model(for: .gemini)
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                system_instruction: .init(parts: [Part(text: system)]),
                contents: messages.map { message in
                    Content(
                        role: message.role == .assistant ? "model" : "user",
                        parts: message.content.map(Part.from)
                    )
                },
                generationConfig: .init(maxOutputTokens: maxTokens, temperature: temperature)
            )
        )

        let data = try await perform(request)
        let body = try JSONDecoder().decode(ResponseBody.self, from: data)
        let text = (body.candidates ?? [])
            .compactMap { $0.content?.parts }
            .flatMap { $0 }
            .compactMap(\.text)
            .joined(separator: "\n")
        guard !text.isEmpty else { throw AIServiceError.badResponse(200, "empty Gemini response") }
        return text
    }

    /// Structured-output send (handoff §6): forces `responseMimeType: application/json`
    /// and a Gemini `responseSchema` (OpenAPI subset, passed as a plain dictionary) so
    /// the reply can't be malformed. Built via JSONSerialization because the schema is
    /// dynamic per intent. Returns the raw JSON text for `AIClient` to decode.
    static func sendStructured(system: String, messages: [AIMessage], schema: [String: Any],
                               maxTokens: Int = 1200, temperature: Double = 0.2) async throws -> String {
        guard let apiKey = AIConfig.geminiKey else { throw AIServiceError.missingKey(.gemini) }
        let model = AIConfig.model(for: .gemini)
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!

        func partDict(_ content: AIContent) -> [String: Any] {
            switch content {
            case .text(let value): return ["text": value]
            case .imagePNG(let data): return ["inline_data": ["mime_type": "image/png", "data": data.base64EncodedString()]]
            }
        }
        let contents: [[String: Any]] = messages.map { message in
            ["role": message.role == .assistant ? "model" : "user", "parts": message.content.map(partDict)]
        }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": maxTokens,
                "temperature": temperature,
                "responseMimeType": "application/json",
                "responseSchema": schema
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await perform(request)
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let text = (decoded.candidates ?? [])
            .compactMap { $0.content?.parts }
            .flatMap { $0 }
            .compactMap(\.text)
            .joined(separator: "\n")
        guard !text.isEmpty else { throw AIServiceError.badResponse(200, "empty Gemini response") }
        return text
    }

    /// GET /v1beta/models — only models that support generateContent.
    static func listModels() async throws -> [String] {
        guard let apiKey = AIConfig.geminiKey else { throw AIServiceError.missingKey(.gemini) }

        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=100")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        struct ModelList: Decodable {
            struct Model: Decodable {
                let name: String
                let supportedGenerationMethods: [String]?
            }
            let models: [Model]?
        }
        let data = try await perform(request)
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        return (list.models ?? [])
            .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
            .map { $0.name.replacingOccurrences(of: "models/", with: "") }
    }

    private static func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.badResponse(0, "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIServiceError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
