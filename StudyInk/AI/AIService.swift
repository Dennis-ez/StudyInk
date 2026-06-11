import Foundation
import UIKit

// MARK: - Provider-neutral message model

/// StudyInk talks to multiple AI providers (Anthropic Claude, Google Gemini).
/// Context builders produce these neutral types; each provider client maps
/// them onto its own wire format.
enum AIProvider: String, CaseIterable, Identifiable {
    case claude, gemini
    /// Any OpenAI-compatible endpoint (Groq, OpenAI, Together, local servers).
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .gemini: return "Gemini (Google)"
        case .custom: return String(localized: "settings.ai.provider.custom")
        }
    }

    /// Curated fallback shown before (or instead of) a live model-list fetch.
    var defaultModels: [String] {
        switch self {
        case .claude:
            return ["claude-fable-5", "claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]
        case .gemini:
            return ["gemini-2.5-flash", "gemini-2.5-pro"]
        case .custom:
            // Groq is the default base URL; these exist there.
            return ["llama-3.3-70b-versatile", "meta-llama/llama-4-scout-17b-16e-instruct"]
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: return "claude-fable-5"
        case .gemini: return "gemini-2.5-flash"
        case .custom: return "llama-3.3-70b-versatile"
        }
    }
}

enum AIContent {
    case text(String)
    case imagePNG(Data)

    static func image(_ image: UIImage) -> AIContent? {
        guard let data = image.pngData() else { return nil }
        return .imagePNG(data)
    }
}

struct AIMessage {
    enum Role: String { case user, assistant }
    var role: Role
    var content: [AIContent]

    static func user(_ content: [AIContent]) -> AIMessage { AIMessage(role: .user, content: content) }
    static func user(text: String) -> AIMessage { AIMessage(role: .user, content: [.text(text)]) }
    static func assistant(text: String) -> AIMessage { AIMessage(role: .assistant, content: [.text(text)]) }
}

enum AIServiceError: LocalizedError {
    case missingKey(AIProvider)
    case badResponse(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            switch provider {
            case .claude: return String(localized: "ai.error.missingKey")
            case .gemini: return String(localized: "ai.error.missingKey.gemini")
            case .custom: return String(localized: "ai.error.missingKey.custom")
            }
        case .badResponse(let code, let body):
            return String(localized: "ai.error.api \(code)") + (body.isEmpty ? "" : " — \(body.prefix(200))")
        }
    }
}

// MARK: - Router

/// Single entry point the tutor uses; routes to the provider chosen in Settings.
enum AIService {
    static func send(system: String, messages: [AIMessage], maxTokens: Int = 1500) async throws -> String {
        switch AIConfig.provider {
        case .claude: return try await ClaudeService.send(system: system, messages: messages, maxTokens: maxTokens)
        case .gemini: return try await GeminiService.send(system: system, messages: messages, maxTokens: maxTokens)
        case .custom: return try await OpenAICompatService.send(system: system, messages: messages, maxTokens: maxTokens)
        }
    }

    /// Live model list for the Settings picker. Falls back to the curated list on failure.
    static func availableModels(for provider: AIProvider) async -> [String] {
        do {
            switch provider {
            case .claude: return try await ClaudeService.listModels()
            case .gemini: return try await GeminiService.listModels()
            case .custom: return try await OpenAICompatService.listModels()
            }
        } catch {
            return provider.defaultModels
        }
    }
}
