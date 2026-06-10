import Foundation
import UIKit

/// Thin Anthropic Messages API client (multimodal). No SDK — one URLSession call.
struct ClaudeService {
    enum ServiceError: LocalizedError {
        case missingKey
        case badResponse(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return String(localized: "ai.error.missingKey")
            case .badResponse(let code, let body):
                return String(localized: "ai.error.api \(code)") + (body.isEmpty ? "" : " — \(body.prefix(200))")
            }
        }
    }

    struct ContentBlock: Encodable {
        let type: String
        var text: String?
        var source: ImageSource?

        struct ImageSource: Encodable {
            let type = "base64"
            let media_type = "image/png"
            let data: String
        }

        static func text(_ value: String) -> ContentBlock {
            ContentBlock(type: "text", text: value)
        }

        static func image(_ image: UIImage) -> ContentBlock? {
            guard let data = image.pngData() else { return nil }
            return ContentBlock(type: "image", source: ImageSource(data: data.base64EncodedString()))
        }
    }

    struct Message: Encodable {
        let role: String
        let content: [ContentBlock]
    }

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
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

    /// Sends a conversation and returns Claude's raw text (response + JSON block).
    static func send(system: String, messages: [Message], maxTokens: Int = 1500) async throws -> String {
        guard let apiKey = AIConfig.apiKey else { throw ServiceError.missingKey }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONEncoder().encode(
            RequestBody(model: AIConfig.model, max_tokens: maxTokens, system: system, messages: messages)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.badResponse(0, "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let body = try JSONDecoder().decode(ResponseBody.self, from: data)
        return body.content.compactMap(\.text).joined(separator: "\n")
    }
}
