import Foundation

/// Splits Claude's reply into display text and the trailing structured JSON block
/// (annotations + chips + tone). Tolerates fenced and bare JSON, or none at all.
enum AIResponseParser {
    private struct Payload: Decodable {
        struct Annotation: Decodable {
            let type: String
            let target: String?
            let match_string: String?
            let color: String?
        }
        let annotations: [Annotation]?
        let chips: [String]?
        let tone: String?
    }

    static func parse(_ raw: String) -> AIParsedResponse {
        let (text, jsonString) = splitTrailingJSON(from: raw)

        var annotations: [AIAnnotationModel] = []
        var chips: [String] = []
        var tone = AIBubbleTone.explanation

        if let jsonString, let data = jsonString.data(using: .utf8),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            annotations = (payload.annotations ?? []).compactMap { item in
                guard let kind = AIAnnotationModel.Kind(rawValue: item.type) else { return nil }
                var annotation = AIAnnotationModel(kind: kind, matchString: item.match_string, colorToken: item.color ?? "")
                if annotation.colorToken.isEmpty { annotation.colorToken = annotation.defaultToken }
                return annotation
            }
            chips = (payload.chips ?? []).filter { !$0.isEmpty }
            if let rawTone = payload.tone, let parsed = AIBubbleTone(rawValue: rawTone) {
                tone = parsed
            }
        }

        return AIParsedResponse(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            annotations: annotations,
            chips: chips,
            tone: tone
        )
    }

    /// Finds the last JSON object in the reply — ```json fenced, or a bare trailing
    /// object — and returns (text without it, json string).
    private static func splitTrailingJSON(from raw: String) -> (String, String?) {
        // Fenced block first.
        if let fenceRange = raw.range(of: "```json", options: [.backwards, .caseInsensitive]) {
            let afterFence = raw[fenceRange.upperBound...]
            if let closing = afterFence.range(of: "```") {
                let json = String(afterFence[..<closing.lowerBound])
                var text = String(raw[..<fenceRange.lowerBound])
                text += String(afterFence[closing.upperBound...])
                return (text, json)
            }
        }
        // Bare trailing object: scan back from the end for a balanced {...}.
        guard let lastBrace = raw.lastIndex(of: "}") else { return (raw, nil) }
        var depth = 0
        var index = lastBrace
        while true {
            let char = raw[index]
            if char == "}" { depth += 1 }
            if char == "{" {
                depth -= 1
                if depth == 0 { break }
            }
            if index == raw.startIndex { return (raw, nil) }
            index = raw.index(before: index)
        }
        let candidate = String(raw[index...lastBrace])
        // Only treat it as payload if it actually looks like our schema.
        guard candidate.contains("\"annotations\"") || candidate.contains("\"chips\"") else {
            return (raw, nil)
        }
        return (String(raw[..<index]), candidate)
    }

    /// Resolves text_match annotations to page rects using OCR line boxes.
    /// Partial matches slice the line box proportionally to the matched range.
    static func resolve(annotations: [AIAnnotationModel], against lines: [OCRLine]) -> [AIAnnotationModel] {
        annotations.map { annotation in
            guard annotation.rect == nil, let target = annotation.matchString?.normalizedForMatch, !target.isEmpty else {
                return annotation
            }
            var resolved = annotation
            for line in lines {
                let haystack = line.text.normalizedForMatch
                guard let range = haystack.range(of: target) else { continue }
                let start = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                let length = haystack.distance(from: range.lowerBound, to: range.upperBound)
                let total = max(haystack.count, 1)
                let fractionStart = CGFloat(start) / CGFloat(total)
                let fractionWidth = CGFloat(length) / CGFloat(total)
                resolved.rect = CGRect(
                    x: line.rect.minX + line.rect.width * fractionStart,
                    y: line.rect.minY,
                    width: max(line.rect.width * fractionWidth, 24),
                    height: line.rect.height
                )
                break
            }
            return resolved
        }
    }
}

private extension String {
    /// Loosens OCR/LaTeX mismatches: strip spaces and common math decorations.
    var normalizedForMatch: String {
        lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "·", with: "*")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "\\", with: "")
    }
}
