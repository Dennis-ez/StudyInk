import Foundation

/// Thin Anthropic Messages API client (multimodal). No SDK — plain URLSession.
enum ClaudeService {
    private struct ContentBlock: Encodable {
        let type: String
        var text: String?
        var source: ImageSource?

        struct ImageSource: Encodable {
            let type = "base64"
            let media_type = "image/png"
            let data: String
        }

        static func from(_ content: AIContent) -> ContentBlock {
            switch content {
            case .text(let value):
                return ContentBlock(type: "text", text: value)
            case .imagePNG(let data):
                return ContentBlock(type: "image", source: ImageSource(data: data.base64EncodedString()))
            }
        }
    }

    private struct Message: Encodable {
        let role: String
        let content: [ContentBlock]
    }

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let temperature: Double
        let system: String
        let messages: [Message]
    }

    private struct ResponseBody: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }
        let content: [Content]
    }

    static func send(system: String, messages: [AIMessage], maxTokens: Int = 1500, temperature: Double = 0.3) async throws -> String {
        guard let apiKey = AIConfig.claudeKey else { throw AIServiceError.missingKey(.claude) }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: AIConfig.model(for: .claude),
                max_tokens: maxTokens,
                temperature: temperature,
                system: system,
                messages: messages.map { message in
                    Message(role: message.role.rawValue, content: message.content.map(ContentBlock.from))
                }
            )
        )

        let data = try await perform(request)
        let body = try JSONDecoder().decode(ResponseBody.self, from: data)
        return body.content.compactMap(\.text).joined(separator: "\n")
    }

    /// GET /v1/models — used to populate the model picker in Settings.
    static func listModels() async throws -> [String] {
        guard let apiKey = AIConfig.claudeKey else { throw AIServiceError.missingKey(.claude) }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=50")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        struct ModelList: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let data = try await perform(request)
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        return list.data.map(\.id)
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
