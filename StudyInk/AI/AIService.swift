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
        // Cap the longest side before encoding. A page render is already ~2x, but
        // a pasted photo/screenshot can be 3–4k px — sending that raw burns image
        // tokens and memory for no readability gain. 2048 keeps stacked fractions
        // legible while bounding the payload.
        guard let data = image.downsampled(maxDimension: 2048).pngData() else { return nil }
        return .imagePNG(data)
    }
}

extension UIImage {
    /// Scales down so the longest side ≤ `maxDimension` (aspect-preserving; never
    /// upscales). Returns self when already within bounds.
    func downsampled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let factor = maxDimension / longest
        let newSize = CGSize(width: size.width * factor, height: size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
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
    /// `temperature` controls sampling randomness. Grading ("Check my work")
    /// passes 0 so the SAME page yields the SAME verdicts every run; creative
    /// asks can leave the default.
    static func send(system: String, messages: [AIMessage], maxTokens: Int = 1500, temperature: Double = 0.3) async throws -> String {
        let start = Date()
        let userText = messages.flatMap(\.content)
            .compactMap { block -> String? in if case let .text(t) = block { return t } else { return nil } }
            .joined(separator: "\n")
        let imageCount = messages.flatMap(\.content).filter { if case .imagePNG = $0 { return true } else { return false } }.count
        func log(_ response: String, failed: Bool) {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            Task { @MainActor in
                AIDebugLog.shared.record(system: system, user: userText, images: imageCount, response: response, failed: failed, ms: ms)
            }
        }
        do {
            let response: String
            switch AIConfig.provider {
            case .claude: response = try await ClaudeService.send(system: system, messages: messages, maxTokens: maxTokens, temperature: temperature)
            case .gemini: response = try await GeminiService.send(system: system, messages: messages, maxTokens: maxTokens, temperature: temperature)
            case .custom: response = try await OpenAICompatService.send(system: system, messages: messages, maxTokens: maxTokens, temperature: temperature)
            }
            log(response, failed: false)
            return response
        } catch {
            log("ERROR: \(error.localizedDescription)", failed: true)
            throw error
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
