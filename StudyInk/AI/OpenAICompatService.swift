import Foundation

/// Client for any OpenAI-compatible /chat/completions endpoint (Groq, OpenAI,
/// Together, local llama.cpp, …). The base URL comes from Settings; images ride
/// along as data-URI image_url blocks for providers with vision models.
enum OpenAICompatService {
    private struct ContentBlock: Encodable {
        let type: String
        var text: String?
        var image_url: ImageURL?

        struct ImageURL: Encodable {
            let url: String
        }

        static func from(_ content: AIContent) -> ContentBlock {
            switch content {
            case .text(let value):
                return ContentBlock(type: "text", text: value)
            case .imagePNG(let data):
                return ContentBlock(
                    type: "image_url",
                    image_url: ImageURL(url: "data:image/png;base64,\(data.base64EncodedString())")
                )
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
        let messages: [Message]
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String? }
            let message: Msg
        }
        let choices: [Choice]
    }

    static func send(system: String, messages: [AIMessage], maxTokens: Int = 1500, temperature: Double = 0.3) async throws -> String {
        guard let apiKey = AIConfig.apiKey(for: .custom) else { throw AIServiceError.missingKey(.custom) }

        var request = URLRequest(url: AIConfig.customEndpoint(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        // OpenAI wire format carries the system prompt as the first message.
        var wireMessages = [Message(role: "system", content: [ContentBlock(type: "text", text: system)])]
        wireMessages += messages.map { message in
            Message(role: message.role.rawValue, content: message.content.map(ContentBlock.from))
        }
        request.httpBody = try JSONEncoder().encode(
            RequestBody(model: AIConfig.model(for: .custom), max_tokens: maxTokens, temperature: temperature, messages: wireMessages)
        )

        let data = try await perform(request)
        let body = try JSONDecoder().decode(ResponseBody.self, from: data)
        return body.choices.compactMap(\.message.content).joined(separator: "\n")
    }

    /// GET /models — same shape across OpenAI-compatible providers.
    static func listModels() async throws -> [String] {
        guard let apiKey = AIConfig.apiKey(for: .custom) else { throw AIServiceError.missingKey(.custom) }

        var request = URLRequest(url: AIConfig.customEndpoint(path: "models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        struct ModelList: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let data = try await perform(request)
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        return list.data.map(\.id).sorted()
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
